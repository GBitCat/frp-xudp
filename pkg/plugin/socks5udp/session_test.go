// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0.

package socks5udp

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

const testSessionSecret = "test-secret-that-is-not-a-password"

func sessionTestServer(t *testing.T, options DatagramServerOptions) *DatagramServer {
	t.Helper()
	if options.SecretKey == "" {
		options.SecretKey = testSessionSecret
	}
	e := NewEndpoint(EndpointOptions{MaxAssociations: 16})
	s, err := NewDatagramServer(e, options)
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, s.Close()); require.NoError(t, e.Close()) })
	return s
}

// The manual peer exposes exact sequence and route selection, without a
// heartbeat racing the cases that intentionally reorder authenticated frames.
type sessionTestPeer struct {
	id       Token
	seq      uint64
	bootOut  *sessionCipher
	bootIn   *sessionCipher
	out      *sessionCipher
	in       *sessionCipher
	cookie   []byte
	requests [][]byte
}

func newSessionTestPeer(t *testing.T) *sessionTestPeer {
	t.Helper()
	p := &sessionTestPeer{}
	_, err := rand.Read(p.id[:])
	require.NoError(t, err)
	p.bootOut, err = newSessionCipher(testSessionSecret, nil, "client-to-server", true)
	require.NoError(t, err)
	p.bootIn, err = newSessionCipher(testSessionSecret, nil, "server-to-client", true)
	require.NoError(t, err)
	return p
}

func (p *sessionTestPeer) packet(t *testing.T, kind byte, payload []byte) []byte {
	t.Helper()
	p.seq++
	mode, codec := byte(sessionBootstrap), p.bootOut
	if kind != sessionHello && kind != sessionOpen {
		mode, codec = sessionEstablished, p.out
	}
	packet, err := codec.seal(sessionFrame{id: p.id, mode: mode, seq: p.seq, kind: kind, payload: payload})
	require.NoError(t, err)
	p.requests = append(p.requests, packet)
	return packet
}

func (p *sessionTestPeer) exchange(t *testing.T, s *DatagramServer, kind byte, payload []byte) sessionFrame {
	t.Helper()
	responses := make(chan []byte, 1)
	require.NoError(t, s.HandlePacket(context.Background(), p.packet(t, kind, payload), func(b []byte) { responses <- b }))
	codec := p.bootIn
	if kind != sessionHello && kind != sessionOpen {
		codec = p.in
	}
	f, err := codec.open(readPacket(t, responses))
	require.NoError(t, err)
	require.Equal(t, p.seq, f.ack)
	return f
}

func (p *sessionTestPeer) open(t *testing.T, s *DatagramServer, username, password string) {
	t.Helper()
	challenge := p.exchange(t, s, sessionHello, []byte{0, 2})
	require.Len(t, challenge.payload, sessionCookieSize+1)
	p.cookie = append([]byte(nil), challenge.payload[1:]...)
	payload := append([]byte(nil), p.cookie...)
	payload = append(payload, byte(len(username)))
	payload = append(payload, username...)
	payload = append(payload, byte(len(password)))
	payload = append(payload, password...)
	opened := p.exchange(t, s, sessionOpen, payload)
	require.Len(t, opened.payload, 37)
	require.Zero(t, opened.payload[0])
	salt := make([]byte, 0, len(p.id)+32)
	salt = append(salt, p.id[:]...)
	salt = append(salt, opened.payload[1:33]...)
	var err error
	p.out, err = newSessionCipher(testSessionSecret, salt, "client-to-server", false)
	require.NoError(t, err)
	p.in, err = newSessionCipher(testSessionSecret, salt, "server-to-client", false)
	require.NoError(t, err)
}

func sessionActive(s *DatagramServer) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.active
}

