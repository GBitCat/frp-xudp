// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

//go:build !frps

package visitor

import (
	"bytes"
	"context"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/plugin/socks5udp"
)

func newStandaloneSocks5UDPHarness(t *testing.T, username, password string, capacity int) *socks5UDPHarness {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	endpoint := socks5udp.NewEndpoint(socks5udp.EndpointOptions{})
	server, err := socks5udp.NewDatagramServer(endpoint, socks5udp.DatagramServerOptions{
		SecretKey: "standalone-secret", Username: username, Password: password,
		PacketSize: 1500, MaxSessions: capacity,
	})
	require.NoError(t, err)
	relay, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)
	replies := make(chan socks5UDPReply, 128)
	packets := make(chan []byte, 128)
	var workers sync.WaitGroup
	workers.Go(func() {
		buf := make([]byte, 65535)
		for {
			n, addr, err := relay.ReadFromUDP(buf)
			if err != nil {
				return
			}
			select {
			case packets <- append([]byte(nil), buf[:n]...):
			default:
			}
			_ = server.HandlePacket(ctx, buf[:n], func(data []byte) {
				select {
				case replies <- socks5UDPReply{data: data, addr: addr}:
				default:
				}
			})
		}
	})
	workers.Go(func() {
		for {
			select {
			case <-ctx.Done():
				return
			case reply := <-replies:
				_, _ = relay.WriteToUDP(reply.data, reply.addr)
			}
		}
	})
	p, err := NewSocks5UDPPlugin(PluginContext{
		Ctx: ctx, ProxyType: "sudp", SecretKey: "standalone-secret", UDPPacketSize: 1500,
		DialDatagram: func(ctx context.Context) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "udp4", relay.LocalAddr().String())
		},
	}, &v1.Socks5UDPVisitorPluginOptions{BindAddr: "127.0.0.1"})
	require.NoError(t, err)
	plugin := p.(*Socks5UDPPlugin)
	plugin.Start()
	t.Cleanup(func() {
		_ = plugin.Close()
		_ = server.Close()
		_ = endpoint.Close()
		cancel()
		_ = relay.Close()
		workers.Wait()
	})
	return &socks5UDPHarness{plugin: plugin, endpoint: endpoint, packets: packets}
}

func TestStandaloneSocks5UDPAuthenticationAndConnectRejection(t *testing.T) {
	for _, credentials := range [][2]string{{"", ""}, {"user", "secret"}, {"user", ""}, {"", "secret"}} {
		t.Run(credentials[0]+"/"+credentials[1], func(t *testing.T) {
			h := newStandaloneSocks5UDPHarness(t, credentials[0], credentials[1], 0)
			control := h.dial(t, credentials[0], credentials[1])
			require.NoError(t, socks5udp.WriteRequest(control, socks5udp.CmdConnect, socks5udp.Address{Host: "127.0.0.1", Port: 80}))
			reply, _, err := socks5udp.ReadReply(control)
			require.NoError(t, err)
			require.Equal(t, byte(7), reply)
			control = h.dial(t, credentials[0], credentials[1])
			bound := socks5Associate(t, control, socks5udp.Address{})
			socks5Exchange(t, socks5UDPClient(t, net.IPv4(127, 0, 0, 1)), bound, socks5UDPEcho(t), "authenticated-udp")
		})
	}
}

func TestStandaloneSocks5UDPRejectsAuthentication(t *testing.T) {
	h := newStandaloneSocks5UDPHarness(t, "user", "secret", 0)
	for _, method := range []byte{0, 2} {
		client, err := net.Dial("tcp4", h.plugin.listener.Addr().String())
		require.NoError(t, err)
		t.Cleanup(func() { _ = client.Close() })
		require.NoError(t, client.SetDeadline(time.Now().Add(2*time.Second)))
		_, err = client.Write([]byte{5, 1, method})
		require.NoError(t, err)
		var reply [2]byte
		_, err = io.ReadFull(client, reply[:])
		require.NoError(t, err)
		if method == 0 {
			require.Equal(t, [2]byte{5, 255}, reply)
			continue
		}
		require.Equal(t, [2]byte{5, 2}, reply)
		_, err = client.Write([]byte{1, 4, 'u', 's', 'e', 'r', 3, 'b', 'a', 'd'})
		require.NoError(t, err)
		_, err = io.ReadFull(client, reply[:])
		require.NoError(t, err)
		require.Equal(t, [2]byte{1, 1}, reply)
	}
}

