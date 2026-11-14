// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0.

package socks5udp

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"io"
	"math"
	"net"
	"sync"
	"time"
)

type DatagramClientOptions struct {
	SecretKey  string
	PacketSize int
	// RenewInterval may request more frequent return-route refreshes. It is
	// always bounded by one third of the provider's advertised session lease.
	RenewInterval time.Duration
}

type sessionPendingRequest struct {
	mode     byte
	kind     byte
	response chan sessionFrame
}

// DatagramClient owns one connected UDP socket to a local SUDP/XUDP visitor.
// Negotiation and authentication are handled by the provider. After opening,
// the client renews its lease independently of application traffic, allowing
// receive-only applications to survive P2P/relay changes.
type DatagramClient struct {
	conn        net.Conn
	opts        DatagramClientOptions
	id          Token
	bootIn      *sessionCipher
	bootOut     *sessionCipher
	ctx         context.Context
	cancel      context.CancelFunc
	mu          sync.Mutex
	closed      bool
	err         error
	negotiated  bool
	method      byte
	cookie      []byte
	authed      bool
	in          *sessionCipher
	out         *sessionCipher
	seq         uint64
	replay      replayWindow
	lease       time.Duration
	lastAlive   time.Time
	pending     map[uint64]sessionPendingRequest
	packets     chan []byte
	writeMu     sync.Mutex
	handshakeMu sync.Mutex
	workers     sync.WaitGroup
	closeOnce   sync.Once
}

func NewDatagramClient(conn net.Conn, options DatagramClientOptions) (*DatagramClient, error) {
	if conn == nil {
		return nil, errors.New("SOCKS5 session requires a datagram connection")
	}
	if options.PacketSize <= 0 {
		options.PacketSize = 1500
	}
	if options.PacketSize < 128 || options.PacketSize > 65535 {
		return nil, errors.New("SOCKS5 session packet size must be between 128 and 65535")
	}
	in, err := newSessionCipher(options.SecretKey, nil, "server-to-client", true)
	if err != nil {
		return nil, err
	}
	out, err := newSessionCipher(options.SecretKey, nil, "client-to-server", true)
	if err != nil {
		return nil, err
	}
	c := &DatagramClient{
		conn: conn, opts: options, bootIn: in, bootOut: out,
		pending: make(map[uint64]sessionPendingRequest), packets: make(chan []byte, 64),
	}
	if _, err := rand.Read(c.id[:]); err != nil {
		return nil, err
	}
	c.ctx, c.cancel = context.WithCancel(context.Background())
	c.workers.Add(1)
	go c.readLoop()
	return c, nil
}

func (c *DatagramClient) Negotiate(ctx context.Context, methods []byte) (byte, error) {
	c.handshakeMu.Lock()
	defer c.handshakeMu.Unlock()
	if len(methods) == 0 || len(methods) > 255 {
		return 0xff, ErrInvalidPacket
	}
	c.mu.Lock()
	if c.negotiated || c.authed {
		c.mu.Unlock()
		return 0xff, errors.New("SOCKS5 session already negotiated")
	}
	c.mu.Unlock()
	response, err := c.request(ctx, sessionBootstrap, sessionHello, sessionChallenge, methods, false)
	if err != nil {
		return 0xff, err
	}
	if len(response.payload) != sessionCookieSize+1 ||
		(response.payload[0] != 0 && response.payload[0] != 2 && response.payload[0] != 0xff) {
		return 0xff, ErrInvalidPacket
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return 0xff, c.err
	}
	c.negotiated = true
	c.method = response.payload[0]
	c.cookie = append([]byte(nil), response.payload[1:]...)
	return c.method, nil
}

