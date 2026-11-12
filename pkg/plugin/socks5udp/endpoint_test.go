package socks5udp

import (
	"context"
	"io"
	"net"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func startControl(t *testing.T, options ControlOptions, methods []byte) (net.Conn, <-chan error, byte) {
	t.Helper()
	server, client := net.Pipe()
	done := make(chan error, 1)
	go func() { done <- ServeControl(context.Background(), server, options) }()
	t.Cleanup(func() { _ = client.Close() })
	require.NoError(t, client.SetDeadline(time.Now().Add(5*time.Second)))
	require.NoError(t, WriteMagic(client))
	require.NoError(t, writeAll(client, append([]byte{Version, byte(len(methods))}, methods...)))
	var reply [2]byte
	_, err := io.ReadFull(client, reply[:])
	require.NoError(t, err)
	require.Equal(t, byte(Version), reply[0])
	return client, done, reply[1]
}

func startAssociation(t *testing.T, endpoint *Endpoint) (net.Conn, Token, <-chan error) {
	t.Helper()
	client, done, method := startControl(t, ControlOptions{Endpoint: endpoint}, []byte{0})
	require.Zero(t, method)
	require.NoError(t, WriteRequest(client, CmdUDPAssociate, Address{}))
	code, _, err := ReadReply(client)
	require.NoError(t, err)
	require.Zero(t, code)
	token, err := ReadToken(client)
	require.NoError(t, err)
	require.NoError(t, client.SetDeadline(time.Time{}))
	return client, token, done
}

func startUDPEcho(t *testing.T) (*net.UDPConn, <-chan string) {
	t.Helper()
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)
	sources := make(chan string, 20)
	done := make(chan struct{})
	go func() {
		defer close(done)
		buffer := make([]byte, 65535)
		for {
			n, addr, err := conn.ReadFromUDP(buffer)
			if err != nil {
				return
			}
			select {
			case sources <- addr.String():
			default:
			}
			_, _ = conn.WriteToUDP(buffer[:n], addr)
		}
	}()
	t.Cleanup(func() { _ = conn.Close(); <-done })
	return conn, sources
}

func readPacket(t *testing.T, ch <-chan []byte) []byte {
	t.Helper()
	select {
	case packet := <-ch:
		return packet
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for UDP response")
		return nil
	}
}

func TestAssociationRouteChangePreservesTargetSocketAndRevoke(t *testing.T) {
	endpoint := NewEndpoint(EndpointOptions{})
	t.Cleanup(func() { require.NoError(t, endpoint.Close()) })
	control, token, done := startAssociation(t, endpoint)
	echo, sources := startUDPEcho(t)
	packet, err := BuildUDP(AddressFromNetAddr(echo.LocalAddr()), []byte("roundtrip"))
	require.NoError(t, err)
	ctxA, cancelA := context.WithCancel(context.Background())
	defer cancelA()
	responsesA := make(chan []byte, 2)
	require.NoError(t, endpoint.HandlePacket(ctxA, EncodeDatagram(token, packet), func(p []byte) { responsesA <- p }))
	gotToken, gotPacket, err := DecodeDatagram(readPacket(t, responsesA))
	require.NoError(t, err)
	require.Equal(t, token, gotToken)
	require.Equal(t, packet, gotPacket)
	sourceA := <-sources
	cancelA()
	responsesB := make(chan []byte, 2)
	require.NoError(t, endpoint.HandlePacket(context.Background(), EncodeDatagram(token, packet), func(p []byte) { responsesB <- p }))
	_, gotPacket, err = DecodeDatagram(readPacket(t, responsesB))
	require.NoError(t, err)
	require.Equal(t, packet, gotPacket)
	require.Equal(t, sourceA, <-sources, "P2P/relay switching must preserve the egress source port")
	require.NoError(t, control.Close())
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("control close did not revoke association")
	}
	require.ErrorIs(t, endpoint.HandlePacket(context.Background(), EncodeDatagram(token, packet), func([]byte) {}), ErrAssociationNotFound)
}