func TestStandaloneSocks5UDPSourceBindingAndIsolation(t *testing.T) {
	h := newStandaloneSocks5UDPHarness(t, "", "", 0)
	target := socks5UDPEcho(t)
	client := socks5UDPClient(t, net.IPv4(127, 0, 0, 1))
	control := h.dial(t, "", "")
	bound := socks5Associate(t, control, socks5udp.Address{Host: "0.0.0.0", Port: uint16(client.LocalAddr().(*net.UDPAddr).Port)})
	packet, err := socks5udp.BuildUDP(socks5udp.AddressFromNetAddr(target), []byte("test"))
	require.NoError(t, err)
	wrongPort := socks5UDPClient(t, net.IPv4(127, 0, 0, 1))
	socks5ExpectDropped(t, wrongPort, bound, packet)
	socks5ExpectDropped(t, socks5UDPClient(t, net.IPv4(127, 0, 0, 2)), bound, packet)
	fragment := append([]byte(nil), packet...)
	fragment[2] = 1
	socks5ExpectDropped(t, client, bound, fragment)
	oversized, err := socks5udp.BuildUDP(socks5udp.AddressFromNetAddr(target), make([]byte, 1500))
	require.NoError(t, err)
	socks5ExpectDropped(t, client, bound, oversized)
	socks5Exchange(t, client, bound, target, "valid-after-drops")

	control2 := h.dial(t, "", "")
	bound2 := socks5Associate(t, control2, socks5udp.Address{})
	require.NotEqual(t, bound.Port, bound2.Port)
	socks5Exchange(t, wrongPort, bound2, target, "second-session")
	socks5ExpectDropped(t, client, bound2, packet)
	require.NoError(t, control.Close())
	require.Eventually(t, func() bool {
		socket, err := net.ListenUDP("udp4", bound)
		if err != nil {
			return false
		}
		_ = socket.Close()
		return true
	}, time.Second, 5*time.Millisecond)
	socks5Exchange(t, wrongPort, bound2, target, "second-survives-close")
}

func TestStandaloneSocks5UDPCloseRevokesRemoteCapacity(t *testing.T) {
	h := newStandaloneSocks5UDPHarness(t, "", "", 1)
	control := h.dial(t, "", "")
	bound := socks5Associate(t, control, socks5udp.Address{})
	socks5Exchange(t, socks5UDPClient(t, net.IPv4(127, 0, 0, 1)), bound, socks5UDPEcho(t), "before-close")
	require.NoError(t, control.Close())
	require.Eventually(t, func() bool {
		h.plugin.mu.Lock()
		defer h.plugin.mu.Unlock()
		return len(h.plugin.clients) == 0
	}, time.Second, 5*time.Millisecond)
	// A single available slot proves CLOSE revoked the remote session before
	// its much longer lease would otherwise expire.
	control = h.dial(t, "", "")
	_ = socks5Associate(t, control, socks5udp.Address{})
	require.NoError(t, h.plugin.Close())
	listener, err := net.Listen("tcp4", h.plugin.listener.Addr().String())
	require.NoError(t, err)
	_ = listener.Close()
}