// Authenticate opens the remote association. Call it for no-auth (method 0)
// too, with empty credentials; the provider remains authoritative for policy.
func (c *DatagramClient) Authenticate(ctx context.Context, username, password string) error {
	c.handshakeMu.Lock()
	defer c.handshakeMu.Unlock()
	if len(username) > 255 || len(password) > 255 {
		return ErrInvalidPacket
	}
	c.mu.Lock()
	if !c.negotiated || c.authed || c.method == 0xff {
		c.mu.Unlock()
		return ErrAuthentication
	}
	payload := append([]byte(nil), c.cookie...)
	c.mu.Unlock()
	payload = append(payload, byte(len(username)))
	payload = append(payload, username...)
	payload = append(payload, byte(len(password)))
	payload = append(payload, password...)
	response, err := c.request(ctx, sessionBootstrap, sessionOpen, sessionOpened, payload, false)
	if err != nil {
		return err
	}
	if len(response.payload) == 0 {
		return ErrInvalidPacket
	}
	if err := sessionStatusError(response.payload[0]); err != nil {
		return err
	}
	if len(response.payload) != 37 {
		return ErrInvalidPacket
	}
	lease := time.Duration(binary.BigEndian.Uint32(response.payload[33:37])) * time.Millisecond
	if lease < 100*time.Millisecond || lease > 24*time.Hour {
		return ErrInvalidPacket
	}
	keySalt := make([]byte, 0, len(c.id)+32)
	keySalt = append(keySalt, c.id[:]...)
	keySalt = append(keySalt, response.payload[1:33]...)
	in, err := newSessionCipher(c.opts.SecretKey, keySalt, "server-to-client", false)
	if err != nil {
		return err
	}
	out, err := newSessionCipher(c.opts.SecretKey, keySalt, "client-to-server", false)
	if err != nil {
		return err
	}
	c.mu.Lock()
	if c.closed {
		err = c.err
		c.mu.Unlock()
		return err
	}
	c.in, c.out, c.lease = in, out, lease
	c.authed, c.lastAlive = true, time.Now()
	c.workers.Add(1)
	c.mu.Unlock()
	go c.renewLoop()
	return nil
}

func (c *DatagramClient) nextFrameLocked(mode, kind byte, payload []byte) ([]byte, uint64, error) {
	if c.seq == math.MaxUint64 {
		return nil, 0, ErrSessionExpired
	}
	c.seq++
	codec := c.bootOut
	if mode == sessionEstablished {
		codec = c.out
		if codec == nil {
			return nil, 0, ErrAuthentication
		}
	}
	packet, err := codec.seal(sessionFrame{id: c.id, mode: mode, seq: c.seq, kind: kind, payload: payload})
	if err == nil && len(packet) > c.opts.PacketSize {
		err = ErrDatagramTooLarge
	}
	return packet, c.seq, err
}

func (c *DatagramClient) write(packet []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_ = c.conn.SetWriteDeadline(time.Now().Add(100 * time.Millisecond))
	n, err := c.conn.Write(packet)
	if err == nil && n != len(packet) {
		err = io.ErrShortWrite
	}
	return err
}

func (c *DatagramClient) request(ctx context.Context, mode, kind, responseKind byte, payload []byte, closing bool) (sessionFrame, error) {
	var zero sessionFrame
	if ctx == nil {
		return zero, errors.New("SOCKS5 session request requires a context")
	}
	c.mu.Lock()
	if c.closed && !closing {
		err := c.err
		c.mu.Unlock()
		return zero, err
	}
	packet, seq, err := c.nextFrameLocked(mode, kind, payload)
	if err != nil {
		c.mu.Unlock()
		return zero, err
	}
	pending := sessionPendingRequest{mode: mode, kind: responseKind, response: make(chan sessionFrame, 1)}
	c.pending[seq] = pending
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		delete(c.pending, seq)
		c.mu.Unlock()
	}()
	interval := 200 * time.Millisecond
	if closing {
		interval = 75 * time.Millisecond
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	done := c.ctx.Done()
	if closing {
		done = nil
	}
	for {
		if err := ctx.Err(); err != nil {
			return zero, err
		}
		// A local UDP visitor can disappear and rebind during recovery.
		// Its transient write errors do not revoke the logical session.
		_ = c.write(packet)
		select {
		case response := <-pending.response:
			return response, nil
		case <-ctx.Done():
			return zero, ctx.Err()
		case <-done:
			return zero, c.Err()
		case <-ticker.C:
		}
	}
}

func (c *DatagramClient) SendPacket(packet []byte) error {
	if _, _, err := ParseUDP(packet); err != nil {
		return err
	}
	c.mu.Lock()
	if c.closed {
		err := c.err
		c.mu.Unlock()
		return err
	}
	if !c.authed {
		c.mu.Unlock()
		return ErrAuthentication
	}
	encoded, _, err := c.nextFrameLocked(sessionEstablished, sessionData, packet)
	c.mu.Unlock()
	if err != nil {
		return err
	}
	return c.write(encoded)
}

