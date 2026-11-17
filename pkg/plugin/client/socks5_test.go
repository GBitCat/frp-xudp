// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0.

//go:build !frps

package client

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	v1 "github.com/fatedier/frp/pkg/config/v1"
)

// Clients reading until EOF must see the end of a response even when they keep
// their request side open.
func TestSocks5TargetEOFReachesClient(t *testing.T) {
	for _, authenticated := range []bool{false, true} {
		t.Run(fmt.Sprintf("authenticated=%v", authenticated), func(t *testing.T) {
			request, response := []byte("request"), []byte("response")
			address, targetDone := socks5Target(t, func(conn net.Conn) error {
				got := make([]byte, len(request))
				if _, err := io.ReadFull(conn, got); err != nil {
					return err
				}
				if !bytes.Equal(got, request) {
					return fmt.Errorf("request changed in transit")
				}
				_, err := conn.Write(response)
				return err // Closing the target must reach the still-open client.
			})
			h := newSocks5Harness(t, authenticated)
			require.True(t, socks5Authenticate(t, h.client, authenticated, "secret"))
			socks5Connect(t, h.client, address)
			_, err := h.client.Write(request)
			require.NoError(t, err)
			got := make([]byte, len(response))
			_, err = io.ReadFull(h.client, got)
			require.NoError(t, err)
			require.Equal(t, response, got)
			socks5Wait(t, targetDone)
			var next [1]byte
			n, err := h.client.Read(next[:])
			require.Zero(t, n)
			require.ErrorIs(t, err, io.EOF, "target EOF must arrive without the client closing its request side")
			h.assertFinishedWithoutBypassingStream(t)
		})
	}
}

func TestSocks5ClientHalfClosePreservesResponse(t *testing.T) {
	request := bytes.Repeat([]byte("request"), 8192)
	response := bytes.Repeat([]byte("response"), 32768)
	address, targetDone := socks5Target(t, func(conn net.Conn) error {
		got, err := io.ReadAll(conn)
		if err != nil {
			return err
		}
		if !bytes.Equal(got, request) {
			return fmt.Errorf("request truncated before client EOF")
		}
		_, err = io.Copy(conn, bytes.NewReader(response))
		return err
	})
	h := newSocks5Harness(t, false)
	require.True(t, socks5Authenticate(t, h.client, false, ""))
	socks5Connect(t, h.client, address)
	_, err := io.Copy(h.client, bytes.NewReader(request))
	require.NoError(t, err)
	require.NoError(t, h.client.CloseWrite())
	got, err := io.ReadAll(h.client)
	require.NoError(t, err)
	require.Equal(t, response, got, "client EOF must not discard the target's remaining response")
	socks5Wait(t, targetDone)
	h.assertFinishedWithoutBypassingStream(t)
}

func TestSocks5RejectsWrongCredentials(t *testing.T) {
	h := newSocks5Harness(t, true)
	require.False(t, socks5Authenticate(t, h.client, true, "wrong-secret"))
	var next [1]byte
	n, err := h.client.Read(next[:])
	require.Zero(t, n)
	require.ErrorIs(t, err, io.EOF)
	h.assertFinishedWithoutBypassingStream(t)
}

type socks5UnderlyingSpy struct {
	net.Conn
	closes      atomic.Int32
	writeCloses atomic.Int32
}

func (c *socks5UnderlyingSpy) Close() error {
	c.closes.Add(1)
	return c.Conn.Close()
}

func (c *socks5UnderlyingSpy) CloseWrite() error {
	c.writeCloses.Add(1)
	return c.Conn.Close()
}

type socks5Harness struct {
	client     *net.TCPConn
	underlying *socks5UnderlyingSpy
	done       chan error
}