func TestSessionCipherAuthenticatesEveryWireByteAndSeparatesDirections(t *testing.T) {
	for _, bootstrap := range []bool{false, true} {
		out, err := newSessionCipher(testSessionSecret, []byte("session-salt"), "client-to-server", bootstrap)
		require.NoError(t, err)
		in, err := newSessionCipher(testSessionSecret, []byte("session-salt"), "server-to-client", bootstrap)
		require.NoError(t, err)
		mode := byte(sessionEstablished)
		if bootstrap {
			mode = sessionBootstrap
		}
		packet, err := out.seal(sessionFrame{mode: mode, seq: 7, kind: sessionData, payload: []byte("private credentials and payload")})
		require.NoError(t, err)
		require.Len(t, packet, SessionDatagramOverhead+len("private credentials and payload"))
		require.NotContains(t, string(packet), "private credentials")
		_, err = in.open(packet)
		require.Error(t, err, "a reflected packet must fail direction-specific authentication")
		for i := range packet {
			changed := bytes.Clone(packet)
			changed[i] ^= 1
			_, err = out.open(changed)
			require.Error(t, err, "modified wire byte %d", i)
		}
		decoded, err := out.open(packet)
		require.NoError(t, err)
		require.Equal(t, []byte("private credentials and payload"), decoded.payload)
	}
}

func TestSessionReplayWindow(t *testing.T) {
	var w replayWindow
	for _, seq := range []uint64{1, 2, 65, 64, 3, 128, 127, 256, 255, 200, 199, 257, 385, 384} {
		previous := w.latest
		accepted, newest := w.accept(seq)
		require.True(t, accepted, "first delivery of %d", seq)
		require.Equal(t, seq > previous, newest)
		accepted, newest = w.accept(seq)
		require.False(t, accepted, "duplicate %d", seq)
		require.False(t, newest)
	}
	for _, seq := range []uint64{0, 1, 128, 256, 257} {
		accepted, _ := w.accept(seq)
		require.False(t, accepted, "packet outside window %d", seq)
	}
}

func TestSessionClosedTranscriptCannotReopenAndRestartInvalidatesCookies(t *testing.T) {
	s := sessionTestServer(t, DatagramServerOptions{Username: "user", Password: "password"})
	p := newSessionTestPeer(t)
	p.open(t, s, "user", "password")
	require.Equal(t, 1, sessionActive(s))
	closed := p.exchange(t, s, sessionClose, nil)
	require.Equal(t, sessionClosed, closed.kind)
	require.Zero(t, sessionActive(s))
	for range 3 {
		for _, packet := range p.requests {
			_ = s.HandlePacket(context.Background(), packet, func([]byte) {})
		}
		require.Zero(t, sessionActive(s), "replaying the original handshake must not resurrect its session")
	}
	// A restart has no tombstones, so its fresh cookie-signing key must reject
	// captured OPEN packets even when the configured transport secret matches.
	restarted := sessionTestServer(t, DatagramServerOptions{})
	for _, packet := range p.requests {
		_ = restarted.HandlePacket(context.Background(), packet, func([]byte) {})
	}
	require.Zero(t, sessionActive(restarted))
}

func TestSessionLeaseAndTombstonesBoundResources(t *testing.T) {
	s := sessionTestServer(t, DatagramServerOptions{LeaseTimeout: 100 * time.Millisecond, HandshakeTimeout: 100 * time.Millisecond, MaxSessions: 1})
	p := newSessionTestPeer(t)
	p.open(t, s, "", "")
	require.Eventually(t, func() bool { return sessionActive(s) == 0 }, time.Second, 10*time.Millisecond)
	require.Eventually(t, func() bool {
		s.endpoint.mu.Lock()
		defer s.endpoint.mu.Unlock()
		return len(s.endpoint.associations) == 0
	}, time.Second, time.Millisecond)
	// A captured OPEN cannot renew the expired session, even after its
	// tombstone is garbage collected and its capacity becomes reusable.
	openPacket := p.requests[1]
	s.mu.Lock()
	s.records[p.id].retireUntil = time.Now().Add(-time.Second)
	s.mu.Unlock()
	require.Eventually(t, func() bool {
		s.mu.Lock()
		defer s.mu.Unlock()
		return len(s.records) == 0
	}, time.Second, 10*time.Millisecond)
	require.NoError(t, s.HandlePacket(context.Background(), openPacket, func([]byte) {}))
	require.Zero(t, sessionActive(s))
	for range 4 {
		peer := newSessionTestPeer(t)
		peer.open(t, s, "", "")
		peer.exchange(t, s, sessionClose, nil)
	}
	s.mu.Lock()
	records := len(s.records)
	s.mu.Unlock()
	require.Equal(t, 4, records)
	next := newSessionTestPeer(t)
	challenge := next.exchange(t, s, sessionHello, []byte{0})
	payload := append(bytes.Clone(challenge.payload[1:]), 0, 0)
	response := next.exchange(t, s, sessionOpen, payload)
	require.Equal(t, []byte{2}, response.payload, "closed tombstones count against the bounded handshake capacity")
}

