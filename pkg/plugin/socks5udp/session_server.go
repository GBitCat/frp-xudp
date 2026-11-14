// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0.

package socks5udp

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"math"
	"net"
	"slices"
	"sync"
	"time"
)

const sessionCookieSize = 41

type DatagramServerOptions struct {
	SecretKey        string
	Username         string
	Password         string
	PacketSize       int
	LeaseTimeout     time.Duration
	HandshakeTimeout time.Duration
	MaxSessions      int
}

// DatagramServer creates independently leased associations on an Endpoint.
// Bootstrap cookies are stateless, while closed-session tombstones prevent an
// authenticated OPEN retransmission from resurrecting a revoked association.
// Close revokes this server's sessions; the caller still owns the Endpoint.
type DatagramServer struct {
	endpoint  *Endpoint
	opts      DatagramServerOptions
	bootIn    *sessionCipher
	bootOut   *sessionCipher
	cookieKey [32]byte
	ctx       context.Context
	cancel    context.CancelFunc
	done      chan struct{}
	mu        sync.Mutex
	closed    bool
	active    int
	records   map[Token]*datagramServerSession
	cleanup   sync.WaitGroup
	closeOnce sync.Once
}

type datagramServerSession struct {
	id            Token
	token         Token
	association   *association
	cookie        []byte
	cookieExpires time.Time
	salt          []byte
	in            *sessionCipher
	out           *sessionCipher
	replay        replayWindow
	sendSeq       uint64
	route         returnRoute
	expires       time.Time
	closed        bool
	retireUntil   time.Time
}

func NewDatagramServer(endpoint *Endpoint, options DatagramServerOptions) (*DatagramServer, error) {
	if endpoint == nil {
		return nil, errors.New("SOCKS5 UDP endpoint is required")
	}
	if len(options.Username) > 255 || len(options.Password) > 255 {
		return nil, errors.New("SOCKS5 credentials exceed 255 bytes")
	}
	if options.PacketSize <= 0 {
		options.PacketSize = 1500
	}
	if options.PacketSize < 128 || options.PacketSize > 65535 {
		return nil, errors.New("SOCKS5 session packet size must be between 128 and 65535")
	}
	if options.LeaseTimeout <= 0 {
		options.LeaseTimeout = 60 * time.Second
	}
	if options.HandshakeTimeout <= 0 {
		options.HandshakeTimeout = 30 * time.Second
	}
	if options.LeaseTimeout < 100*time.Millisecond || options.LeaseTimeout > 24*time.Hour ||
		options.HandshakeTimeout < 100*time.Millisecond || options.HandshakeTimeout > 5*time.Minute {
		return nil, errors.New("invalid SOCKS5 session lease or handshake timeout")
	}
	if options.MaxSessions <= 0 {
		options.MaxSessions = endpoint.options.MaxAssociations
	}
	options.MaxSessions = min(options.MaxSessions, endpoint.options.MaxAssociations, 1<<20)
	in, err := newSessionCipher(options.SecretKey, nil, "client-to-server", true)
	if err != nil {
		return nil, err
	}
	out, err := newSessionCipher(options.SecretKey, nil, "server-to-client", true)
	if err != nil {
		return nil, err
	}
	s := &DatagramServer{
		endpoint: endpoint, opts: options, bootIn: in, bootOut: out,
		done: make(chan struct{}), records: make(map[Token]*datagramServerSession),
	}
	if _, err := rand.Read(s.cookieKey[:]); err != nil {
		return nil, err
	}
	s.ctx, s.cancel = context.WithCancel(context.Background())
	go s.sweep()
	return s, nil
}

func (s *DatagramServer) challenge(id Token, method byte, now time.Time) []byte {
	cookie := make([]byte, 9, sessionCookieSize)
	binary.BigEndian.PutUint64(cookie[:8], uint64(now.Add(s.opts.HandshakeTimeout).UnixNano()))
	cookie[8] = method
	mac := hmac.New(sha256.New, s.cookieKey[:])
	_, _ = mac.Write(id[:])
	_, _ = mac.Write(cookie)
	return append(cookie, mac.Sum(nil)...)
}

