// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

//go:build !frps

package visitor

import (
	"context"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
	"github.com/fatedier/frp/pkg/plugin/socks5udp"
	"github.com/fatedier/frp/pkg/vnet"
	xudptransport "github.com/fatedier/frp/pkg/xudp/transport"
)

type standaloneSocks5VisitorHelper struct {
	Helper
	relayAttempts atomic.Int32
}

func (*standaloneSocks5VisitorHelper) VNetController() *vnet.Controller { return nil }

func (h *standaloneSocks5VisitorHelper) ConnectServer() (*msg.Conn, error) {
	h.relayAttempts.Add(1)
	return nil, net.ErrClosed
}

type standaloneSocks5Provider struct {
	*socks5udp.DatagramServer
	unreachable atomic.Bool
}

func (s *standaloneSocks5Provider) HandlePacket(ctx context.Context, data []byte, reply func([]byte)) error {
	if s.unreachable.Load() {
		return nil
	}
	return s.DatagramServer.HandlePacket(ctx, data, reply)
}

// This transport exercises the real XUDP binary framing and visitor workers,
// while substituting only the already-established QUIC connection.
type standaloneSocks5DatagramTransport struct {
	*blockingXUDPActiveTransport
	ctx     context.Context
	server  *standaloneSocks5Provider
	replies chan []byte
}

func (*standaloneSocks5DatagramTransport) MaxDatagramPayloadSize() int {
	return xudptransport.ConservativeXUDPDatagramPayloadLimit
}

func (d *standaloneSocks5DatagramTransport) SendDatagram(data []byte) error {
	packet, err := msg.DecodeUDPPacketBinary(data)
	if err != nil {
		return err
	}
	// Provider packet rejection is a dropped datagram, not a QUIC transport
	// failure. Match ServePackets so replayed control retries keep the route.
	_ = d.server.HandlePacket(d.ctx, packet.Content, func(data []byte) {
		reply, err := msg.EncodeUDPPacketBinary(&msg.UDPPacket{Content: data, RemoteAddr: packet.RemoteAddr})
		if err != nil {
			return
		}
		select {
		case d.replies <- reply:
		default:
		}
	})
	return nil
}

func (d *standaloneSocks5DatagramTransport) ReceiveDatagram(ctx context.Context) ([]byte, error) {
	select {
	case data := <-d.replies:
		return data, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-d.closed:
		return nil, net.ErrClosed
	}
}