func TestSessionReorderedDataCannotStealNewestReturnRoute(t *testing.T) {
	s := sessionTestServer(t, DatagramServerOptions{})
	p := newSessionTestPeer(t)
	p.open(t, s, "", "")
	target, sources := startUDPEcho(t)
	packet, err := BuildUDP(AddressFromNetAddr(target.LocalAddr()), []byte("ordered"))
	require.NoError(t, err)
	older := p.packet(t, sessionData, packet)
	newer := p.packet(t, sessionRenew, nil)
	oldResponses, newResponses := make(chan []byte, 4), make(chan []byte, 4)
	require.NoError(t, s.HandlePacket(context.Background(), newer, func(b []byte) { newResponses <- b }))
	readPacket(t, newResponses) // renewal acknowledgment
	require.NoError(t, s.HandlePacket(context.Background(), older, func(b []byte) { oldResponses <- b }))
	got, err := p.in.open(readPacket(t, newResponses))
	require.NoError(t, err)
	require.Equal(t, packet, got.payload)
	firstSource := <-sources
	require.Empty(t, oldResponses, "an accepted older data frame must not replace the newest physical route")
	require.ErrorIs(t, s.HandlePacket(context.Background(), older, func([]byte) {}), ErrReplay)
	select {
	case <-sources:
		t.Fatal("replayed application data reached its target")
	case <-time.After(30 * time.Millisecond):
	}
	require.NoError(t, s.HandlePacket(context.Background(), p.packet(t, sessionData, packet), func(b []byte) { newResponses <- b }))
	readPacket(t, newResponses)
	require.Equal(t, firstSource, <-sources, "new routes preserve the target socket")
}

type sessionWireHarness struct {
	server     *DatagramServer
	conn       *net.UDPConn
	mu         sync.Mutex
	requests   [][]byte
	dropOpen   atomic.Int32
	dropClosed atomic.Int32
	dropAll    atomic.Bool
}

func newSessionWireHarness(t *testing.T, options DatagramServerOptions) *sessionWireHarness {
	t.Helper()
	h := &sessionWireHarness{server: sessionTestServer(t, options)}
	var err error
	h.conn, err = net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)
	done := make(chan struct{})
	go func() {
		defer close(done)
		buf := make([]byte, 65536)
		for {
			n, addr, err := h.conn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			packet := bytes.Clone(buf[:n])
			h.mu.Lock()
			h.requests = append(h.requests, packet)
			h.mu.Unlock()
			if h.dropAll.Load() {
				continue
			}
			_ = h.server.HandlePacket(context.Background(), packet, func(response []byte) {
				header, _ := parseSessionHeader(response)
				codec := h.server.bootOut
				if header.mode == sessionEstablished {
					h.server.mu.Lock()
					codec = h.server.records[header.id].out
					h.server.mu.Unlock()
				}
				frame, _ := codec.open(response)
				if frame.kind == sessionOpened && h.dropOpen.Add(-1) >= 0 {
					return
				}
				if frame.kind == sessionClosed && h.dropClosed.Add(-1) >= 0 {
					return
				}
				_, _ = h.conn.WriteToUDP(response, addr)
			})
		}
	}()
	t.Cleanup(func() { _ = h.conn.Close(); <-done })
	return h
}