func TestAssociationMultipleTargetsAndInvalidCapability(t *testing.T) {
	endpoint := NewEndpoint(EndpointOptions{})
	t.Cleanup(func() { _ = endpoint.Close() })
	_, token, _ := startAssociation(t, endpoint)
	responses := make(chan []byte, 4)
	for range 2 {
		echo, _ := startUDPEcho(t)
		packet, err := BuildUDP(AddressFromNetAddr(echo.LocalAddr()), []byte("target"))
		require.NoError(t, err)
		require.NoError(t, endpoint.HandlePacket(context.Background(), EncodeDatagram(token, packet), func(p []byte) { responses <- p }))
		_, actual, err := DecodeDatagram(readPacket(t, responses))
		require.NoError(t, err)
		require.Equal(t, packet, actual)
		wrong := token
		wrong[0] ^= 1
		require.ErrorIs(t, endpoint.HandlePacket(context.Background(), EncodeDatagram(wrong, packet), func([]byte) {}), ErrAssociationNotFound)
		packet[2] = 1
		require.ErrorIs(t, endpoint.HandlePacket(context.Background(), EncodeDatagram(token, packet), func([]byte) {}), ErrFragmented)
	}
}

func TestAssociationReplyFromAlternatePortPreservesClientPort(t *testing.T) {
	for _, network := range []string{"udp4", "udp6"} {
		t.Run(network, func(t *testing.T) {
			ip := net.ParseIP("127.0.0.1")
			if network == "udp6" {
				ip = net.IPv6loopback
			}
			requestPort, err := net.ListenUDP(network, &net.UDPAddr{IP: ip})
			if err != nil && network == "udp6" {
				t.Skipf("IPv6 unavailable: %v", err)
			}
			require.NoError(t, err)
			t.Cleanup(func() { _ = requestPort.Close() })
			transferPort, err := net.ListenUDP(network, &net.UDPAddr{IP: ip})
			require.NoError(t, err)
			t.Cleanup(func() { _ = transferPort.Close() })
			endpoint := NewEndpoint(EndpointOptions{})
			t.Cleanup(func() { _ = endpoint.Close() })
			_, token, _ := startAssociation(t, endpoint)
			responses := make(chan []byte, 4)
			send := func(target net.Addr, payload string) {
				packet, buildErr := BuildUDP(AddressFromNetAddr(target), []byte(payload))
				require.NoError(t, buildErr)
				require.NoError(t, endpoint.HandlePacket(context.Background(), EncodeDatagram(token, packet), func(p []byte) {
					responses <- p
				}))
			}
			buffer := make([]byte, 100)
			send(requestPort.LocalAddr(), "read-request")
			require.NoError(t, requestPort.SetReadDeadline(time.Now().Add(time.Second)))
			n, source, err := requestPort.ReadFromUDP(buffer)
			require.NoError(t, err)
			require.Equal(t, "read-request", string(buffer[:n]))
			// TFTP replies from a newly selected transfer port. The SOCKS5
			// reply must expose that actual port to the application.
			_, err = transferPort.WriteToUDP([]byte("data"), source)
			require.NoError(t, err)
			gotToken, packet, err := DecodeDatagram(readPacket(t, responses))
			require.NoError(t, err)
			require.Equal(t, token, gotToken)
			address, payload, err := ParseUDP(packet)
			require.NoError(t, err)
			require.Equal(t, AddressFromNetAddr(transferPort.LocalAddr()), address)
			require.Equal(t, "data", string(payload))
			// Follow-up datagrams to the transfer port must retain the
			// source port that the server learned from the initial request.
			send(transferPort.LocalAddr(), "acknowledgment")
			require.NoError(t, transferPort.SetReadDeadline(time.Now().Add(time.Second)))
			n, followupSource, err := transferPort.ReadFromUDP(buffer)
			require.NoError(t, err)
			require.Equal(t, "acknowledgment", string(buffer[:n]))
			require.Equal(t, source, followupSource)
			_, err = transferPort.WriteToUDP([]byte("next-data"), followupSource)
			require.NoError(t, err)
			_, packet, err = DecodeDatagram(readPacket(t, responses))
			require.NoError(t, err)
			_, payload, err = ParseUDP(packet)
			require.NoError(t, err)
			require.Equal(t, "next-data", string(payload))
		})
	}
}