func newSocks5Harness(t *testing.T, authenticated bool) *socks5Harness {
	t.Helper()
	listener, err := net.ListenTCP("tcp", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)
	t.Cleanup(func() { _ = listener.Close() })
	client, err := net.DialTCP("tcp", nil, listener.Addr().(*net.TCPAddr))
	require.NoError(t, err)
	t.Cleanup(func() { _ = client.Close() })
	server, err := listener.AcceptTCP()
	require.NoError(t, err)
	t.Cleanup(func() { _ = server.Close() })
	require.NoError(t, listener.Close())
	require.NoError(t, client.SetDeadline(time.Now().Add(3*time.Second)))
	// The underlying connection supplies addresses and deadlines. Closing it
	// directly would bypass the logical stream's encryption/compression wrappers.
	spy := &socks5UnderlyingSpy{Conn: server}
	opts := &v1.Socks5PluginOptions{Type: v1.PluginSocks5}
	if authenticated {
		opts.Username, opts.Password = "user", "secret"
	}
	plugin, err := NewSocks5Plugin(PluginContext{}, opts)
	require.NoError(t, err)
	done := make(chan error, 1)
	go func() {
		plugin.Handle(context.Background(), &ConnectionInfo{Conn: server, UnderlyingConn: spy})
		done <- nil
		close(done)
	}()
	t.Cleanup(func() {
		_ = client.Close()
		_ = server.Close()
		_ = plugin.Close()
		socks5Wait(t, done)
	})
	return &socks5Harness{client: client, underlying: spy, done: done}
}

func (h *socks5Harness) assertFinishedWithoutBypassingStream(t *testing.T) {
	t.Helper()
	socks5Wait(t, h.done)
	require.Zero(t, h.underlying.closes.Load(), "must close only the logical SOCKS stream")
	require.Zero(t, h.underlying.writeCloses.Load(), "must not bypass the logical stream wrappers")
}

func socks5Authenticate(t *testing.T, conn net.Conn, authenticated bool, password string) bool {
	t.Helper()
	method := byte(0)
	if authenticated {
		method = 2
	}
	_, err := conn.Write([]byte{5, 1, method})
	require.NoError(t, err)
	var reply [2]byte
	_, err = io.ReadFull(conn, reply[:])
	require.NoError(t, err)
	require.Equal(t, [2]byte{5, method}, reply)
	if !authenticated {
		return true
	}
	frame := append([]byte{1, 4}, []byte("user")...)
	frame = append(frame, byte(len(password)))
	frame = append(frame, password...)
	_, err = conn.Write(frame)
	require.NoError(t, err)
	_, err = io.ReadFull(conn, reply[:])
	require.NoError(t, err)
	require.Equal(t, byte(1), reply[0])
	return reply[1] == 0
}

func socks5Connect(t *testing.T, conn net.Conn, address *net.TCPAddr) {
	t.Helper()
	frame := append([]byte{5, 1, 0, 1}, address.IP.To4()...)
	frame = binary.BigEndian.AppendUint16(frame, uint16(address.Port))
	_, err := conn.Write(frame)
	require.NoError(t, err)
	var reply [10]byte
	_, err = io.ReadFull(conn, reply[:])
	require.NoError(t, err)
	require.Equal(t, []byte{5, 0, 0, 1}, reply[:4])
}

func socks5Target(t *testing.T, handle func(net.Conn) error) (*net.TCPAddr, <-chan error) {
	t.Helper()
	listener, err := net.ListenTCP("tcp", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)
	done := make(chan error, 1)
	t.Cleanup(func() { _ = listener.Close(); socks5Wait(t, done) })
	go func() {
		defer close(done)
		conn, err := listener.Accept()
		if err != nil {
			done <- err
			return
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
		done <- handle(conn)
	}()
	return listener.Addr().(*net.TCPAddr), done
}

func socks5Wait(t *testing.T, done <-chan error) {
	t.Helper()
	select {
	case err := <-done:
		require.NoError(t, err)
	case <-time.After(4 * time.Second):
		t.Fatal("SOCKS test worker did not exit")
	}
}