func (h *sessionWireHarness) client(t *testing.T, options DatagramClientOptions) *DatagramClient {
	t.Helper()
	if options.SecretKey == "" {
		options.SecretKey = testSessionSecret
	}
	conn, err := net.DialUDP("udp4", nil, h.conn.LocalAddr().(*net.UDPAddr))
	require.NoError(t, err)
	c, err := NewDatagramClient(conn, options)
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, c.Close()) })
	return c
}

func TestSessionClientRetriesLostOpenAndCloseAndKeepsLease(t *testing.T) {
	h := newSessionWireHarness(t, DatagramServerOptions{Username: "login-user", Password: "login-password", LeaseTimeout: time.Second})
	h.dropOpen.Store(1)
	h.dropClosed.Store(1)
	c := h.client(t, DatagramClientOptions{RenewInterval: 40 * time.Millisecond})
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	method, err := c.Negotiate(ctx, []byte{0, 2})
	require.NoError(t, err)
	require.Equal(t, byte(2), method)
	require.NoError(t, c.Authenticate(ctx, "login-user", "login-password"))
	require.Equal(t, 1, sessionActive(h.server), "retries must allocate only one association")
	h.mu.Lock()
	for _, packet := range h.requests {
		require.NotContains(t, string(packet), "login-user")
		require.NotContains(t, string(packet), "login-password")
	}
	h.mu.Unlock()
	// No application data is needed to maintain the lease.
	time.Sleep(1100 * time.Millisecond)
	require.Equal(t, 1, sessionActive(h.server))
	require.NoError(t, c.Err())
	target, _ := startUDPEcho(t)
	packet, err := BuildUDP(AddressFromNetAddr(target.LocalAddr()), []byte("encrypted data"))
	require.NoError(t, err)
	require.NoError(t, c.SendPacket(packet))
	got, err := c.ReceivePacket(ctx)
	require.NoError(t, err)
	require.Equal(t, packet, got)
	start := time.Now()
	require.NoError(t, c.Close())
	require.Less(t, time.Since(start), time.Second)
	require.Zero(t, sessionActive(h.server))
	require.Less(t, h.dropClosed.Load(), int32(0), "lost CLOSE acknowledgment must trigger an idempotent retry")
}

func TestSessionClientLostCloseExpiresProviderAndLostRenewExpiresClient(t *testing.T) {
	for _, closeClient := range []bool{false, true} {
		h := newSessionWireHarness(t, DatagramServerOptions{LeaseTimeout: 150 * time.Millisecond})
		c := h.client(t, DatagramClientOptions{RenewInterval: 20 * time.Millisecond})
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		method, err := c.Negotiate(ctx, []byte{0})
		require.NoError(t, err)
		require.Zero(t, method)
		require.NoError(t, c.Authenticate(ctx, "", ""))
		cancel()
		h.dropAll.Store(true)
		if closeClient {
			require.NoError(t, c.Close())
		} else {
			select {
			case <-c.Done():
				require.ErrorIs(t, c.Err(), ErrSessionExpired)
			case <-time.After(time.Second):
				t.Fatal("unreachable provider must expire the local session")
			}
		}
		require.Eventually(t, func() bool { return sessionActive(h.server) == 0 }, time.Second, 10*time.Millisecond)
	}
}

func TestSessionClientRejectsWrongSecretAndOversizedDatagram(t *testing.T) {
	h := newSessionWireHarness(t, DatagramServerOptions{})
	wrong := h.client(t, DatagramClientOptions{SecretKey: "different secret"})
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	_, err := wrong.Negotiate(ctx, []byte{0})
	cancel()
	require.ErrorIs(t, err, context.DeadlineExceeded)
	require.Zero(t, sessionActive(h.server))
	c := h.client(t, DatagramClientOptions{PacketSize: 128})
	ctx, cancel = context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, err = c.Negotiate(ctx, []byte{0})
	require.NoError(t, err)
	require.NoError(t, c.Authenticate(ctx, "", ""))
	packet, err := BuildUDP(Address{Host: "127.0.0.1", Port: 1234}, make([]byte, 128))
	require.NoError(t, err)
	require.ErrorIs(t, c.SendPacket(packet), ErrDatagramTooLarge)
	_, err = NewDatagramServer(h.server.endpoint, DatagramServerOptions{})
	require.Error(t, err, "a transport secret is mandatory even when SOCKS5 authentication is disabled")
}