func (s *DatagramServer) validateCookie(id Token, cookie []byte, now time.Time) (time.Time, bool) {
	if len(cookie) != sessionCookieSize {
		return time.Time{}, false
	}
	mac := hmac.New(sha256.New, s.cookieKey[:])
	_, _ = mac.Write(id[:])
	_, _ = mac.Write(cookie[:9])
	if !hmac.Equal(cookie[9:], mac.Sum(nil)) {
		return time.Time{}, false
	}
	expires := time.Unix(0, int64(binary.BigEndian.Uint64(cookie[:8])))
	return expires, expires.After(now)
}

// HandlePacket handles a bounded control frame or queues an application
// datagram. reply must not block. Its context identifies a transport route,
// not the logical association lifetime, so P2P/relay replacement is harmless.
func (s *DatagramServer) HandlePacket(ctx context.Context, packet []byte, reply func([]byte)) error {
	if ctx == nil || reply == nil || ctx.Err() != nil {
		return ErrInvalidPacket
	}
	if len(packet) > s.opts.PacketSize {
		return ErrDatagramTooLarge
	}
	header, err := parseSessionHeader(packet)
	if err != nil {
		return err
	}
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return net.ErrClosed
	}
	r := s.records[header.id]
	s.mu.Unlock()
	if header.mode == sessionBootstrap {
		frame, err := s.bootIn.open(packet)
		if err != nil || frame.seq == 0 || frame.ack != 0 {
			return ErrInvalidPacket
		}
		return s.handleBootstrap(ctx, frame, reply)
	}
	if r == nil {
		return ErrAssociationNotFound
	}
	frame, err := r.in.open(packet)
	if err != nil || frame.ack != 0 {
		return ErrInvalidPacket
	}
	if frame.kind == sessionData {
		if _, _, err := ParseUDP(frame.payload); err != nil {
			return err
		}
	} else if (frame.kind != sessionRenew && frame.kind != sessionClose) || len(frame.payload) != 0 {
		return ErrInvalidPacket
	}

	var retire *association
	var response []byte
	s.mu.Lock()
	if s.closed || s.records[frame.id] != r {
		s.mu.Unlock()
		return ErrAssociationNotFound
	}
	now := time.Now()
	if !r.closed && !r.expires.After(now) {
		retire = s.retireLocked(r, now)
	}
	if r.closed {
		if frame.kind == sessionClose {
			response, err = s.replyLocked(r, sessionClosed, frame.seq, nil)
		} else {
			err = ErrSessionExpired
		}
		s.mu.Unlock()
		s.finishRetire(retire)
		if err == nil && ctx.Err() == nil {
			reply(response)
		}
		return err
	}
	accepted, newest := r.replay.accept(frame.seq)
	if !accepted {
		// Retrying a control request may recover its lost response, but a
		// duplicate must never extend a lease or change the return route.
		if frame.kind == sessionRenew {
			response, err = s.replyLocked(r, sessionRenewed, frame.seq, nil)
		} else {
			err = ErrReplay
		}
		s.mu.Unlock()
		if err == nil && ctx.Err() == nil {
			reply(response)
		}
		return err
	}
	if newest {
		r.route = returnRoute{ctx: ctx, reply: reply}
	}
	r.expires = now.Add(s.opts.LeaseTimeout)
	switch frame.kind {
	case sessionRenew:
		response, err = s.replyLocked(r, sessionRenewed, frame.seq, nil)
	case sessionClose:
		retire = s.retireLocked(r, now)
		response, err = s.replyLocked(r, sessionClosed, frame.seq, nil)
	}
	s.mu.Unlock()
	s.finishRetire(retire)
	if err != nil {
		return err
	}
	if response != nil {
		if ctx.Err() == nil {
			reply(response)
		}
		return nil
	}
	// All queued jobs carry one stable logical reply callback. Older jobs
	// cannot overwrite the newest authenticated physical route after a switch.
	return s.endpoint.HandlePacket(s.ctx, EncodeDatagram(r.token, frame.payload), func(payload []byte) {
		s.returnData(r, payload)
	})
}

