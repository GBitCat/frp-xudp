// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

//go:build !frps

package visitor

import (
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/plugin/socks5udp"
)

type socks5UDPReply struct {
	data []byte
	addr *net.UDPAddr
}

type socks5UDPHarness struct {
	plugin   *Socks5UDPPlugin
	endpoint *socks5udp.Endpoint
	packets  chan []byte
}

// The loopback relay stands in for the unchanged SUDP/XUDP visitor data path.
// A real Endpoint handles both the control connection and the datagram egress.
func newSocks5UDPHarness(t *testing.T, username, password string) *socks5UDPHarness {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	endpoint := socks5udp.NewEndpoint(socks5udp.EndpointOptions{})
	relay, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)
	replies := make(chan socks5UDPReply, 128)
	packets := make(chan []byte, 128)
	var workers sync.WaitGroup
	workers.Add(2)
	go func() {
		defer workers.Done()
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
			_ = endpoint.HandlePacket(ctx, buf[:n], func(data []byte) {
				select {
				case replies <- socks5UDPReply{data: data, addr: addr}:
				default:
				}
			})
		}
	}()
	go func() {
		defer workers.Done()
		for {
			select {
			case <-ctx.Done():
				return
			case reply := <-replies:
				_, _ = relay.WriteToUDP(reply.data, reply.addr)
			}
		}
	}()
	p, err := NewSocks5UDPPlugin(PluginContext{
		Ctx:           ctx,
		UDPPacketSize: 1500,
		SendConnToVisitor: func(conn net.Conn) {
			workers.Go(func() {
				_ = socks5udp.ServeControl(ctx, conn, socks5udp.ControlOptions{
					Username: username, Password: password, Endpoint: endpoint,
				})
			})
		},
	}, &v1.Socks5UDPVisitorPluginOptions{
		BindAddr:       "127.0.0.1",
		UDPVisitorAddr: relay.LocalAddr().String(),
	})
	require.NoError(t, err)
	plugin := p.(*Socks5UDPPlugin)
	plugin.Start()
	t.Cleanup(func() {
		_ = plugin.Close()
		_ = endpoint.Close()
		cancel()
		_ = relay.Close()
		workers.Wait()
	})
	return &socks5UDPHarness{plugin: plugin, endpoint: endpoint, packets: packets}
}

func (h *socks5UDPHarness) dial(t *testing.T, username, password string) net.Conn {
	t.Helper()
	conn, err := net.DialTimeout("tcp", h.plugin.listener.Addr().String(), time.Second)
	require.NoError(t, err)
	t.Cleanup(func() { _ = conn.Close() })
	require.NoError(t, conn.SetDeadline(time.Now().Add(3*time.Second)))
	method := byte(0)
	if username != "" || password != "" {
		method = 2
	}
	_, err = conn.Write([]byte{5, 1, method})
	require.NoError(t, err)
	var response [2]byte
	_, err = io.ReadFull(conn, response[:])
	require.NoError(t, err)
	require.Equal(t, [2]byte{5, method}, response)
	if method == 2 {
		frame := append([]byte{1, byte(len(username))}, []byte(username)...)
		frame = append(frame, byte(len(password)))
		frame = append(frame, []byte(password)...)
		_, err = conn.Write(frame)
		require.NoError(t, err)
		_, err = io.ReadFull(conn, response[:])
		require.NoError(t, err)
		require.Equal(t, [2]byte{1, 0}, response)
	}
	return conn
}

func socks5Associate(t *testing.T, control net.Conn, source socks5udp.Address) *net.UDPAddr {
	t.Helper()
	require.NoError(t, socks5udp.WriteRequest(control, socks5udp.CmdUDPAssociate, source))
	reply, bound, err := socks5udp.ReadReply(control)
	require.NoError(t, err)
	require.Zero(t, reply)
	addr, err := net.ResolveUDPAddr("udp", bound.String())
	require.NoError(t, err)
	require.True(t, addr.IP.IsLoopback())
	require.Positive(t, addr.Port)
	return addr
}

func socks5UDPEcho(t *testing.T) *net.UDPAddr {
	t.Helper()
	socket, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)
	done := make(chan struct{})
	go func() {
		defer close(done)
		buf := make([]byte, 65535)
		for {
			n, addr, err := socket.ReadFromUDP(buf)
			if err != nil {
				return
			}
			_, _ = socket.WriteToUDP(buf[:n], addr)
		}
	}()
	t.Cleanup(func() { _ = socket.Close(); <-done })
	return socket.LocalAddr().(*net.UDPAddr)
}

