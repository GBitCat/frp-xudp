// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

//go:build !frps

package visitor

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"time"

	"github.com/fatedier/frp/pkg/plugin/socks5udp"
)

func (p *Socks5UDPPlugin) startDatagramClient(client net.Conn) {
	p.mu.Lock()
	if p.closed || len(p.clients) >= socks5UDPMaxConnections {
		p.mu.Unlock()
		_ = client.Close()
		return
	}
	// A standalone session has no remote stream to close. The plugin context
	// cancels its handlers, which close their datagram clients concurrently.
	p.clients[client] = nil
	p.workers.Add(1)
	p.mu.Unlock()
	go func() {
		defer p.workers.Done()
		defer func() {
			_ = client.Close()
			p.mu.Lock()
			delete(p.clients, client)
			p.mu.Unlock()
		}()
		p.handleDatagram(client)
	}()
}

func (p *Socks5UDPPlugin) handleDatagram(client net.Conn) {
	ctx, cancel := context.WithCancel(p.ctx)
	defer cancel()
	stopClient := context.AfterFunc(ctx, func() { _ = client.Close() })
	defer stopClient()
	_ = client.SetDeadline(time.Now().Add(socks5UDPHandshakeTimeout))
	methods, err := readSOCKS5Methods(client)
	if err != nil {
		return
	}
	// The first datagram can establish the private visitor transport, including
	// XUDP hole punching and relay fallback. This is separate from client-side
	// protocol deadlines, just as it is for the legacy stream visitor.
	_ = client.SetDeadline(time.Time{})
	// Keep reading the local control connection while transport setup and
	// remote authentication are pending. Its EOF must cancel those requests,
	// even when the peer never answers. The same reader preserves any pipelined
	// credentials/request bytes for the rest of the SOCKS handshake.
	control := newDatagramControlConn(client, cancel)
	defer control.Close()
	setupCtx, setupCancel := context.WithTimeout(ctx, socks5UDPConnectTimeout)
	upstream, err := p.pluginCtx.DialDatagram(setupCtx)
	if err != nil {
		setupCancel()
		return
	}
	session, err := socks5udp.NewDatagramClient(upstream, socks5udp.DatagramClientOptions{
		SecretKey: p.pluginCtx.SecretKey, PacketSize: p.packetSize,
	})
	if err != nil {
		setupCancel()
		_ = upstream.Close()
		return
	}
	defer session.Close()
	method, err := session.Negotiate(setupCtx, methods)
	setupCancel()
	if err != nil {
		return
	}
	deadline := time.Now().Add(socks5UDPHandshakeTimeout)
	_ = client.SetDeadline(deadline)
	if _, err := client.Write([]byte{5, method}); err != nil {
		return
	}
	if method != 0 && method != 2 {
		return
	}
	var username, password string
	if method == 2 {
		username, password, err = readSOCKS5Credentials(control)
		if err != nil {
			return
		}
	}
	authCtx, authCancel := context.WithDeadline(ctx, deadline)
	err = session.Authenticate(authCtx, username, password)
	authCancel()
	if method == 2 {
		status := byte(0)
		if err != nil {
			status = 1
		}
		if _, writeErr := client.Write([]byte{1, status}); writeErr != nil {
			return
		}
	}
	if err != nil {
		return
	}
	command, source, err := socks5udp.ReadRequest(control)
	if err != nil {
		_ = socks5udp.WriteReply(client, 8, socks5udp.Address{})
		return
	}
	if command != socks5udp.CmdUDPAssociate {
		_ = socks5udp.WriteReply(client, 7, socks5udp.Address{})
		return
	}
	p.associateDatagram(ctx, control, session, source)
}

// datagramControlConn has a single network reader so it can observe disconnects
// during a remote round trip without racing the SOCKS protocol reader. After
// the greeting, valid clients send at most 513 authentication bytes and a
// 262-byte request; UDP ASSOCIATE carries no subsequent TCP application data.
// Bound queued bytes rather than reads so fragmented handshakes are supported.
type datagramControlConn struct {
	net.Conn
	mu     sync.Mutex
	ready  *sync.Cond
	buffer bytes.Buffer
	err    error
	done   chan struct{}
}

func newDatagramControlConn(conn net.Conn, cancel context.CancelFunc) *datagramControlConn {
	c := &datagramControlConn{Conn: conn, done: make(chan struct{})}
	c.ready = sync.NewCond(&c.mu)
	go func() {
		defer close(c.done)
		defer cancel()
		var buf [512]byte
		for {
			n, err := conn.Read(buf[:])
			c.mu.Lock()
			if c.buffer.Len()+n > 1024 {
				err = errors.New("SOCKS5 control input exceeds handshake limit")
			} else if n > 0 {
				_, _ = c.buffer.Write(buf[:n])
			}
			c.err = err
			c.ready.Broadcast()
			c.mu.Unlock()
			if err != nil {
				return
			}
		}
	}()
	return c
}