func TestAssociationRejectsUncontactedSourceIP(t *testing.T) {
	endpoint := NewEndpoint(EndpointOptions{})
	t.Cleanup(func() { _ = endpoint.Close() })
	_, token, _ := startAssociation(t, endpoint)
	target, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	require.NoError(t, err)
	t.Cleanup(func() { _ = target.Close() })
	intruder, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.2")})
	require.NoError(t, err)
	t.Cleanup(func() { _ = intruder.Close() })
	packet, err := BuildUDP(AddressFromNetAddr(target.LocalAddr()), []byte("request"))
	require.NoError(t, err)
	responses := make(chan []byte, 4)
	require.NoError(t, endpoint.HandlePacket(context.Background(), EncodeDatagram(token, packet), func(p []byte) { responses <- p }))
	require.NoError(t, target.SetReadDeadline(time.Now().Add(time.Second)))
	_, source, err := target.ReadFromUDP(make([]byte, 100))
	require.NoError(t, err)
	_, err = intruder.WriteToUDP([]byte("unsolicited"), source)
	require.NoError(t, err)
	select {
	case <-responses:
		t.Fatal("forwarded a datagram from an IP never contacted by this association")
	case <-time.After(50 * time.Millisecond):
	}
	_, err = target.WriteToUDP([]byte("expected"), source)
	require.NoError(t, err)
	_, packet, err = DecodeDatagram(readPacket(t, responses))
	require.NoError(t, err)
	_, payload, err := ParseUDP(packet)
	require.NoError(t, err)
	require.Equal(t, "expected", string(payload))
}

func TestAssociationExpiresInactiveIPWhileSocketRemainsActive(t *testing.T) {
	endpoint := NewEndpoint(EndpointOptions{IdleTimeout: 100 * time.Millisecond, MaxTargetsPerAssociation: 2, MaxTargets: 2})
	t.Cleanup(func() { _ = endpoint.Close() })
	_, token, _ := startAssociation(t, endpoint)
	idle, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	require.NoError(t, err)
	t.Cleanup(func() { _ = idle.Close() })
	active, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.2")})
	require.NoError(t, err)
	t.Cleanup(func() { _ = active.Close() })
	responses := make(chan []byte, 4)
	send := func(target *net.UDPConn) *net.UDPAddr {
		packet, buildErr := BuildUDP(AddressFromNetAddr(target.LocalAddr()), []byte("request"))
		require.NoError(t, buildErr)
		require.NoError(t, endpoint.HandlePacket(context.Background(), EncodeDatagram(token, packet), func(p []byte) { responses <- p }))
		require.NoError(t, target.SetReadDeadline(time.Now().Add(time.Second)))
		_, source, readErr := target.ReadFromUDP(make([]byte, 100))
		require.NoError(t, readErr)
		return source
	}
	source := send(idle)
	for range 10 {
		require.Equal(t, source, send(active))
		time.Sleep(25 * time.Millisecond)
	}
	require.Len(t, endpoint.targetSlots, 1, "an active IP must not retain another IP's expired permission")
	_, err = idle.WriteToUDP([]byte("expired"), source)
	require.NoError(t, err)
	select {
	case <-responses:
		t.Fatal("accepted a reply from an IP whose target permission expired")
	case <-time.After(25 * time.Millisecond):
	}
	_, err = active.WriteToUDP([]byte("active"), source)
	require.NoError(t, err)
	_, packet, err := DecodeDatagram(readPacket(t, responses))
	require.NoError(t, err)
	_, payload, err := ParseUDP(packet)
	require.NoError(t, err)
	require.Equal(t, "active", string(payload))
	// Expiration frees capacity, and contacting that IP again reauthorizes it
	// without changing the association's still-live egress port.
	require.Equal(t, source, send(idle))
	_, err = idle.WriteToUDP([]byte("reauthorized"), source)
	require.NoError(t, err)
	readPacket(t, responses)
}