func socks5UDPClient(t *testing.T, sourceIP net.IP) *net.UDPConn {
	t.Helper()
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: sourceIP})
	require.NoError(t, err)
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

func socks5Exchange(t *testing.T, client *net.UDPConn, relay, target *net.UDPAddr, payload string) {
	t.Helper()
	address := socks5udp.AddressFromNetAddr(target)
	packet, err := socks5udp.BuildUDP(address, []byte(payload))
	require.NoError(t, err)
	require.NoError(t, client.SetDeadline(time.Now().Add(2*time.Second)))
	_, err = client.WriteToUDP(packet, relay)
	require.NoError(t, err)
	buf := make([]byte, 65535)
	n, _, err := client.ReadFromUDP(buf)
	require.NoError(t, err)
	actual, data, err := socks5udp.ParseUDP(buf[:n])
	require.NoError(t, err)
	require.Equal(t, address, actual)
	require.Equal(t, payload, string(data))
}

func socks5ExpectDropped(t *testing.T, client *net.UDPConn, relay *net.UDPAddr, packet []byte) {
	t.Helper()
	require.NoError(t, client.SetDeadline(time.Now().Add(100*time.Millisecond)))
	_, err := client.WriteToUDP(packet, relay)
	require.NoError(t, err)
	_, _, err = client.ReadFromUDP(make([]byte, 4096))
	var timeout net.Error
	require.ErrorAs(t, err, &timeout)
	require.True(t, timeout.Timeout())
}

func TestSocks5UDPVisitorConnectAndAuthentication(t *testing.T) {
	for _, credentials := range [][2]string{{"", ""}, {"user", "secret"}, {"user", ""}, {"", "secret"}} {
		t.Run(credentials[0]+"/"+credentials[1], func(t *testing.T) {
			h := newSocks5UDPHarness(t, credentials[0], credentials[1])
			listener, err := net.Listen("tcp4", "127.0.0.1:0")
			require.NoError(t, err)
			t.Cleanup(func() { _ = listener.Close() })
			done := make(chan struct{})
			go func() {
				defer close(done)
				conn, err := listener.Accept()
				if err != nil {
					return
				}
				defer conn.Close()
				_, _ = io.Copy(conn, conn)
			}()
			client := h.dial(t, credentials[0], credentials[1])
			target := socks5udp.AddressFromNetAddr(listener.Addr())
			target.Host = "localhost"
			require.NoError(t, socks5udp.WriteRequest(client, socks5udp.CmdConnect, target))
			reply, _, err := socks5udp.ReadReply(client)
			require.NoError(t, err)
			require.Zero(t, reply)
			_, err = client.Write([]byte("tcp-through-provider"))
			require.NoError(t, err)
			result := make([]byte, len("tcp-through-provider"))
			_, err = io.ReadFull(client, result)
			require.NoError(t, err)
			require.Equal(t, "tcp-through-provider", string(result))
			_ = client.Close()
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("provider target was not closed")
			}
		})
	}
}

func TestSocks5UDPVisitorRejectsAuthentication(t *testing.T) {
	h := newSocks5UDPHarness(t, "user", "secret")
	client, err := net.Dial("tcp", h.plugin.listener.Addr().String())
	require.NoError(t, err)
	defer client.Close()
	require.NoError(t, client.SetDeadline(time.Now().Add(time.Second)))
	_, err = client.Write([]byte{5, 1, 0})
	require.NoError(t, err)
	var reply [2]byte
	_, err = io.ReadFull(client, reply[:])
	require.NoError(t, err)
	require.Equal(t, [2]byte{5, 255}, reply)

	client2, err := net.Dial("tcp", h.plugin.listener.Addr().String())
	require.NoError(t, err)
	defer client2.Close()
	require.NoError(t, client2.SetDeadline(time.Now().Add(time.Second)))
	_, err = client2.Write([]byte{5, 1, 2})
	require.NoError(t, err)
	_, err = io.ReadFull(client2, reply[:])
	require.NoError(t, err)
	_, err = client2.Write([]byte{1, 4, 'u', 's', 'e', 'r', 3, 'b', 'a', 'd'})
	require.NoError(t, err)
	_, err = io.ReadFull(client2, reply[:])
	require.NoError(t, err)
	require.Equal(t, [2]byte{1, 1}, reply)
}

