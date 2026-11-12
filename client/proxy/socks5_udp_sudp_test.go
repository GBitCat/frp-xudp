// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

//go:build !frps

package proxy

import (
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
	plugin "github.com/fatedier/frp/pkg/plugin/client"
	"github.com/fatedier/frp/pkg/util/xlog"
)

// A minimal datagram plugin leaves the transport's reader blocked and pushes
// one reply into its writer. Close must release both network operations and
// the plugin worker before closing plugin-owned association state.
type sudpSOCKS5ClosePlugin struct {
	started   chan struct{}
	startOnce sync.Once
	active    atomic.Int32
	closed    atomic.Int32
	closeGate <-chan struct{}
	closing   chan struct{}
}

func (*sudpSOCKS5ClosePlugin) Name() string                                   { return "sudp-socks5-close-test" }
func (*sudpSOCKS5ClosePlugin) Handle(context.Context, *plugin.ConnectionInfo) {}
func (p *sudpSOCKS5ClosePlugin) Close() error {
	p.closed.Add(1)
	if p.closing != nil {
		close(p.closing)
	}
	if p.closeGate != nil {
		<-p.closeGate
	}
	return nil
}

func (p *sudpSOCKS5ClosePlugin) ServePackets(ctx context.Context, _ <-chan *msg.UDPPacket, sendCh chan<- msg.Message) {
	p.active.Add(1)
	defer p.active.Add(-1)
	p.startOnce.Do(func() { close(p.started) })
	select {
	case sendCh <- &msg.UDPPacket{
		Content: []byte("reply"), RemoteAddr: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 40001},
	}:
	case <-ctx.Done():
		return
	}
	<-ctx.Done()
}

type sudpSOCKS5ObservedConn struct {
	net.Conn
	reading   chan struct{}
	writing   chan struct{}
	readOnce  sync.Once
	writeOnce sync.Once
}

func (c *sudpSOCKS5ObservedConn) Read(b []byte) (int, error) {
	c.readOnce.Do(func() { close(c.reading) })
	return c.Conn.Read(b)
}

func (c *sudpSOCKS5ObservedConn) Write(b []byte) (int, error) {
	c.writeOnce.Do(func() { close(c.writing) })
	return c.Conn.Write(b)
}

func newSUDPSOCKS5CloseTestProxy() (*SUDPProxy, *sudpSOCKS5ClosePlugin) {
	p := &sudpSOCKS5ClosePlugin{started: make(chan struct{})}
	cfg := &v1.SUDPProxyConfig{}
	base := &BaseProxy{
		ctx: context.Background(), xl: xlog.New(), baseCfg: &cfg.ProxyBaseConfig,
		clientCfg: &v1.ClientCommonConfig{UDPPacketSize: 1500}, proxyPlugin: p,
	}
	return NewSUDPProxy(base, cfg).(*SUDPProxy), p
}

func waitSUDPSOCKS5Done(t *testing.T, done <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatalf("timed out waiting for %s", what)
	}
}

func expectSUDPSOCKS5PeerClosed(t *testing.T, peer net.Conn) {
	t.Helper()
	if err := peer.SetReadDeadline(time.Now().Add(time.Second)); errors.Is(err, net.ErrClosed) || errors.Is(err, io.ErrClosedPipe) {
		return
	} else if err != nil {
		t.Fatal(err)
	}
	_, err := peer.Read(make([]byte, 1))
	if err == nil {
		t.Fatal("shutdown left a work connection usable")
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		t.Fatal("shutdown left a work connection open until the test deadline")
	}
}