func TestStandaloneSocks5UDPCloseDuringSetup(t *testing.T) {
	relay, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)
	defer relay.Close()
	p, err := NewSocks5UDPPlugin(PluginContext{
		ProxyType: "xudp", SecretKey: "secret",
		DialDatagram: func(ctx context.Context) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "udp4", relay.LocalAddr().String())
		},
	}, &v1.Socks5UDPVisitorPluginOptions{BindAddr: "127.0.0.1"})
	require.NoError(t, err)
	plugin := p.(*Socks5UDPPlugin)
	t.Cleanup(func() { _ = plugin.Close() })
	plugin.Start()
	client, err := net.Dial("tcp4", plugin.listener.Addr().String())
	require.NoError(t, err)
	defer client.Close()
	_, err = client.Write([]byte{5, 1, 0})
	require.NoError(t, err)
	require.NoError(t, relay.SetReadDeadline(time.Now().Add(time.Second)))
	_, _, err = relay.ReadFromUDP(make([]byte, 4096))
	require.NoError(t, err)
	done := make(chan struct{})
	go func() { _ = plugin.Close(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Close did not cancel standalone tunnel setup")
	}
	require.NoError(t, client.SetReadDeadline(time.Now().Add(time.Second)))
	_, err = client.Read(make([]byte, 1))
	require.ErrorIs(t, err, io.EOF)
}

func TestStandaloneSocks5UDPRejectsInvalidPacketBudgetBeforeListening(t *testing.T) {
	for _, packetSize := range []int{127, 65536} {
		p, err := NewSocks5UDPPlugin(PluginContext{
			ProxyType: "sudp", SecretKey: "secret", UDPPacketSize: packetSize,
			DialDatagram: func(context.Context) (net.Conn, error) { return nil, net.ErrClosed },
		}, &v1.Socks5UDPVisitorPluginOptions{BindAddr: "127.0.0.1"})
		require.Nil(t, p)
		require.ErrorContains(t, err, "packet size")
	}
}

func TestStandaloneSocks5UDPDisconnectCancelsDial(t *testing.T) {
	for _, overflow := range []bool{false, true} {
		name := "disconnect"
		if overflow {
			name = "excess_control_input"
		}
		t.Run(name, func(t *testing.T) {
			started := make(chan struct{})
			canceled := make(chan struct{})
			p, err := NewSocks5UDPPlugin(PluginContext{
				ProxyType: "xudp", SecretKey: "secret",
				DialDatagram: func(ctx context.Context) (net.Conn, error) {
					close(started)
					<-ctx.Done()
					close(canceled)
					return nil, ctx.Err()
				},
			}, &v1.Socks5UDPVisitorPluginOptions{BindAddr: "127.0.0.1"})
			require.NoError(t, err)
			plugin := p.(*Socks5UDPPlugin)
			plugin.Start()
			t.Cleanup(func() { _ = plugin.Close() })
			client, err := net.Dial("tcp4", plugin.listener.Addr().String())
			require.NoError(t, err)
			defer client.Close()
			_, err = client.Write([]byte{5, 1, 0})
			require.NoError(t, err)
			select {
			case <-started:
			case <-time.After(time.Second):
				t.Fatal("datagram dial did not start")
			}
			if overflow {
				_, err = client.Write(make([]byte, 1025))
				require.NoError(t, err)
			} else {
				require.NoError(t, client.Close())
			}
			select {
			case <-canceled:
			case <-time.After(time.Second):
				t.Fatal("local control termination did not cancel datagram dial")
			}
			require.Eventually(t, func() bool {
				plugin.mu.Lock()
				defer plugin.mu.Unlock()
				return len(plugin.clients) == 0
			}, time.Second, time.Millisecond)
		})
	}
}