func TestSocks5UDPVisitorAssociationsAndRevocation(t *testing.T) {
	h := newSocks5UDPHarness(t, "user", "secret")
	target := socks5UDPEcho(t)
	target2 := socks5UDPEcho(t)
	control := h.dial(t, "user", "secret")
	control2 := h.dial(t, "user", "secret")
	bound := socks5Associate(t, control, socks5udp.Address{})
	bound2 := socks5Associate(t, control2, socks5udp.Address{})
	require.NotEqual(t, bound.Port, bound2.Port)
	client := socks5UDPClient(t, net.IPv4(127, 0, 0, 1))
	client2 := socks5UDPClient(t, net.IPv4(127, 0, 0, 1))
	socks5Exchange(t, client, bound, target, "first")
	socks5Exchange(t, client2, bound2, target, "second")
	socks5Exchange(t, client, bound, target2, "another-target")
	// Ignore periodic bindings and packets for the other association when
	// selecting the capability whose control connection is being closed.
	var packet []byte
	for packet == nil {
		select {
		case candidate := <-h.packets:
			_, payload, err := socks5udp.DecodeDatagram(candidate)
			require.NoError(t, err)
			_, data, err := socks5udp.ParseUDP(payload)
			if err == nil && string(data) == "first" {
				packet = candidate
			}
		case <-time.After(time.Second):
			t.Fatal("first association's data frame was not forwarded")
		}
	}
	require.NoError(t, control.Close())
	require.Eventually(t, func() bool {
		return errors.Is(h.endpoint.HandlePacket(context.Background(), packet, func([]byte) {}), socks5udp.ErrAssociationNotFound)
	}, time.Second, 5*time.Millisecond)
	socks5Exchange(t, client2, bound2, target, "second-remains-live")
}

func TestSocks5UDPVisitorSourceBindingAndInvalidPackets(t *testing.T) {
	h := newSocks5UDPHarness(t, "", "")
	target := socks5UDPEcho(t)
	control := h.dial(t, "", "")
	client := socks5UDPClient(t, net.IPv4(127, 0, 0, 1))
	bound := socks5Associate(t, control, socks5udp.Address{
		Host: "0.0.0.0", Port: uint16(client.LocalAddr().(*net.UDPAddr).Port),
	})
	packet, err := socks5udp.BuildUDP(socks5udp.AddressFromNetAddr(target), []byte("test"))
	require.NoError(t, err)
	wrongPort := socks5UDPClient(t, net.IPv4(127, 0, 0, 1))
	socks5ExpectDropped(t, wrongPort, bound, packet)
	wrongIP := socks5UDPClient(t, net.IPv4(127, 0, 0, 2))
	socks5ExpectDropped(t, wrongIP, bound, packet)
	fragment := append([]byte(nil), packet...)
	fragment[2] = 1
	socks5ExpectDropped(t, client, bound, fragment)
	oversized, err := socks5udp.BuildUDP(socks5udp.AddressFromNetAddr(target), make([]byte, 1500))
	require.NoError(t, err)
	socks5ExpectDropped(t, client, bound, oversized)
	socks5Exchange(t, client, bound, target, "valid-after-drops")

	control2 := h.dial(t, "", "")
	bound2 := socks5Associate(t, control2, socks5udp.Address{})
	socks5Exchange(t, client, bound2, target, "pin-first-source-port")
	socks5ExpectDropped(t, wrongPort, bound2, packet)
}