func (c *DatagramClient) ReceivePacket(ctx context.Context) ([]byte, error) {
	if err := c.ctx.Err(); err != nil {
		return nil, c.Err()
	}
	select {
	case packet := <-c.packets:
		return packet, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-c.ctx.Done():
		return nil, c.Err()
	}
}

func (c *DatagramClient) Done() <-chan struct{} { return c.ctx.Done() }

func (c *DatagramClient) Err() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.err
}

func (c *DatagramClient) readLoop() {
	defer c.workers.Done()
	buf := make([]byte, c.opts.PacketSize+1)
	for {
		n, err := c.conn.Read(buf)
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				c.terminate(err)
				return
			}
			timer := time.NewTimer(10 * time.Millisecond)
			select {
			case <-c.ctx.Done():
				timer.Stop()
				return
			case <-timer.C:
				continue
			}
		}
		if n > c.opts.PacketSize {
			continue
		}
		header, err := parseSessionHeader(buf[:n])
		if err != nil || header.id != c.id {
			continue
		}
		c.mu.Lock()
		codec := c.bootIn
		if header.mode == sessionEstablished {
			codec = c.in
		}
		c.mu.Unlock()
		if codec == nil {
			continue
		}
		frame, err := codec.open(buf[:n])
		if err != nil {
			continue
		}
		c.mu.Lock()
		if frame.mode == sessionEstablished {
			accepted, _ := c.replay.accept(frame.seq)
			if !accepted {
				c.mu.Unlock()
				continue
			}
		}
		if pending, ok := c.pending[frame.ack]; ok && pending.mode == frame.mode && pending.kind == frame.kind {
			if !c.closed && frame.mode == sessionEstablished {
				c.lastAlive = time.Now()
			}
			select {
			case pending.response <- frame:
			default:
			}
			c.mu.Unlock()
			continue
		}
		if c.closed || frame.mode != sessionEstablished || frame.kind != sessionData || frame.ack != 0 {
			c.mu.Unlock()
			continue
		}
		if _, _, err := ParseUDP(frame.payload); err != nil {
			c.mu.Unlock()
			continue
		}
		c.lastAlive = time.Now()
		c.mu.Unlock()
		select {
		case c.packets <- frame.payload:
		default:
		}
	}
}

func (c *DatagramClient) renewLoop() {
	defer c.workers.Done()
	c.mu.Lock()
	lease := c.lease
	c.mu.Unlock()
	interval := min(lease/3, 10*time.Second)
	if c.opts.RenewInterval > 0 {
		interval = min(interval, c.opts.RenewInterval)
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-c.ctx.Done():
			return
		case <-ticker.C:
			ctx, cancel := context.WithTimeout(c.ctx, min(lease/3, 3*time.Second))
			_, _ = c.request(ctx, sessionEstablished, sessionRenew, sessionRenewed, nil, false)
			cancel()
			c.mu.Lock()
			expired := time.Since(c.lastAlive) >= lease
			c.mu.Unlock()
			if expired {
				c.terminate(ErrSessionExpired)
				return
			}
		}
	}
}

func (c *DatagramClient) terminate(err error) {
	c.mu.Lock()
	if !c.closed {
		c.closed = true
		c.err = err
		c.cancel()
	}
	c.mu.Unlock()
	_ = c.conn.Close()
}

// Close first cancels callers, then retries authenticated CLOSE for at most
// 300ms. If every notification is lost, the provider's lease still expires.
func (c *DatagramClient) Close() error {
	c.closeOnce.Do(func() {
		c.mu.Lock()
		graceful := c.authed && !c.closed
		c.closed = true
		if c.err == nil {
			c.err = net.ErrClosed
		}
		c.cancel()
		c.mu.Unlock()
		if graceful {
			ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
			_, _ = c.request(ctx, sessionEstablished, sessionClose, sessionClosed, nil, true)
			cancel()
		}
		_ = c.conn.Close()
		c.workers.Wait()
	})
	return nil
}