func TestStandaloneSocks5UDPVisitorWiring(t *testing.T) {
	for _, tc := range []struct {
		name        string
		proxyType   string
		loseOnClose bool
	}{
		{name: "sudp", proxyType: "sudp"},
		{name: "xudp", proxyType: "xudp"},
		{name: "sudp/unreachable-close", proxyType: "sudp", loseOnClose: true},
		{name: "xudp/unreachable-close", proxyType: "xudp", loseOnClose: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			endpoint := socks5udp.NewEndpoint(socks5udp.EndpointOptions{})
			datagramServer, err := socks5udp.NewDatagramServer(endpoint, socks5udp.DatagramServerOptions{
				SecretKey: "visitor-test-secret", Username: "user", Password: "password", PacketSize: 1500,
			})
			require.NoError(t, err)
			server := &standaloneSocks5Provider{DatagramServer: datagramServer}
			t.Cleanup(func() { cancel(); _ = server.Close(); _ = endpoint.Close() })
			reserve, err := net.Listen("tcp4", "127.0.0.1:0")
			require.NoError(t, err)
			ingress := reserve.Addr().(*net.TCPAddr)
			require.NoError(t, reserve.Close())
			base := v1.VisitorBaseConfig{
				Name: "standalone", Type: tc.proxyType, BindAddr: "0.0.0.0", BindPort: -1, SecretKey: "visitor-test-secret",
				Plugin: v1.TypedVisitorPluginOptions{
					Type:                 v1.VisitorPluginSocks5UDP,
					VisitorPluginOptions: &v1.Socks5UDPVisitorPluginOptions{BindAddr: "127.0.0.1", BindPort: ingress.Port},
				},
			}
			var cfg v1.VisitorConfigurer = &v1.SUDPVisitorConfig{VisitorBaseConfig: base}
			if tc.proxyType == "xudp" {
				cfg = &v1.XUDPVisitorConfig{VisitorBaseConfig: base}
			}
			helper := &standaloneSocks5VisitorHelper{}
			v, err := NewVisitor(ctx, cfg, &v1.ClientCommonConfig{UDPPacketSize: 1500}, helper)
			require.NoError(t, err)
			var workers sync.WaitGroup
			var internalAddr func() *net.UDPAddr
			switch visitor := v.(type) {
			case *SUDPVisitor:
				visitor.newVisitorConnFn = func() (net.Conn, func(), error) {
					local, remote := net.Pipe()
					workers.Go(func() { serveStandaloneSocks5SUDP(ctx, remote, server) })
					return local, func() {}, nil
				}
				internalAddr = func() *net.UDPAddr { return visitor.udpConn.LocalAddr().(*net.UDPAddr) }
			case *XUDPVisitor:
				visitor.p2PDialer = func(uint64) (xudptransport.DatagramTransport, bool) {
					return &standaloneSocks5DatagramTransport{
						blockingXUDPActiveTransport: newBlockingXUDPActiveTransport(),
						ctx:                         ctx, server: server, replies: make(chan []byte, 64),
					}, true
				}
				internalAddr = func() *net.UDPAddr { return visitor.udpConn.LocalAddr().(*net.UDPAddr) }
			}
			t.Cleanup(func() { v.Close(); workers.Wait() })
			require.NoError(t, v.Run())
			require.True(t, internalAddr().IP.Equal(net.IPv4(127, 0, 0, 1)))
			// The configured SOCKS ingress has no shared/raw UDP listener. Only
			// an authenticated UDP ASSOCIATE opens an application's relay socket.
			unused, err := net.ListenUDP("udp4", &net.UDPAddr{IP: ingress.IP, Port: ingress.Port})
			require.NoError(t, err)
			require.NoError(t, unused.Close())
			control, err := net.Dial("tcp4", ingress.String())
			require.NoError(t, err)
			defer control.Close()
			require.NoError(t, control.SetDeadline(time.Now().Add(3*time.Second)))
			_, err = control.Write([]byte{5, 1, 2})
			require.NoError(t, err)
			var reply [2]byte
			_, err = io.ReadFull(control, reply[:])
			require.NoError(t, err)
			require.Equal(t, [2]byte{5, 2}, reply)
			_, err = control.Write([]byte{1, 4, 'u', 's', 'e', 'r', 8, 'p', 'a', 's', 's', 'w', 'o', 'r', 'd'})
			require.NoError(t, err)
			_, err = io.ReadFull(control, reply[:])
			require.NoError(t, err)
			require.Equal(t, [2]byte{1, 0}, reply)
			require.NoError(t, socks5udp.WriteRequest(control, socks5udp.CmdUDPAssociate, socks5udp.Address{}))
			code, bound, err := socks5udp.ReadReply(control)
			require.NoError(t, err)
			require.Zero(t, code)
			relayAddr, err := net.ResolveUDPAddr("udp4", bound.String())
			require.NoError(t, err)
			relay, err := net.DialUDP("udp4", nil, relayAddr)
			require.NoError(t, err)
			defer relay.Close()
			target, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
			require.NoError(t, err)
			defer target.Close()
			targetAddr := socks5udp.AddressFromNetAddr(target.LocalAddr())
			payload := make([]byte, 1000)
			packet, err := socks5udp.BuildUDP(targetAddr, payload)
			require.NoError(t, err)
			_, err = relay.Write(packet)
			require.NoError(t, err)
			require.NoError(t, target.SetDeadline(time.Now().Add(2*time.Second)))
			buffer := make([]byte, 4096)
			n, from, err := target.ReadFromUDP(buffer)
			require.NoError(t, err)
			require.Equal(t, payload, buffer[:n])
			_, err = target.WriteToUDP(buffer[:n], from)
			require.NoError(t, err)
			require.NoError(t, relay.SetReadDeadline(time.Now().Add(time.Second)))
			n, err = relay.Read(buffer)
			require.NoError(t, err)
			require.Equal(t, packet, buffer[:n])
			private := internalAddr()
			server.unreachable.Store(tc.loseOnClose)
			closeDone := make(chan struct{})
			go func() {
				var callers sync.WaitGroup
				for range 8 {
					callers.Go(v.Close)
				}
				callers.Wait()
				close(closeDone)
			}()
			select {
			case <-closeDone:
			case <-time.After(2 * time.Second):
				t.Fatal("standalone visitor Close blocked")
			}
			require.Zero(t, helper.relayAttempts.Load(), "shutdown must not start relay fallback")
			addresses := []*net.UDPAddr{private, relayAddr}
			if !tc.loseOnClose {
				// The provider socket must be revoked before Close returns,
				// without waiting for the remote session lease to expire.
				addresses = append(addresses, from)
			}
			for _, addr := range addresses {
				socket, err := net.ListenUDP("udp4", addr)
				require.NoError(t, err)
				_ = socket.Close()
			}
			listener, err := net.Listen("tcp4", ingress.String())
			require.NoError(t, err)
			_ = listener.Close()
		})
	}
}

func serveStandaloneSocks5SUDP(ctx context.Context, conn net.Conn, server *standaloneSocks5Provider) {
	defer conn.Close()
	peer := msg.NewConn(conn, msg.NewV1ReadWriter(conn))
	replies := make(chan *msg.UDPPacket, 64)
	done := make(chan struct{})
	var writer sync.WaitGroup
	writer.Go(func() {
		for {
			select {
			case <-done:
				return
			case packet := <-replies:
				if err := peer.WriteMsg(packet); err != nil {
					return
				}
			}
		}
	})
	// Closing the connection also releases a writer blocked in a response.
	defer func() {
		close(done)
		_ = conn.Close()
		writer.Wait()
	}()
	for {
		raw, err := peer.ReadMsg()
		if err != nil {
			return
		}
		packet, ok := raw.(*msg.UDPPacket)
		if !ok {
			continue
		}
		_ = server.HandlePacket(ctx, packet.Content, func(data []byte) {
			select {
			case replies <- &msg.UDPPacket{Content: data, RemoteAddr: packet.RemoteAddr}:
			default:
			}
		})
	}
}
