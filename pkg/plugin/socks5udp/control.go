// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

package socks5udp

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"io"
	"net"
	"slices"
	"time"
)

type ControlOptions struct {
	Username string
	Password string
	Endpoint *Endpoint
}

// ServeControl serves one authenticated CONNECT or UDP ASSOCIATE request. It
// owns conn. Successful UDP replies include an internal capability after the
// normal SOCKS5 reply; visitors must consume it before replying to applications.
func ServeControl(ctx context.Context, conn net.Conn, options ControlOptions) error {
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	if err := readMagic(conn); err != nil {
		return err
	}
	if err := authenticate(conn, options); err != nil {
		return err
	}
	command, address, err := ReadRequest(conn)
	if err != nil {
		_ = WriteReply(conn, 8, Address{})
		return err
	}
	switch command {
	case CmdConnect:
		if address.Port == 0 {
			_ = WriteReply(conn, 1, Address{})
			return ErrInvalidPacket
		}
		dialer := net.Dialer{Timeout: 5 * time.Second}
		target, err := dialer.DialContext(ctx, "tcp", address.String())
		if err != nil {
			_ = WriteReply(conn, 5, Address{})
			return err
		}
		defer target.Close()
		if err := WriteReply(conn, 0, AddressFromNetAddr(target.LocalAddr())); err != nil {
			return err
		}
		_ = conn.SetDeadline(time.Time{})
		relay(conn, target)
		return nil
	case CmdUDPAssociate:
		if options.Endpoint == nil {
			_ = WriteReply(conn, 7, Address{})
			return errors.New("SOCKS5 UDP endpoint unavailable")
		}
		a, err := options.Endpoint.addAssociation(ctx, conn)
		if err != nil {
			_ = WriteReply(conn, 1, Address{})
			return err
		}
		defer options.Endpoint.removeAssociation(a)
		if err := WriteReply(conn, 0, Address{}); err != nil {
			return err
		}
		if err := writeAll(conn, a.token[:]); err != nil {
			return err
		}
		_ = conn.SetDeadline(time.Time{})
		// No further data is valid on a UDP association's control connection.
		// EOF, an unexpected byte, or transport cancellation all revoke it.
		var b [1]byte
		_, err = conn.Read(b[:])
		return err
	default:
		_ = WriteReply(conn, 7, Address{})
		return errors.New("SOCKS5 command unsupported")
	}
}

func authenticate(conn io.ReadWriter, options ControlOptions) error {
	var head [2]byte
	if _, err := io.ReadFull(conn, head[:]); err != nil {
		return err
	}
	if head[0] != Version || head[1] == 0 {
		return ErrInvalidPacket
	}
	methods := make([]byte, int(head[1]))
	if _, err := io.ReadFull(conn, methods); err != nil {
		return err
	}
	method := byte(0)
	if options.Username != "" || options.Password != "" {
		method = 2
	}
	if !slices.Contains(methods, method) {
		_ = writeAll(conn, []byte{Version, 0xff})
		return errors.New("no acceptable SOCKS5 authentication method")
	}
	if err := writeAll(conn, []byte{Version, method}); err != nil {
		return err
	}
	if method == 0 {
		return nil
	}
	if _, err := io.ReadFull(conn, head[:]); err != nil {
		return err
	}
	if head[0] != 1 {
		return ErrInvalidPacket
	}
	username := make([]byte, int(head[1]))
	if _, err := io.ReadFull(conn, username); err != nil {
		return err
	}
	var length [1]byte
	if _, err := io.ReadFull(conn, length[:]); err != nil {
		return err
	}
	password := make([]byte, int(length[0]))
	if _, err := io.ReadFull(conn, password); err != nil {
		return err
	}
	u, p := sha256.Sum256(username), sha256.Sum256(password)
	wantU, wantP := sha256.Sum256([]byte(options.Username)), sha256.Sum256([]byte(options.Password))
	if subtle.ConstantTimeCompare(u[:], wantU[:])&subtle.ConstantTimeCompare(p[:], wantP[:]) != 1 {
		_ = writeAll(conn, []byte{1, 1})
		return errors.New("SOCKS5 authentication failed")
	}
	return writeAll(conn, []byte{1, 0})
}

func relay(client, target net.Conn) {
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _ = io.Copy(target, client)
		_ = target.Close()
		_ = client.Close()
	}()
	_, _ = io.Copy(client, target)
	_ = client.Close()
	_ = target.Close()
	<-done
}