func (s *DatagramServer) handleBootstrap(ctx context.Context, f sessionFrame, reply func([]byte)) error {
	var payload []byte
	kind := sessionChallenge
	switch f.kind {
	case sessionHello:
		if len(f.payload) == 0 || len(f.payload) > 255 {
			return ErrInvalidPacket
		}
		method := byte(0)
		if s.opts.Username != "" || s.opts.Password != "" {
			method = 2
		}
		if !slices.Contains(f.payload, method) {
			method = 0xff
		}
		payload = append([]byte{method}, s.challenge(f.id, method, time.Now())...)
	case sessionOpen:
		kind = sessionOpened
		payload = s.openAssociation(ctx, f, reply)
	default:
		return ErrInvalidPacket
	}
	response, err := s.bootOut.seal(sessionFrame{id: f.id, mode: sessionBootstrap, kind: kind, ack: f.seq, payload: payload})
	if err != nil {
		return err
	}
	s.mu.Lock()
	closed := s.closed
	s.mu.Unlock()
	if !closed && ctx.Err() == nil {
		reply(response)
	}
	return nil
}

func (s *DatagramServer) openAssociation(ctx context.Context, f sessionFrame, reply func([]byte)) []byte {
	if len(f.payload) < sessionCookieSize+2 {
		return []byte{1}
	}
	cookie := f.payload[:sessionCookieSize]
	expires, valid := s.validateCookie(f.id, cookie, time.Now())
	if !valid {
		return []byte{3}
	}
	credentials := f.payload[sessionCookieSize:]
	uLen := int(credentials[0])
	if len(credentials) < uLen+2 || len(credentials) != uLen+2+int(credentials[uLen+1]) {
		return []byte{1}
	}
	method := byte(0)
	if s.opts.Username != "" || s.opts.Password != "" {
		method = 2
	}
	if cookie[8] != method {
		return []byte{1}
	}
	if method == 2 {
		u, p := sha256.Sum256(credentials[1:1+uLen]), sha256.Sum256(credentials[2+uLen:])
		wantU, wantP := sha256.Sum256([]byte(s.opts.Username)), sha256.Sum256([]byte(s.opts.Password))
		if subtle.ConstantTimeCompare(u[:], wantU[:])&subtle.ConstantTimeCompare(p[:], wantP[:]) != 1 {
			return []byte{1}
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	// Recheck expiry while holding the records lock. A validated request may
	// have waited for this lock until its closed-session tombstone was swept;
	// it must not create another association after that cookie expired.
	if s.closed || !expires.After(time.Now()) {
		return []byte{3}
	}
	if r := s.records[f.id]; r != nil {
		if r.closed || !r.expires.After(time.Now()) || !bytes.Equal(r.cookie, cookie) {
			return []byte{3}
		}
		// Duplicate OPEN only resends the original result. It never extends
		// a lease, changes route, or allocates another association.
		return s.openReply(r)
	}
	if s.active >= s.opts.MaxSessions || len(s.records) >= 4*s.opts.MaxSessions {
		return []byte{2}
	}
	salt := make([]byte, 32)
	if _, err := rand.Read(salt); err != nil {
		return []byte{2}
	}
	keySalt := make([]byte, 0, len(f.id)+len(salt))
	keySalt = append(keySalt, f.id[:]...)
	keySalt = append(keySalt, salt...)
	in, err := newSessionCipher(s.opts.SecretKey, keySalt, "client-to-server", false)
	if err != nil {
		return []byte{2}
	}
	out, err := newSessionCipher(s.opts.SecretKey, keySalt, "server-to-client", false)
	if err != nil {
		return []byte{2}
	}
	a, err := s.endpoint.addAssociation(s.ctx, nil)
	if err != nil {
		return []byte{2}
	}
	r := &datagramServerSession{
		id: f.id, token: a.token, association: a, cookie: append([]byte(nil), cookie...),
		cookieExpires: expires, salt: salt, in: in, out: out,
		route: returnRoute{ctx: ctx, reply: reply}, expires: time.Now().Add(s.opts.LeaseTimeout),
	}
	s.records[f.id] = r
	s.active++
	return s.openReply(r)
}

func (s *DatagramServer) openReply(r *datagramServerSession) []byte {
	response := append([]byte{0}, r.salt...)
	return binary.BigEndian.AppendUint32(response, uint32(s.opts.LeaseTimeout/time.Millisecond))
}

func (s *DatagramServer) replyLocked(r *datagramServerSession, kind byte, ack uint64, payload []byte) ([]byte, error) {
	if r.sendSeq == math.MaxUint64 {
		return nil, ErrSessionExpired
	}
	r.sendSeq++
	return r.out.seal(sessionFrame{id: r.id, mode: sessionEstablished, kind: kind, seq: r.sendSeq, ack: ack, payload: payload})
}

func (s *DatagramServer) returnData(r *datagramServerSession, encoded []byte) {
	token, packet, err := DecodeDatagram(encoded)
	if err != nil || token != r.token || len(packet)+SessionDatagramOverhead > s.opts.PacketSize {
		return
	}
	s.mu.Lock()
	if s.closed || r.closed || !r.expires.After(time.Now()) || r.route.ctx == nil || r.route.ctx.Err() != nil {
		s.mu.Unlock()
		return
	}
	route := r.route
	response, err := s.replyLocked(r, sessionData, 0, packet)
	s.mu.Unlock()
	if err == nil && route.ctx.Err() == nil {
		route.reply(response)
	}
}

func (s *DatagramServer) retireLocked(r *datagramServerSession, now time.Time) *association {
	if r.closed {
		return nil
	}
	r.closed = true
	r.retireUntil = now.Add(2 * time.Second)
	if r.cookieExpires.After(r.retireUntil) {
		r.retireUntil = r.cookieExpires
	}
	r.route = returnRoute{}
	s.active--
	a := r.association
	r.association = nil
	s.cleanup.Add(1)
	return a
}

func (s *DatagramServer) finishRetire(a *association) {
	if a == nil {
		return
	}
	s.endpoint.detachAssociation(a)
	go func() {
		a.wg.Wait()
		s.cleanup.Done()
	}()
}

func (s *DatagramServer) sweep() {
	defer close(s.done)
	ticker := time.NewTicker(min(s.opts.LeaseTimeout/4, s.opts.HandshakeTimeout/4, time.Second))
	defer ticker.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return
		case now := <-ticker.C:
			var retired []*association
			s.mu.Lock()
			if s.closed {
				s.mu.Unlock()
				return
			}
			for id, r := range s.records {
				if !r.closed && !r.expires.After(now) {
					retired = append(retired, s.retireLocked(r, now))
				}
				if r.closed && !r.retireUntil.After(now) {
					delete(s.records, id)
				}
			}
			s.mu.Unlock()
			for _, a := range retired {
				s.finishRetire(a)
			}
		}
	}
}

func (s *DatagramServer) Close() error {
	s.closeOnce.Do(func() {
		var retired []*association
		s.mu.Lock()
		s.closed = true
		s.cancel()
		for _, r := range s.records {
			if !r.closed {
				retired = append(retired, s.retireLocked(r, time.Now()))
			}
		}
		s.mu.Unlock()
		for _, a := range retired {
			s.finishRetire(a)
		}
		<-s.done
		s.cleanup.Wait()
	})
	return nil
}