func TestSOCKS5UDPSUDPCloseUnblocksAllWorkers(t *testing.T) {
	pxy, p := newSUDPSOCKS5CloseTestProxy()
	t.Cleanup(pxy.Close)
	conn, peer := net.Pipe()
	t.Cleanup(func() { _ = peer.Close() })
	observed := &sudpSOCKS5ObservedConn{Conn: conn, reading: make(chan struct{}), writing: make(chan struct{})}
	workerDone := make(chan struct{})
	go func() {
		pxy.InWorkConn(observed, nil)
		close(workerDone)
	}()
	waitSUDPSOCKS5Done(t, p.started, "plugin ServePackets")
	waitSUDPSOCKS5Done(t, observed.reading, "blocked work connection read")
	waitSUDPSOCKS5Done(t, observed.writing, "blocked work connection write")
	closeDone := make(chan struct{})
	go func() {
		pxy.Close()
		close(closeDone)
	}()
	waitSUDPSOCKS5Done(t, closeDone, "SUDP Close")
	waitSUDPSOCKS5Done(t, workerDone, "SUDP InWorkConn completion")
	if active := p.active.Load(); active != 0 {
		t.Fatalf("Close returned with %d active plugin workers", active)
	}
	pxy.Close()
	if got := p.closed.Load(); got != 1 {
		t.Fatalf("plugin Close calls = %d, want 1", got)
	}
	expectSUDPSOCKS5PeerClosed(t, peer)

	lateConn, latePeer := net.Pipe()
	defer latePeer.Close()
	lateDone := make(chan struct{})
	go func() {
		pxy.InWorkConn(lateConn, nil)
		close(lateDone)
	}()
	waitSUDPSOCKS5Done(t, lateDone, "late connection rejection")
	expectSUDPSOCKS5PeerClosed(t, latePeer)
}

func TestSOCKS5UDPSUDPCloseConcurrentWithIncomingConnections(t *testing.T) {
	pxy, p := newSUDPSOCKS5CloseTestProxy()
	t.Cleanup(pxy.Close)
	firstConn, firstPeer := net.Pipe()
	t.Cleanup(func() { _ = firstPeer.Close() })
	var workers sync.WaitGroup
	workers.Go(func() { pxy.InWorkConn(firstConn, nil) })
	waitSUDPSOCKS5Done(t, p.started, "initial active plugin worker")

	start := make(chan struct{})
	peers := make([]net.Conn, 24)
	for i := range peers {
		conn, peer := net.Pipe()
		peers[i] = peer
		t.Cleanup(func() { _ = peer.Close() })
		workers.Go(func() {
			<-start
			pxy.InWorkConn(conn, nil)
		})
	}
	for range 12 {
		workers.Go(func() {
			<-start
			pxy.Close()
		})
	}
	done := make(chan struct{})
	go func() {
		workers.Wait()
		close(done)
	}()
	close(start)
	waitSUDPSOCKS5Done(t, done, "concurrent Close and InWorkConn")
	if active := p.active.Load(); active != 0 {
		t.Fatalf("concurrent Close leaked %d plugin workers", active)
	}
	if calls := p.closed.Load(); calls != 1 {
		t.Fatalf("concurrent plugin Close calls = %d, want 1", calls)
	}
	for _, peer := range peers {
		expectSUDPSOCKS5PeerClosed(t, peer)
	}
}

func TestSOCKS5UDPSUDPConcurrentCloseWaitsForPluginCleanup(t *testing.T) {
	pxy, p := newSUDPSOCKS5CloseTestProxy()
	release := make(chan struct{})
	p.closeGate = release
	p.closing = make(chan struct{})
	unblock := sync.OnceFunc(func() { close(release) })
	t.Cleanup(func() {
		unblock()
		pxy.Close()
	})
	firstDone := make(chan struct{})
	go func() {
		pxy.Close()
		close(firstDone)
	}()
	waitSUDPSOCKS5Done(t, p.closing, "plugin cleanup gate")
	secondStarted := make(chan struct{})
	secondDone := make(chan struct{})
	go func() {
		close(secondStarted)
		pxy.Close()
		close(secondDone)
	}()
	waitSUDPSOCKS5Done(t, secondStarted, "second Close call")
	select {
	case <-secondDone:
		t.Fatal("second Close returned before the plugin finished cleanup")
	case <-time.After(100 * time.Millisecond):
	}
	unblock()
	waitSUDPSOCKS5Done(t, firstDone, "first Close completion")
	waitSUDPSOCKS5Done(t, secondDone, "second Close completion")
	if calls := p.closed.Load(); calls != 1 {
		t.Fatalf("concurrent plugin cleanup calls = %d, want 1", calls)
	}
}