func TestSessionDuplicateRenewDoesNotExtendLeaseOrRoute(t *testing.T) {
	s := sessionTestServer(t, DatagramServerOptions{LeaseTimeout: 100 * time.Millisecond})
	p := newSessionTestPeer(t)
	p.open(t, s, "", "")
	request := p.packet(t, sessionRenew, nil)
	require.NoError(t, s.HandlePacket(context.Background(), request, func([]byte) {}))
	s.mu.Lock()
	deadline := s.records[p.id].expires
	s.mu.Unlock()
	for range 3 {
		require.NoError(t, s.HandlePacket(context.Background(), request, func([]byte) {}))
	}
	s.mu.Lock()
	afterRetries := s.records[p.id].expires
	s.mu.Unlock()
	require.Equal(t, deadline, afterRetries)
	require.Eventually(t, func() bool { return sessionActive(s) == 0 }, time.Second, 10*time.Millisecond)
	require.ErrorIs(t, s.HandlePacket(context.Background(), request, func([]byte) {}), ErrSessionExpired)
}

func TestSessionCookieBindsIdentityPolicyAndExpiry(t *testing.T) {
	s := sessionTestServer(t, DatagramServerOptions{})
	p := newSessionTestPeer(t)
	now := time.Now()
	cookie := s.challenge(p.id, 0, now)
	_, valid := s.validateCookie(p.id, cookie, now)
	require.True(t, valid)
	other := p.id
	other[0] ^= 1
	_, valid = s.validateCookie(other, cookie, now)
	require.False(t, valid)
	changed := bytes.Clone(cookie)
	changed[8] = 2
	_, valid = s.validateCookie(p.id, changed, now)
	require.False(t, valid)
	expiry := time.Unix(0, int64(binary.BigEndian.Uint64(cookie[:8])))
	_, valid = s.validateCookie(p.id, cookie, expiry)
	require.False(t, valid)
}

func TestSessionOpenWaitingForRecordsLockCannotOutliveCookie(t *testing.T) {
	s := sessionTestServer(t, DatagramServerOptions{HandshakeTimeout: 100 * time.Millisecond})
	p := newSessionTestPeer(t)
	cookie := s.challenge(p.id, 0, time.Now())
	frame := sessionFrame{id: p.id, kind: sessionOpen, payload: append(cookie, 0, 0)}
	started, result := make(chan struct{}), make(chan []byte, 1)
	s.mu.Lock()
	go func() {
		close(started)
		result <- s.openAssociation(context.Background(), frame, func([]byte) {})
	}()
	<-started
	// Cookie authentication may complete before lock acquisition. Its expiry
	// must still be checked at allocation, after tombstones can be swept.
	time.Sleep(150 * time.Millisecond)
	s.mu.Unlock()
	require.Equal(t, []byte{3}, <-result)
	require.Zero(t, sessionActive(s))
}

func TestSessionCloseCancelsPendingNegotiate(t *testing.T) {
	h := newSessionWireHarness(t, DatagramServerOptions{})
	h.dropAll.Store(true)
	c := h.client(t, DatagramClientOptions{})
	done := make(chan error, 1)
	go func() { _, err := c.Negotiate(context.Background(), []byte{0}); done <- err }()
	require.Eventually(t, func() bool {
		h.mu.Lock()
		defer h.mu.Unlock()
		return len(h.requests) > 0
	}, time.Second, time.Millisecond)
	require.NoError(t, c.Close())
	select {
	case err := <-done:
		require.True(t, errors.Is(err, net.ErrClosed))
	case <-time.After(time.Second):
		t.Fatal("Close did not cancel pending negotiation")
	}
}