func TestRouteBindingRestoresReceiveOnlyAssociation(t *testing.T) {
	endpoint := NewEndpoint(EndpointOptions{})
	t.Cleanup(func() { _ = endpoint.Close() })
	_, token, _ := startAssociation(t, endpoint)
	target, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)
	t.Cleanup(func() { _ = target.Close() })
	packet, err := BuildUDP(AddressFromNetAddr(target.LocalAddr()), []byte("subscribe"))
	require.NoError(t, err)
	ctxA, cancelA := context.WithCancel(context.Background())
	defer cancelA()
	responsesA := make(chan []byte, 4)
	require.NoError(t, endpoint.HandlePacket(ctxA, EncodeDatagram(token, packet), func(p []byte) { responsesA <- p }))
	require.NoError(t, target.SetReadDeadline(time.Now().Add(time.Second)))
	buffer := make([]byte, 100)
	n, subscriber, err := target.ReadFromUDP(buffer)
	require.NoError(t, err)
	require.Equal(t, "subscribe", string(buffer[:n]))
	_, err = target.WriteToUDP([]byte("first-event"), subscriber)
	require.NoError(t, err)
	readPacket(t, responsesA)
	cancelA()
	responsesB := make(chan []byte, 4)
	binding := EncodeDatagram(token, nil)
	require.ErrorIs(t, endpoint.HandlePacket(ctxA, binding, func([]byte) {}), context.Canceled)
	require.NoError(t, endpoint.HandlePacket(context.Background(), binding, func(p []byte) { responsesB <- p }))
	// No new application UDP data is sent. The original target subscription
	// still addresses the original egress port after the return route changes.
	_, err = target.WriteToUDP([]byte("after-switch"), subscriber)
	require.NoError(t, err)
	gotToken, udpPacket, err := DecodeDatagram(readPacket(t, responsesB))
	require.NoError(t, err)
	require.Equal(t, token, gotToken)
	address, payload, err := ParseUDP(udpPacket)
	require.NoError(t, err)
	require.Equal(t, AddressFromNetAddr(target.LocalAddr()), address)
	require.Equal(t, "after-switch", string(payload))
	// The binding itself must not become an application datagram.
	require.NoError(t, target.SetReadDeadline(time.Now().Add(30*time.Millisecond)))
	_, _, err = target.ReadFromUDP(buffer)
	require.Error(t, err)
	wrong := token
	wrong[0] ^= 1
	require.ErrorIs(t, endpoint.HandlePacket(context.Background(), EncodeDatagram(wrong, nil), func([]byte) {}), ErrAssociationNotFound)
}

func TestEndpointCloseEndsControlAndTargetSockets(t *testing.T) {
	endpoint := NewEndpoint(EndpointOptions{})
	_, token, done := startAssociation(t, endpoint)
	echo, _ := startUDPEcho(t)
	packet, err := BuildUDP(AddressFromNetAddr(echo.LocalAddr()), []byte("before-close"))
	require.NoError(t, err)
	responses := make(chan []byte, 1)
	require.NoError(t, endpoint.HandlePacket(context.Background(), EncodeDatagram(token, packet), func(p []byte) { responses <- p }))
	readPacket(t, responses)
	require.NoError(t, endpoint.Close())
	require.NoError(t, endpoint.Close())
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("endpoint close did not end control connection")
	}
	require.Empty(t, endpoint.targetSlots)
	require.ErrorIs(t, endpoint.HandlePacket(context.Background(), EncodeDatagram(token, packet), func([]byte) {}), net.ErrClosed)
}

func TestEndpointAssociationLimit(t *testing.T) {
	endpoint := NewEndpoint(EndpointOptions{MaxAssociations: 1})
	t.Cleanup(func() { _ = endpoint.Close() })
	_, _, _ = startAssociation(t, endpoint)
	client, _, method := startControl(t, ControlOptions{Endpoint: endpoint}, []byte{0})
	require.Zero(t, method)
	require.NoError(t, WriteRequest(client, CmdUDPAssociate, Address{}))
	code, _, err := ReadReply(client)
	require.NoError(t, err)
	require.NotZero(t, code)
}