func TestSocks5UDPVisitorCloseReleasesSessionsAndListener(t *testing.T) {
	h := newSocks5UDPHarness(t, "", "")
	client, err := net.Dial("tcp", h.plugin.listener.Addr().String())
	require.NoError(t, err)
	defer client.Close()
	control := h.dial(t, "", "")
	bound := socks5Associate(t, control, socks5udp.Address{})
	udpClient := socks5UDPClient(t, net.IPv4(127, 0, 0, 1))
	socks5Exchange(t, udpClient, bound, socks5UDPEcho(t), "before-close")
	done := make(chan struct{})
	go func() { _ = h.plugin.Close(); _ = h.plugin.Close(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("plugin Close blocked")
	}
	for _, conn := range []net.Conn{client, control} {
		require.NoError(t, conn.SetReadDeadline(time.Now().Add(time.Second)))
		_, err := conn.Read(make([]byte, 1))
		require.Error(t, err)
	}
	listener, err := net.Listen("tcp", h.plugin.listener.Addr().String())
	require.NoError(t, err)
	_ = listener.Close()
	udp, err := net.ListenUDP("udp", bound)
	require.NoError(t, err)
	_ = udp.Close()
}

func TestSocks5UDPVisitorBindsWithoutApplicationTrafficAndStopsOnClose(t *testing.T) {
	h := newSocks5UDPHarness(t, "", "")
	control := h.dial(t, "", "")
	_ = socks5Associate(t, control, socks5udp.Address{})
	readBinding := func(timeout time.Duration) socks5udp.Token {
		t.Helper()
		select {
		case packet := <-h.packets:
			token, payload, err := socks5udp.DecodeDatagram(packet)
			require.NoError(t, err)
			require.Empty(t, payload, "binding must not carry target service data")
			require.NotEqual(t, socks5udp.Token{}, token)
			return token
		case <-time.After(timeout):
			t.Fatal("association did not refresh its UDP return route")
			return socks5udp.Token{}
		}
	}
	first := readBinding(time.Second)
	require.Equal(t, first, readBinding(socks5UDPBindInterval+time.Second))
	require.NoError(t, control.Close())
	require.Eventually(t, func() bool {
		h.plugin.mu.Lock()
		defer h.plugin.mu.Unlock()
		return len(h.plugin.clients) == 0
	}, time.Second, time.Millisecond)
	select {
	case <-h.packets:
		t.Fatal("closed association kept emitting UDP bindings")
	case <-time.After(socks5UDPBindInterval + 100*time.Millisecond):
	}
}

func TestSocks5UDPVisitorCloseDuringTunnelSetup(t *testing.T) {
	queued := make(chan net.Conn, 1)
	p, err := NewSocks5UDPPlugin(PluginContext{
		SendConnToVisitor: func(conn net.Conn) { queued <- conn },
	}, &v1.Socks5UDPVisitorPluginOptions{BindAddr: "127.0.0.1", UDPVisitorAddr: "127.0.0.1:12345"})
	require.NoError(t, err)
	plugin := p.(*Socks5UDPPlugin)
	t.Cleanup(func() { _ = plugin.Close() })
	plugin.Start()
	client, err := net.Dial("tcp", plugin.listener.Addr().String())
	require.NoError(t, err)
	defer client.Close()
	select {
	case conn := <-queued:
		defer conn.Close()
	case <-time.After(time.Second):
		t.Fatal("visitor did not queue the pending connection")
	}
	done := make(chan struct{})
	go func() { _ = plugin.Close(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Close did not cancel the pending tunnel setup")
	}
	require.NoError(t, client.SetReadDeadline(time.Now().Add(time.Second)))
	_, err = client.Read(make([]byte, 1))
	require.ErrorIs(t, err, io.EOF)
}

func TestSocks5UDPVisitorHandshakeTimeoutAfterTunnelReady(t *testing.T) {
	t.Parallel()
	ready := make(chan struct{})
	var workers sync.WaitGroup
	p, err := NewSocks5UDPPlugin(PluginContext{
		SendConnToVisitor: func(conn net.Conn) {
			workers.Go(func() {
				defer conn.Close()
				// Drain the internal preface without imposing a provider deadline,
				// so only the frontend can end this incomplete client handshake.
				var magic [6]byte
				if _, err := io.ReadFull(conn, magic[:]); err != nil {
					return
				}
				close(ready)
				_, _ = io.Copy(io.Discard, conn)
			})
		},
	}, &v1.Socks5UDPVisitorPluginOptions{BindAddr: "127.0.0.1", UDPVisitorAddr: "127.0.0.1:12345"})
	require.NoError(t, err)
	plugin := p.(*Socks5UDPPlugin)
	t.Cleanup(func() { _ = plugin.Close(); workers.Wait() })
	plugin.Start()
	client, err := net.Dial("tcp", plugin.listener.Addr().String())
	require.NoError(t, err)
	defer client.Close()
	select {
	case <-ready:
	case <-time.After(time.Second):
		t.Fatal("control transport did not consume the preface")
	}
	started := time.Now()
	_, err = client.Write([]byte{5}) // Incomplete two-byte greeting.
	require.NoError(t, err)
	require.NoError(t, client.SetReadDeadline(time.Now().Add(13*time.Second)))
	_, err = client.Read(make([]byte, 1))
	require.ErrorIs(t, err, io.EOF)
	require.InDelta(t, socks5UDPHandshakeTimeout.Seconds(), time.Since(started).Seconds(), 2)
}