func TestStandaloneSocks5UDPDisconnectReleasesPendingNegotiation(t *testing.T) {
	blackhole, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)
	defer blackhole.Close()
	localAddrs := make(chan *net.UDPAddr, 1)
	p, err := NewSocks5UDPPlugin(PluginContext{
		ProxyType: "sudp", SecretKey: "secret",
		DialDatagram: func(ctx context.Context) (net.Conn, error) {
			conn, err := (&net.Dialer{}).DialContext(ctx, "udp4", blackhole.LocalAddr().String())
			if err == nil {
				localAddrs <- conn.LocalAddr().(*net.UDPAddr)
			}
			return conn, err
		},
	}, &v1.Socks5UDPVisitorPluginOptions{BindAddr: "127.0.0.1"})
	require.NoError(t, err)
	plugin := p.(*Socks5UDPPlugin)
	plugin.Start()
	t.Cleanup(func() { _ = plugin.Close() })
	for _, pipelined := range []bool{false, true} {
		client, err := net.Dial("tcp4", plugin.listener.Addr().String())
		require.NoError(t, err)
		t.Cleanup(func() { _ = client.Close() })
		greeting := []byte{5, 1, 0}
		if pipelined {
			// Input queued during negotiation must not hide a subsequent EOF.
			greeting = append(greeting, 5, 3, 0, 1, 0, 0, 0, 0, 0, 0)
		}
		_, err = client.Write(greeting)
		require.NoError(t, err)
		require.NoError(t, blackhole.SetReadDeadline(time.Now().Add(time.Second)))
		_, _, err = blackhole.ReadFromUDP(make([]byte, 1500))
		require.NoError(t, err)
		localAddr := <-localAddrs
		require.NoError(t, client.Close())
		require.Eventually(t, func() bool {
			plugin.mu.Lock()
			defer plugin.mu.Unlock()
			return len(plugin.clients) == 0
		}, time.Second, time.Millisecond, "disconnected application retained a pending client slot")
		// The upstream socket is released with the slot, rather than being left
		// to retry HELLO until the 60-second setup timeout.
		rebound, err := net.ListenUDP("udp4", localAddr)
		require.NoError(t, err)
		_ = rebound.Close()
	}
}

func TestStandaloneSocks5UDPPipelinedHandshake(t *testing.T) {
	for _, authenticated := range []bool{false, true} {
		for _, fragmented := range []bool{false, true} {
			username, password := "", ""
			method := byte(0)
			if authenticated {
				username, password = strings.Repeat("u", 255), strings.Repeat("p", 255)
				method = 2
			}
			h := newStandaloneSocks5UDPHarness(t, username, password, 0)
			client, err := net.Dial("tcp4", h.plugin.listener.Addr().String())
			require.NoError(t, err)
			t.Cleanup(func() { _ = client.Close() })
			require.NoError(t, client.SetDeadline(time.Now().Add(3*time.Second)))
			var handshake bytes.Buffer
			handshake.Write([]byte{5, 1, method})
			if authenticated {
				handshake.Write([]byte{1, 255})
				handshake.WriteString(username)
				handshake.WriteByte(255)
				handshake.WriteString(password)
			}
			require.NoError(t, socks5udp.WriteRequest(&handshake, socks5udp.CmdUDPAssociate, socks5udp.Address{}))
			if fragmented {
				for _, b := range handshake.Bytes() {
					_, err = client.Write([]byte{b})
					require.NoError(t, err)
				}
			} else {
				_, err = client.Write(handshake.Bytes())
				require.NoError(t, err)
			}
			var reply [2]byte
			_, err = io.ReadFull(client, reply[:])
			require.NoError(t, err)
			require.Equal(t, [2]byte{5, method}, reply)
			if authenticated {
				_, err = io.ReadFull(client, reply[:])
				require.NoError(t, err)
				require.Equal(t, [2]byte{1, 0}, reply)
			}
			status, bound, err := socks5udp.ReadReply(client)
			require.NoError(t, err)
			require.Zero(t, status)
			relay, err := net.ResolveUDPAddr("udp", bound.String())
			require.NoError(t, err)
			socks5Exchange(t, socks5UDPClient(t, net.IPv4(127, 0, 0, 1)), relay, socks5UDPEcho(t), "pipelined-handshake")
		}
	}
}
