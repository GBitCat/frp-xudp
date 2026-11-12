// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

//go:build !frps

package proxy

import (
	"context"
	"io"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
	plugin "github.com/fatedier/frp/pkg/plugin/client"
	"github.com/fatedier/frp/pkg/plugin/socks5udp"
	xudptransport "github.com/fatedier/frp/pkg/xudp/transport"
)

// This test exercises the production provider forwarding paths with a real
// mutually authenticated QUIC DATAGRAM connection. It does not need a public
// STUN service and must not be mistaken for a test of NAT traversal itself.
func TestSOCKS5UDPXUDPTransportSwitchKeepsTargetMapping(t *testing.T) {
	store := &sync.Map{}
	udpPlugin, err := plugin.Create(v1.PluginSocks5UDP, plugin.PluginContext{
		Name: "socks-data", ProxyType: "xudp", SharedStore: store, UDPPacketSize: 1500,
	}, &v1.Socks5UDPPluginOptions{Type: v1.PluginSocks5UDP})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = udpPlugin.Close() })
	controlPlugin, err := plugin.Create(v1.PluginSocks5UDP, plugin.PluginContext{
		Name: "socks-control", ProxyType: "stcp", SharedStore: store,
	}, &v1.Socks5UDPPluginOptions{Type: v1.PluginSocks5UDP, UDPProxyName: "socks-data"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = controlPlugin.Close() })
	serverControl, control := net.Pipe()
	t.Cleanup(func() { _ = control.Close() })
	controlDone := make(chan struct{})
	go func() {
		controlPlugin.Handle(context.Background(), &plugin.ConnectionInfo{Conn: serverControl, UnderlyingConn: serverControl})
		close(controlDone)
	}()
	token := openSOCKS5TransportTestAssociation(t, control)

	target, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = target.Close() })
	var targetRequests atomic.Int32
	go func() {
		b := make([]byte, 1500)
		for {
			n, peer, err := target.ReadFromUDP(b)
			if err != nil {
				return
			}
			targetRequests.Add(1)
			_, _ = target.WriteToUDP(append([]byte(peer.String()+"|"), b[:n]...), peer)
		}
	}()
	address := socks5udp.AddressFromNetAddr(target.LocalAddr())
	visitorSource := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 40123}
	packet := func(payload string) *msg.UDPPacket {
		raw, err := socks5udp.BuildUDP(address, []byte(payload))
		if err != nil {
			t.Fatal(err)
		}
		return &msg.UDPPacket{Content: socks5udp.EncodeDatagram(token, raw), RemoteAddr: visitorSource}
	}
	decodeReply := func(reply *msg.UDPPacket, expected string) string {
		t.Helper()
		if reply.RemoteAddr == nil || reply.RemoteAddr.String() != visitorSource.String() {
			t.Fatalf("reply lost visitor route: %+v", reply.RemoteAddr)
		}
		gotToken, raw, err := socks5udp.DecodeDatagram(reply.Content)
		if err != nil || gotToken != token {
			t.Fatalf("reply association mismatch: %v", err)
		}
		from, data, err := socks5udp.ParseUDP(raw)
		if err != nil || from != address {
			t.Fatalf("reply source = %+v, want %+v: %v", from, address, err)
		}
		source, payload, ok := strings.Cut(string(data), "|")
		if !ok || payload != expected {
			t.Fatalf("reply payload = %q, want source|%s", data, expected)
		}
		return source
	}

	pxy := newProductionXUDPLifecycleTestProxy()
	pxy.proxyPlugin = udpPlugin
	t.Cleanup(pxy.Close)
	startRelay := func() (net.Conn, msg.ReadWriter, func()) {
		t.Helper()
		lc, conn, peer := promoteProductionXUDPConn(t, pxy)
		done := make(chan struct{})
		go func() {
			pxy.handleRelayWorkConn(lc, conn, nil)
			pxy.finishActive(lc)
			close(done)
		}()
		stop := func() {
			lc.stop()
			_ = peer.Close()
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				t.Error("SOCKS5 relay workers did not stop")
			}
		}
		t.Cleanup(stop)
		rw, err := msg.NewUDPPacketReadWriter(peer, "", "")
		if err != nil {
			t.Fatal(err)
		}
		return peer, rw, stop
	}
	relayPeer, relay, stopRelay := startRelay()
	if err := relayPeer.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	if err := relay.WriteMsg(packet("relay-before")); err != nil {
		t.Fatal(err)
	}
	var response msg.UDPPacket
	if err := relay.ReadMsgInto(&response); err != nil {
		t.Fatal(err)
	}
	originalSource := decodeReply(&response, "relay-before")
	stopRelay()

	providerQUIC, visitorQUIC := newSOCKS5TestQUICPair(t)
	lc, _, p2pPeer := promoteProductionXUDPConn(t, pxy)
	lc.addCloser(func() { _ = providerQUIC.Close() })
	p2pDone := make(chan struct{})
	go func() {
		pxy.forwardP2PQUICDatagram(lc, providerQUIC)
		pxy.finishActive(lc)
		close(p2pDone)
	}()
	stopP2P := func() {
		lc.stop()
		_ = p2pPeer.Close()
		select {
		case <-p2pDone:
		case <-time.After(3 * time.Second):
			t.Error("SOCKS5 P2P workers did not stop")
		}
	}
	t.Cleanup(stopP2P)
	// Switch the return path without sending any new application datagram to
	// the target. Binding frames must not appear at the target or recreate its
	// socket; a receive-only application should recover after rebinding too.
	bindBody, err := msg.EncodeUDPPacketBinary(&msg.UDPPacket{
		Content: socks5udp.EncodeDatagram(token, nil), RemoteAddr: visitorSource,
	})
	if err != nil {
		t.Fatal(err)
	}
	targetPeer, err := net.ResolveUDPAddr("udp", originalSource)
	if err != nil {
		t.Fatal(err)
	}
	rebound := false
	for range 20 {
		if err := visitorQUIC.SendDatagram(bindBody); err != nil {
			t.Fatal(err)
		}
		if _, err := target.WriteToUDP([]byte(originalSource+"|p2p-push"), targetPeer); err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
		body, err := visitorQUIC.ReceiveDatagram(ctx)
		cancel()
		if err != nil {
			continue
		}
		reply, err := msg.DecodeUDPPacketBinary(body)
		if err != nil {
			t.Fatal(err)
		}
		if source := decodeReply(reply, "p2p-push"); source != originalSource {
			t.Fatalf("receive-only rebind changed target UDP source: %s -> %s", originalSource, source)
		}
		rebound = true
		break
	}
	if !rebound {
		t.Fatal("binding frames did not restore the receive-only P2P return path")
	}
	if got := targetRequests.Load(); got != 1 {
		t.Fatalf("binding frames leaked to the target: received %d requests, want only the initial request", got)
	}

	body, err := msg.EncodeUDPPacketBinary(packet("p2p-direct"))
	if err != nil {
		t.Fatal(err)
	}
	if err := visitorQUIC.SendDatagram(body); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	var reply *msg.UDPPacket
	for {
		body, err = visitorQUIC.ReceiveDatagram(ctx)
		if err != nil {
			t.Fatal(err)
		}
		reply, err = msg.DecodeUDPPacketBinary(body)
		if err != nil {
			t.Fatal(err)
		}
		// A retried push may have arrived just after its short receive
		// deadline. Only ignore that known payload, never other responses.
		_, raw, err := socks5udp.DecodeDatagram(reply.Content)
		if err != nil {
			t.Fatal(err)
		}
		_, data, err := socks5udp.ParseUDP(raw)
		if err != nil {
			t.Fatal(err)
		}
		if string(data) != originalSource+"|p2p-push" {
			break
		}
	}
	if source := decodeReply(reply, "p2p-direct"); source != originalSource {
		t.Fatalf("relay -> P2P changed target UDP source: %s -> %s", originalSource, source)
	}
	stopP2P()

	relayPeer, relay, _ = startRelay()
	if err := relayPeer.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	if err := relay.WriteMsg(packet("relay-after")); err != nil {
		t.Fatal(err)
	}
	if err := relay.ReadMsgInto(&response); err != nil {
		t.Fatal(err)
	}
	if source := decodeReply(&response, "relay-after"); source != originalSource {
		t.Fatalf("P2P -> relay changed target UDP source: %s -> %s", originalSource, source)
	}

	if err := control.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-controlDone:
	case <-time.After(3 * time.Second):
		t.Fatal("control close did not finish association cleanup")
	}
	if err := relay.WriteMsg(packet("revoked")); err != nil {
		t.Fatal(err)
	}
	if err := relayPeer.SetReadDeadline(time.Now().Add(200 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	if err := relay.ReadMsgInto(&response); err == nil {
		t.Fatal("revoked association still forwarded UDP data")
	}
}

func openSOCKS5TransportTestAssociation(t *testing.T, conn net.Conn) socks5udp.Token {
	t.Helper()
	if err := conn.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	if err := socks5udp.WriteMagic(conn); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Write([]byte{5, 1, 0}); err != nil {
		t.Fatal(err)
	}
	var auth [2]byte
	if _, err := io.ReadFull(conn, auth[:]); err != nil {
		t.Fatal(err)
	}
	if auth != [2]byte{5, 0} {
		t.Fatalf("unexpected authentication response: %v", auth)
	}
	if _, err := conn.Write([]byte{5, 3, 0, 1, 0, 0, 0, 0, 0, 0}); err != nil {
		t.Fatal(err)
	}
	code, _, err := socks5udp.ReadReply(conn)
	if err != nil || code != 0 {
		t.Fatalf("UDP association failed: %d %v", code, err)
	}
	token, err := socks5udp.ReadToken(conn)
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.SetDeadline(time.Time{}); err != nil {
		t.Fatal(err)
	}
	return token
}

func newSOCKS5TestQUICPair(t *testing.T) (xudptransport.DatagramTransport, xudptransport.DatagramTransport) {
	t.Helper()
	providerConn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = providerConn.Close() })
	visitorConn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = visitorConn.Close() })
	providerID, err := xudptransport.GenerateIdentity()
	if err != nil {
		t.Fatal(err)
	}
	visitorID, err := xudptransport.GenerateIdentity()
	if err != nil {
		t.Fatal(err)
	}
	providerTLS, err := xudptransport.ServerTLSConfig(providerID, visitorID.Fingerprint())
	if err != nil {
		t.Fatal(err)
	}
	visitorTLS, err := xudptransport.ClientTLSConfig(visitorID, providerID.Fingerprint())
	if err != nil {
		t.Fatal(err)
	}
	listener, err := xudptransport.Listen(providerConn, providerTLS, xudptransport.Options{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	type acceptResult struct {
		conn xudptransport.DatagramTransport
		err  error
	}
	accepted := make(chan acceptResult, 1)
	go func() {
		conn, err := listener.Accept(ctx)
		accepted <- acceptResult{conn: conn, err: err}
	}()
	visitor, err := xudptransport.Dial(ctx, visitorConn, providerConn.LocalAddr().(*net.UDPAddr), visitorTLS, xudptransport.Options{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = visitor.Close() })
	result := <-accepted
	if result.err != nil {
		t.Fatal(result.err)
	}
	t.Cleanup(func() { _ = result.conn.Close() })
	return result.conn, visitor
}
