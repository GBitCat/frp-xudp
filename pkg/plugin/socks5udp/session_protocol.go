// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0.

package socks5udp

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	// SessionDatagramOverhead includes all authenticated framing, the nonce,
	// and the GCM tag; it is additional to the standard SOCKS5 UDP packet.
	SessionDatagramOverhead = 83
	sessionHeaderSize       = 46
	sessionBootstrap        = 0
	sessionEstablished      = 1
)

const (
	sessionHello byte = iota + 1
	sessionChallenge
	sessionOpen
	sessionOpened
	sessionData
	sessionRenew
	sessionRenewed
	sessionClose
	sessionClosed
)

var (
	sessionMagic        = []byte{'F', 'S', '5', 'D', 1}
	ErrDatagramTooLarge = errors.New("SOCKS5 session datagram exceeds packet limit")
	ErrAuthentication   = errors.New("SOCKS5 authentication failed")
	ErrSessionExpired   = errors.New("SOCKS5 UDP session expired")
	ErrReplay           = errors.New("replayed SOCKS5 session datagram")
)

// IsSessionDatagram identifies autonomous sessions, which cannot be mixed with
// legacy bearer-token datagrams on a standalone provider.
func IsSessionDatagram(packet []byte) bool {
	return len(packet) >= len(sessionMagic) && bytes.Equal(packet[:len(sessionMagic)], sessionMagic)
}

type sessionFrame struct {
	id      Token
	mode    byte
	seq     uint64
	kind    byte
	ack     uint64
	payload []byte
}

type sessionCipher struct {
	aead cipher.AEAD
	boot bool
}

func newSessionCipher(secret string, salt []byte, direction string, bootstrap bool) (*sessionCipher, error) {
	if secret == "" {
		return nil, errors.New("autonomous SOCKS5 UDP requires a nonempty secretKey")
	}
	phase := "session"
	if bootstrap {
		phase = "bootstrap"
	}
	key, err := hkdf.Key(sha256.New, []byte(secret), salt, "frp/socks5udp/v1/"+phase+"/"+direction, 32)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	var aead cipher.AEAD
	if bootstrap {
		// Stateless challenge replies have no per-peer sequence counter. Use
		// Go's random-nonce GCM implementation for that bootstrap phase.
		aead, err = cipher.NewGCMWithRandomNonce(block)
	} else {
		aead, err = cipher.NewGCM(block)
	}
	return &sessionCipher{aead: aead, boot: bootstrap}, err
}

func sessionNonce(seq uint64) []byte {
	var nonce [12]byte
	binary.BigEndian.PutUint64(nonce[4:], seq)
	return nonce[:]
}

func (c *sessionCipher) seal(f sessionFrame) ([]byte, error) {
	if !c.boot && f.seq == 0 {
		return nil, ErrInvalidPacket
	}
	header := make([]byte, sessionHeaderSize)
	copy(header, sessionMagic)
	header[5] = f.mode
	copy(header[6:38], f.id[:])
	binary.BigEndian.PutUint64(header[38:46], f.seq)
	plain := make([]byte, 9, 9+len(f.payload))
	plain[0] = f.kind
	binary.BigEndian.PutUint64(plain[1:9], f.ack)
	plain = append(plain, f.payload...)
	if c.boot {
		return c.aead.Seal(header, nil, plain, header), nil
	}
	nonce := sessionNonce(f.seq)
	out := make([]byte, 0, len(header)+len(nonce)+len(plain)+c.aead.Overhead())
	out = append(out, header...)
	out = append(out, nonce...)
	return c.aead.Seal(out, nonce, plain, header), nil
}

func parseSessionHeader(packet []byte) (sessionFrame, error) {
	var f sessionFrame
	if len(packet) < SessionDatagramOverhead || !IsSessionDatagram(packet) || packet[5] > sessionEstablished {
		return f, ErrInvalidPacket
	}
	f.mode = packet[5]
	copy(f.id[:], packet[6:38])
	f.seq = binary.BigEndian.Uint64(packet[38:46])
	return f, nil
}

func (c *sessionCipher) open(packet []byte) (sessionFrame, error) {
	f, err := parseSessionHeader(packet)
	if err != nil || c.boot != (f.mode == sessionBootstrap) {
		return f, ErrInvalidPacket
	}
	var plain []byte
	if c.boot {
		plain, err = c.aead.Open(nil, nil, packet[sessionHeaderSize:], packet[:sessionHeaderSize])
	} else {
		if f.seq == 0 || !bytes.Equal(packet[sessionHeaderSize:sessionHeaderSize+12], sessionNonce(f.seq)) {
			return f, ErrInvalidPacket
		}
		plain, err = c.aead.Open(nil, packet[sessionHeaderSize:sessionHeaderSize+12], packet[sessionHeaderSize+12:], packet[:sessionHeaderSize])
	}
	if err != nil || len(plain) < 9 {
		return f, ErrInvalidPacket
	}
	f.kind = plain[0]
	f.ack = binary.BigEndian.Uint64(plain[1:9])
	f.payload = plain[9:]
	return f, nil
}

// replayWindow accepts bounded reordering while identifying the newest packet
// separately: an older accepted datagram must not restore an obsolete route.
type replayWindow struct {
	latest uint64
	bits   [2]uint64
}

func (w *replayWindow) accept(seq uint64) (accepted, newest bool) {
	if seq == 0 {
		return false, false
	}
	if seq > w.latest {
		delta := seq - w.latest
		switch {
		case delta >= 128:
			w.bits = [2]uint64{1, 0}
		case delta >= 64:
			w.bits = [2]uint64{1, w.bits[0] << (delta - 64)}
		default:
			w.bits[1] = w.bits[1]<<delta | w.bits[0]>>(64-delta)
			w.bits[0] = w.bits[0]<<delta | 1
		}
		w.latest = seq
		return true, true
	}
	delta := w.latest - seq
	if delta >= 128 {
		return false, false
	}
	index, bit := delta/64, uint64(1)<<(delta%64)
	if w.bits[index]&bit != 0 {
		return false, false
	}
	w.bits[index] |= bit
	return true, false
}

func sessionStatusError(status byte) error {
	switch status {
	case 0:
		return nil
	case 1:
		return ErrAuthentication
	case 2:
		return ErrCapacity
	case 3:
		return ErrSessionExpired
	default:
		return fmt.Errorf("SOCKS5 session rejected: %d", status)
	}
}