func (c *datagramControlConn) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for c.buffer.Len() == 0 && c.err == nil {
		c.ready.Wait()
	}
	if c.buffer.Len() > 0 {
		return c.buffer.Read(p)
	}
	return 0, c.err
}

func (c *datagramControlConn) Close() error {
	err := c.Conn.Close()
	<-c.done
	return err
}

func readSOCKS5Methods(conn io.Reader) ([]byte, error) {
	var header [2]byte
	if _, err := io.ReadFull(conn, header[:]); err != nil {
		return nil, err
	}
	if header[0] != 5 || header[1] == 0 {
		return nil, errors.New("invalid SOCKS5 greeting")
	}
	methods := make([]byte, int(header[1]))
	_, err := io.ReadFull(conn, methods)
	return methods, err
}

func readSOCKS5Credentials(conn io.Reader) (string, string, error) {
	var header [2]byte
	if _, err := io.ReadFull(conn, header[:]); err != nil {
		return "", "", err
	}
	if header[0] != 1 {
		return "", "", errors.New("invalid SOCKS5 authentication")
	}
	username := make([]byte, int(header[1]))
	if _, err := io.ReadFull(conn, username); err != nil {
		return "", "", err
	}
	var size [1]byte
	if _, err := io.ReadFull(conn, size[:]); err != nil {
		return "", "", err
	}
	password := make([]byte, int(size[0]))
	if _, err := io.ReadFull(conn, password); err != nil {
		return "", "", err
	}
	return string(username), string(password), nil
}

func (p *Socks5UDPPlugin) associateDatagram(ctx context.Context, client net.Conn, session *socks5udp.DatagramClient, source socks5udp.Address) {
	peer, ok := client.RemoteAddr().(*net.TCPAddr)
	if !ok {
		_ = socks5udp.WriteReply(client, 1, socks5udp.Address{})
		return
	}
	sourceIP := net.ParseIP(source.Host)
	if sourceIP == nil || (!sourceIP.IsUnspecified() && !sourceIP.Equal(peer.IP)) {
		_ = socks5udp.WriteReply(client, 2, socks5udp.Address{})
		return
	}
	local, ok := client.LocalAddr().(*net.TCPAddr)
	if !ok {
		return
	}
	udpConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: local.IP, Zone: local.Zone})
	if err != nil {
		_ = socks5udp.WriteReply(client, 1, socks5udp.Address{})
		return
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stop := func() {
		cancel()
		_ = udpConn.Close()
		_ = client.Close()
	}
	stopOnCancel := context.AfterFunc(ctx, func() { _ = udpConn.Close() })
	defer stopOnCancel()
	defer stop()
	bound := udpConn.LocalAddr().(*net.UDPAddr)
	if err := socks5udp.WriteReply(client, 0, socks5udp.Address{Host: bound.IP.String(), Port: uint16(bound.Port)}); err != nil {
		return
	}
	_ = client.SetDeadline(time.Time{})
	var sourceMu sync.Mutex
	var clientUDPAddr *net.UDPAddr
	if source.Port != 0 {
		clientUDPAddr = &net.UDPAddr{IP: peer.IP, Port: int(source.Port), Zone: peer.Zone}
	}
	var workers sync.WaitGroup
	workers.Go(func() {
		defer stop()
		var b [1]byte
		_, _ = client.Read(b[:])
	})
	workers.Go(func() {
		defer stop()
		for {
			packet, err := session.ReceivePacket(ctx)
			if err != nil {
				return
			}
			sourceMu.Lock()
			addr := clientUDPAddr
			sourceMu.Unlock()
			if addr != nil {
				_, _ = udpConn.WriteToUDP(packet, addr)
			}
		}
	})
	buffer := make([]byte, 65535)
	for {
		n, addr, err := udpConn.ReadFromUDP(buffer)
		if err != nil {
			break
		}
		if !addr.IP.Equal(peer.IP) || (source.Port != 0 && addr.Port != int(source.Port)) {
			continue
		}
		if _, _, err := socks5udp.ParseUDP(buffer[:n]); err != nil || n+socks5udp.SessionDatagramOverhead > p.packetSize {
			continue
		}
		sourceMu.Lock()
		if clientUDPAddr == nil {
			clientUDPAddr = addr
		}
		matches := clientUDPAddr.Port == addr.Port && clientUDPAddr.IP.Equal(addr.IP)
		sourceMu.Unlock()
		if !matches {
			continue
		}
		if err := session.SendPacket(buffer[:n]); err != nil && !errors.Is(err, socks5udp.ErrDatagramTooLarge) {
			break
		}
	}
	stop()
	workers.Wait()
}