func TestEndpointIdleSocketExpires(t *testing.T) {
	endpoint := NewEndpoint(EndpointOptions{IdleTimeout: 30 * time.Millisecond})
	t.Cleanup(func() { _ = endpoint.Close() })
	_, token, _ := startAssociation(t, endpoint)
	echo, _ := startUDPEcho(t)
	packet, err := BuildUDP(AddressFromNetAddr(echo.LocalAddr()), []byte("idle"))
	require.NoError(t, err)
	responses := make(chan []byte, 1)
	require.NoError(t, endpoint.HandlePacket(context.Background(), EncodeDatagram(token, packet), func(p []byte) { responses <- p }))
	readPacket(t, responses)
	require.Eventually(t, func() bool { return len(endpoint.targetSlots) == 0 }, time.Second, 5*time.Millisecond)
}

func TestControlAuthentication(t *testing.T) {
	for _, tc := range []struct {
		name, username, password string
		success                  bool
	}{
		{"valid", "alice", "secret", true},
		{"wrong-password", "alice", "wrong", false},
		{"wrong-user", "bob", "secret", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			client, _, method := startControl(t, ControlOptions{Username: "alice", Password: "secret"}, []byte{0, 2})
			require.Equal(t, byte(2), method)
			auth := append([]byte{1, byte(len(tc.username))}, tc.username...)
			auth = append(auth, byte(len(tc.password)))
			auth = append(auth, tc.password...)
			require.NoError(t, writeAll(client, auth))
			var reply [2]byte
			_, err := io.ReadFull(client, reply[:])
			require.NoError(t, err)
			require.Equal(t, tc.success, reply[1] == 0)
		})
	}
	client, done, method := startControl(t, ControlOptions{Username: "alice", Password: "secret"}, []byte{0})
	require.Equal(t, byte(0xff), method)
	_ = client.Close()
	require.Error(t, <-done)
}

func TestControlConnect(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	require.NoError(t, err)
	t.Cleanup(func() { _ = listener.Close() })
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_, _ = io.Copy(conn, conn)
	}()
	client, done, method := startControl(t, ControlOptions{}, []byte{0})
	require.Zero(t, method)
	require.NoError(t, WriteRequest(client, CmdConnect, AddressFromNetAddr(listener.Addr())))
	code, _, err := ReadReply(client)
	require.NoError(t, err)
	require.Zero(t, code)
	require.NoError(t, writeAll(client, []byte("hello")))
	buffer := make([]byte, 5)
	_, err = io.ReadFull(client, buffer)
	require.NoError(t, err)
	require.Equal(t, []byte("hello"), buffer)
	_ = client.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("CONNECT did not shut down")
	}
}

func TestControlConnectShutdownWithUnresponsiveTarget(t *testing.T) {
	for _, byCancel := range []bool{false, true} {
		t.Run(map[bool]string{false: "client-close", true: "context-cancel"}[byCancel], func(t *testing.T) {
			listener, err := net.Listen("tcp4", "127.0.0.1:0")
			require.NoError(t, err)
			defer listener.Close()
			accepted := make(chan net.Conn, 1)
			go func() {
				conn, err := listener.Accept()
				if err == nil {
					accepted <- conn
				}
			}()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			server, client := net.Pipe()
			defer client.Close()
			done := make(chan error, 1)
			go func() { done <- ServeControl(ctx, server, ControlOptions{}) }()
			require.NoError(t, client.SetDeadline(time.Now().Add(3*time.Second)))
			require.NoError(t, WriteMagic(client))
			require.NoError(t, writeAll(client, []byte{Version, 1, 0}))
			var response [2]byte
			_, err = io.ReadFull(client, response[:])
			require.NoError(t, err)
			require.NoError(t, WriteRequest(client, CmdConnect, AddressFromNetAddr(listener.Addr())))
			code, _, err := ReadReply(client)
			require.NoError(t, err)
			require.Zero(t, code)
			target := <-accepted
			defer target.Close()
			// Keep the accepted target open without reading, sending, or closing
			// after EOF. Closing only its write half would strand the relay.
			if byCancel {
				cancel()
			} else {
				_ = client.Close()
			}
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("CONNECT shutdown waited for target EOF")
			}
		})
	}
}
