// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

//go:build !frps

package proxy

import (
	"context"
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
)

// Authentication, leases, application traffic, and revocation traverse the
// production UDP provider paths. The QUIC pair uses real mutually authenticated
// DATAGRAM sockets; this deliberately does not claim to test NAT traversal.
func TestSOCKS5UDPDatagramXUDPTransportSwitchKeepsSession(t *testing.T) {
	const secret = "standalone-transport-test-secret"
	provider, err := plugin.Create(v1.PluginSocks5UDP, plugin.PluginContext{
		Name: "standalone-data", ProxyType: "xudp", SecretKey: secret, UDPPacketSize: 1500,
	}, &v1.Socks5UDPPluginOptions{
		Type: v1.PluginSocks5UDP, SessionMode: "datagram", Username: "alice", Password: "password",
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = provider.Close() })
	pxy := newProductionXUDPLifecycleTestProxy()
	pxy.proxyPlugin = provider
	t.Cleanup(pxy.Close)
	bridge, upstream := newSOCKS5DatagramTransportBridge(t)

	startRelay := func() (func(*msg.UDPPacket) error, func()) {
		t.Helper()
		lc, conn, peer := promoteProductionXUDPConn(t, pxy)
		rw, err := msg.NewUDPPacketReadWriter(peer, "", "")
		if err != nil {
			t.Fatal(err)
		}
		var workers sync.WaitGroup
		workers.Add(2)
		go func() {
			defer workers.Done()
			pxy.handleRelayWorkConn(lc, conn, nil)
			pxy.finishActive(lc)
		}()
		go func() {
			defer workers.Done()
			for {
				m, err := rw.ReadMsg()
				if err != nil {
					return
				}
				if reply, ok := m.(*msg.UDPPacket); ok {
					bridge.deliver(t, reply)
				}
			}
		}()
		done := make(chan struct{})
		go func() { workers.Wait(); close(done) }()
		stop := func() {
			lc.stop()
			_ = peer.Close()
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				t.Error("standalone relay workers did not stop")
			}
		}
		t.Cleanup(stop)
		var writeMu sync.Mutex
		return func(packet *msg.UDPPacket) error {
			writeMu.Lock()
			defer writeMu.Unlock()
			return rw.WriteMsg(packet)
		}, stop
	}
	relaySend, stopRelay := startRelay()
	bridge.setRoute(relaySend)
	client, err := socks5udp.NewDatagramClient(upstream, socks5udp.DatagramClientOptions{
		SecretKey: secret, PacketSize: 1500, RenewInterval: 100 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	method, err := client.Negotiate(ctx, []byte{2})
	if err != nil || method != 2 {
		t.Fatalf("UDP authentication negotiation = %d, %v", method, err)
	}
	if err := client.Authenticate(ctx, "alice", "password"); err != nil {
		t.Fatal(err)
	}

	target, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = target.Close() })
	var requests atomic.Int32
	go func() {
		b := make([]byte, 1500)
		for {
			n, peer, err := target.ReadFromUDP(b)
			if err != nil {
				return
			}
			requests.Add(1)
			_, _ = target.WriteToUDP(append([]byte(peer.String()+"|"), b[:n]...), peer)
		}
	}()
	address := socks5udp.AddressFromNetAddr(target.LocalAddr())
	decodeReply := func(raw []byte) (string, string) {
		t.Helper()
		from, payload, err := socks5udp.ParseUDP(raw)
		if err != nil || from != address {
			t.Fatalf("reply source = %+v, want %+v: %v", from, address, err)
		}
		source, body, ok := strings.Cut(string(payload), "|")
		if !ok {
			t.Fatalf("unexpected reply payload: %q", payload)
		}
		return source, body
	}
	exchange := func(payload string) string {
		t.Helper()
		raw, err := socks5udp.BuildUDP(address, []byte(payload))
		if err != nil {
			t.Fatal(err)
		}
		if err := client.SendPacket(raw); err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		for {
			raw, err := client.ReceivePacket(ctx)
			if err != nil {
				t.Fatal(err)
			}
			source, body := decodeReply(raw)
			if body == "p2p-push" || body == "relay-push" {
				continue // A previous receive-only probe can arrive after its deadline.
			}
			if body != payload {
				t.Fatalf("reply = %q, want %q", body, payload)
			}
			return source
		}
	}
	originalSource := exchange("relay-before")
	targetPeer, err := net.ResolveUDPAddr("udp4", originalSource)
	if err != nil {
		t.Fatal(err)
	}
	assertReceiveOnly := func(payload string, expectedRequests int32) {
		t.Helper()
		rebound := false
		for range 30 {
			if _, err := target.WriteToUDP([]byte(originalSource+"|"+payload), targetPeer); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
			raw, err := client.ReceivePacket(ctx)
			cancel()
			if err != nil {
				continue
			}
			source, body := decodeReply(raw)
			if source != originalSource || body != payload {
				t.Fatalf("receive-only rebind reply = %q|%q, want %q|%q", source, body, originalSource, payload)
			}
			rebound = true
			break
		}
		if !rebound {
			t.Fatal("UDP session renewals did not restore the receive-only return path")
		}
		if got := requests.Load(); got != expectedRequests {
			t.Fatalf("session control frames reached the target: %d application requests, want %d", got, expectedRequests)
		}
	}
	stopRelay()

	providerQUIC, visitorQUIC := newSOCKS5TestQUICPair(t)
	lc, _, peer := promoteProductionXUDPConn(t, pxy)
	lc.addCloser(func() { _ = providerQUIC.Close() })
	var p2pWorkers sync.WaitGroup
	p2pWorkers.Add(2)
	go func() {
		defer p2pWorkers.Done()
		pxy.forwardP2PQUICDatagram(lc, providerQUIC)
		pxy.finishActive(lc)
	}()
	go func() {
		defer p2pWorkers.Done()
		for {
			body, err := visitorQUIC.ReceiveDatagram(lc.ctx)
			if err != nil {
				return
			}
			reply, err := msg.DecodeUDPPacketBinary(body)
			if err != nil {
				t.Errorf("invalid QUIC UDP frame: %v", err)
				return
			}
			bridge.deliver(t, reply)
		}
	}()
	p2pDone := make(chan struct{})
	go func() { p2pWorkers.Wait(); close(p2pDone) }()
	stopP2P := func() {
		lc.stop()
		_ = peer.Close()
		_ = visitorQUIC.Close()
		select {
		case <-p2pDone:
		case <-time.After(3 * time.Second):
			t.Error("standalone P2P workers did not stop")
		}
	}
	t.Cleanup(stopP2P)
	bridge.setRoute(func(packet *msg.UDPPacket) error {
		body, err := msg.EncodeUDPPacketBinary(packet)
		if err != nil {
			return err
		}
		return visitorQUIC.SendDatagram(body)
	})
	assertReceiveOnly("p2p-push", 1)
	if source := exchange("p2p-direct"); source != originalSource {
		t.Fatalf("relay -> QUIC changed the target UDP source: %s -> %s", originalSource, source)
	}
	stopP2P()

	relaySend, _ = startRelay()
	bridge.setRoute(relaySend)
	assertReceiveOnly("relay-push", 2)
	if source := exchange("relay-after"); source != originalSource {
		t.Fatalf("QUIC -> relay changed the target UDP source: %s -> %s", originalSource, source)
	}
	closeResult := make(chan error, 1)
	go func() { closeResult <- client.Close() }()
	select {
	case err := <-closeResult:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("closing the UDP session exceeded the cleanup deadline")
	}
	select {
	case <-client.Done():
	default:
		t.Fatal("closed datagram client still has workers running")
	}
	// The target source port belongs to the provider, not to the local bridge.
	// Releasing it proves that an encrypted close revoked the remote session.
	released := false
	for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); {
		probe, err := net.ListenUDP("udp4", targetPeer)
		if err == nil {
			_ = probe.Close()
			released = true
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !released {
		t.Fatal("session close did not release the provider target socket")
	}
	// Replaying the encrypted handshake and data must not resurrect the closed
	// association, even though the provider transport remains available.
	for _, content := range bridge.transcript() {
		if err := relaySend(&msg.UDPPacket{Content: content, RemoteAddr: bridge.visitor}); err != nil {
			t.Fatal(err)
		}
	}
	time.Sleep(200 * time.Millisecond)
	if got := requests.Load(); got != 3 {
		t.Fatalf("revoked session forwarded replayed UDP traffic: %d target requests, want 3", got)
	}
}

// A real local UDP socket stands in for the visitor's private listener, while
// route callbacks change only the surrounding production XUDP transport.
type socks5DatagramTransportBridge struct {
	conn    *net.UDPConn
	peer    *net.UDPAddr
	visitor *net.UDPAddr
	mu      sync.Mutex
	send    func(*msg.UDPPacket) error
	sent    [][]byte
}

func newSOCKS5DatagramTransportBridge(t *testing.T) (*socks5DatagramTransportBridge, net.Conn) {
	t.Helper()
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	upstream, err := net.DialUDP("udp4", nil, conn.LocalAddr().(*net.UDPAddr))
	if err != nil {
		_ = conn.Close()
		t.Fatal(err)
	}
	bridge := &socks5DatagramTransportBridge{
		conn: conn, peer: upstream.LocalAddr().(*net.UDPAddr),
		visitor: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 40124},
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		b := make([]byte, 1500)
		for {
			n, _, err := conn.ReadFromUDP(b)
			if err != nil {
				return
			}
			content := append([]byte(nil), b[:n]...)
			if !socks5udp.IsSessionDatagram(content) {
				t.Error("session emitted a non-session UDP frame")
				continue
			}
			bridge.mu.Lock()
			send := bridge.send
			bridge.sent = append(bridge.sent, content)
			bridge.mu.Unlock()
			if send != nil {
				// Dropped packets during a route change are expected. Session
				// retries and lease renewal must recover without a new login.
				_ = send(&msg.UDPPacket{Content: content, RemoteAddr: bridge.visitor})
			}
		}
	}()
	t.Cleanup(func() {
		_ = upstream.Close()
		_ = conn.Close()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			t.Error("local UDP bridge did not stop")
		}
	})
	return bridge, upstream
}

func (b *socks5DatagramTransportBridge) setRoute(send func(*msg.UDPPacket) error) {
	b.mu.Lock()
	b.send = send
	b.mu.Unlock()
}

func (b *socks5DatagramTransportBridge) deliver(t *testing.T, packet *msg.UDPPacket) {
	t.Helper()
	if packet.RemoteAddr == nil || packet.RemoteAddr.String() != b.visitor.String() || !socks5udp.IsSessionDatagram(packet.Content) {
		t.Errorf("provider returned an invalid session route or frame: %+v", packet.RemoteAddr)
		return
	}
	_, _ = b.conn.WriteToUDP(packet.Content, b.peer)
}

func (b *socks5DatagramTransportBridge) transcript() [][]byte {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([][]byte(nil), b.sent...)
}
