// Copyright 2026 The frp Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package proxy

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/fatedier/frp/pkg/config/types"
	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
	"github.com/fatedier/frp/pkg/util/xlog"
	"github.com/fatedier/frp/server/controller"
	"github.com/fatedier/frp/server/ports"
)

func TestUDPProxyConcurrentCloseStopsProducersAndReclaimsWorkConn(t *testing.T) {
	workConn, peerConn := net.Pipe()
	t.Cleanup(func() { _ = peerConn.Close() })
	require.NoError(t, peerConn.SetReadDeadline(time.Now().Add(time.Second)))

	pxy := &UDPProxy{
		BaseProxy: &BaseProxy{
			rc: &controller.ResourceController{
				UDPPortManager: new(ports.Manager),
			},
			ctx: context.Background(),
		},
		workConn:    workConn,
		readCh:      make(chan *msg.UDPPacket),
		sendCh:      make(chan *msg.UDPPacket),
		reconnectCh: make(chan struct{}, 1),
		doneCh:      make(chan struct{}),
	}

	producerDone := make(chan bool, 1)
	go func() {
		producerDone <- pxy.deliverWorkConnPacket(&msg.UDPPacket{Content: []byte("blocked")})
	}()

	var wg sync.WaitGroup
	for range 32 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			pxy.Close()
		}()
	}
	for range 32 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			conn, peer := net.Pipe()
			defer peer.Close()
			pxy.replaceWorkConn(conn)
		}()
	}
	wg.Wait()

	select {
	case delivered := <-producerDone:
		require.False(t, delivered, "workConn reader must stop when the proxy is done")
	case <-time.After(time.Second):
		t.Fatal("workConn reader remained blocked sending to readCh after Close")
	}

	_, err := peerConn.Read(make([]byte, 1))
	require.Error(t, err, "Close must reclaim the active workConn")
	requireUDPChannelOpen(t, pxy.readCh)
	requireUDPChannelOpen(t, pxy.sendCh)
}

func TestUDPProxyConcurrentCloseJoinsBlockedWorkersAndReleasesPortOnce(t *testing.T) {
	probe, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)
	port := probe.LocalAddr().(*net.UDPAddr).Port
	require.NoError(t, probe.Close())

	portManager := ports.NewManager("udp", "127.0.0.1", []types.PortsRange{{Single: port}})
	cfg := &v1.UDPProxyConfig{
		ProxyBaseConfig: v1.ProxyBaseConfig{
			Name: "udp-close-lifecycle",
			Type: string(v1.ProxyTypeUDP),
		},
		RemotePort: port,
	}
	ctx := context.Background()
	serverSide, peerSide := net.Pipe()
	t.Cleanup(func() { _ = peerSide.Close() })
	signaledServerSide := newSignalingConn(serverSide)
	serverMsgConn := msg.NewConn(signaledServerSide, msg.NewReadWriter(signaledServerSide, ""))
	peerMsgConn := msg.NewConn(peerSide, msg.NewReadWriter(peerSide, ""))

	var workConnTaken atomic.Bool
	baseProxy := &BaseProxy{
		name:       cfg.Name,
		rc:         &controller.ResourceController{UDPPortManager: portManager},
		serverCfg:  &v1.ServerConfig{ProxyBindAddr: "127.0.0.1", UDPPacketSize: 1500},
		configurer: cfg,
		ctx:        ctx,
		xl:         xlog.FromContextSafe(ctx),
		getWorkConnFn: func() (*WorkConn, error) {
			if workConnTaken.CompareAndSwap(false, true) {
				return NewWorkConn(serverMsgConn), nil
			}
			return nil, errors.New("no more work connections")
		},
	}
	pxy := NewUDPProxy(baseProxy).(*UDPProxy)
	_, err = pxy.Run()
	require.NoError(t, err)

	startRead := make(chan error, 1)
	go func() {
		var start msg.StartWorkConn
		startRead <- peerMsgConn.ReadMsgInto(&start)
	}()
	select {
	case err = <-startRead:
		require.NoError(t, err)
	case <-time.After(2 * time.Second):
		t.Fatal("UDP dispatcher did not obtain its first work connection")
	}
	requireUDPTestSignal(t, signaledServerSide.readStarted, "workConn reader did not block in ReadMsg")

	signaledServerSide.armWrite.Store(true)
	userConn, err := net.DialUDP("udp4", nil, pxy.udpConn.LocalAddr().(*net.UDPAddr))
	require.NoError(t, err)
	t.Cleanup(func() { _ = userConn.Close() })
	_, err = userConn.Write([]byte("block the workConn sender"))
	require.NoError(t, err)
	requireUDPTestSignal(t, signaledServerSide.writeStarted, "workConn sender did not block in WriteMsg")

	closeDone := make(chan struct{})
	go func() {
		defer close(closeDone)
		var wg sync.WaitGroup
		for range 32 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				pxy.Close()
			}()
		}
		wg.Wait()
	}()
	requireUDPTestSignal(t, closeDone, "concurrent UDP Close calls did not join all workers")

	reacquired, err := portManager.Acquire("replacement", port)
	require.NoError(t, err, "Close must release the UDP port before returning")
	require.Equal(t, port, reacquired)

	// A later Close must not release a port that has since been acquired by a
	// different proxy. This catches repeated finalization after concurrent Close.
	pxy.Close()
	_, err = portManager.Acquire("must-stay-busy", port)
	require.ErrorIs(t, err, ports.ErrPortAlreadyUsed)
	portManager.Release(port)

	requireUDPChannelOpen(t, pxy.readCh)
	requireUDPChannelOpen(t, pxy.sendCh)
}

func TestUDPProxyCloseReturnsBeforeBlockedGetWorkConnAndClosesLateConn(t *testing.T) {
	probe, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)
	port := probe.LocalAddr().(*net.UDPAddr).Port
	require.NoError(t, probe.Close())

	portManager := ports.NewManager("udp", "127.0.0.1", []types.PortsRange{{Single: port}})
	cfg := &v1.UDPProxyConfig{
		ProxyBaseConfig: v1.ProxyBaseConfig{
			Name: "udp-blocked-get-work-conn",
			Type: string(v1.ProxyTypeUDP),
		},
		RemotePort: port,
	}
	serverSide, peerSide := net.Pipe()
	t.Cleanup(func() { _ = peerSide.Close() })
	trackedServerSide := newUDPTrackedCloseConn(serverSide)
	serverMsgConn := msg.NewConn(trackedServerSide, msg.NewReadWriter(trackedServerSide, ""))
	peerMsgConn := msg.NewConn(peerSide, msg.NewReadWriter(peerSide, ""))
	getStarted := make(chan struct{})
	releaseGet := make(chan struct{})
	getReturned := make(chan struct{})

	ctx := context.Background()
	baseProxy := &BaseProxy{
		name:       cfg.Name,
		rc:         &controller.ResourceController{UDPPortManager: portManager},
		serverCfg:  &v1.ServerConfig{ProxyBindAddr: "127.0.0.1", UDPPacketSize: 1500},
		configurer: cfg,
		ctx:        ctx,
		xl:         xlog.FromContextSafe(ctx),
		getWorkConnFn: func() (*WorkConn, error) {
			close(getStarted)
			<-releaseGet
			close(getReturned)
			return NewWorkConn(serverMsgConn), nil
		},
	}
	pxy := NewUDPProxy(baseProxy).(*UDPProxy)
	_, err = pxy.Run()
	require.NoError(t, err)
	requireUDPTestSignal(t, getStarted, "UDP dispatcher did not enter GetWorkConnFromPool")

	closeDone := make(chan struct{})
	go func() {
		pxy.Close()
		close(closeDone)
	}()
	requireUDPTestSignal(t, closeDone, "UDP Close waited for blocked GetWorkConnFromPool")
	select {
	case <-getReturned:
		t.Fatal("GetWorkConnFromPool returned before the fake was released")
	default:
	}

	reacquired, err := portManager.Acquire("replacement", port)
	require.NoError(t, err, "Close must release the UDP port while GetWorkConnFromPool is blocked")
	require.Equal(t, port, reacquired)
	portManager.Release(reacquired)
	queuedPacket := &msg.UDPPacket{Content: []byte("must remain queued after close")}
	pxy.sendCh <- queuedPacket

	startRead := make(chan error, 1)
	go func() {
		var start msg.StartWorkConn
		startRead <- peerMsgConn.ReadMsgInto(&start)
	}()
	close(releaseGet)
	requireUDPTestSignal(t, getReturned, "blocked getWorkConnFn did not return after release")
	select {
	case err = <-startRead:
		require.NoError(t, err)
	case <-time.After(2 * time.Second):
		t.Fatal("GetWorkConnFromPool did not finish StartWorkConn delivery")
	}
	requireUDPTestSignal(t, trackedServerSide.closed, "late UDP work connection was not closed")
	require.Zero(t, trackedServerSide.reads.Load(), "late work connection must not start a reader")
	pxy.mu.RLock()
	installedWorkConn := pxy.workConn
	pxy.mu.RUnlock()
	require.Nil(t, installedWorkConn, "late work connection must not be installed")
	select {
	case packet := <-pxy.sendCh:
		require.Same(t, queuedPacket, packet, "late work connection must not start a sender")
	default:
		t.Fatal("late work connection sender consumed a packet after Close")
	}
}

func TestUDPProxyReconnectJoinsOldSenderAndHandsOffFailedPacket(t *testing.T) {
	probe, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)
	port := probe.LocalAddr().(*net.UDPAddr).Port
	require.NoError(t, probe.Close())

	portManager := ports.NewManager("udp", "127.0.0.1", []types.PortsRange{{Single: port}})
	cfg := &v1.UDPProxyConfig{
		ProxyBaseConfig: v1.ProxyBaseConfig{
			Name: "udp-reconnect-handoff",
			Type: string(v1.ProxyTypeUDP),
		},
		RemotePort: port,
	}
	firstServer, firstPeer := net.Pipe()
	firstConn := &udpGatedWriteFailureConn{
		Conn:         firstServer,
		writeStarted: make(chan struct{}),
		releaseWrite: make(chan struct{}),
	}
	secondServer, secondPeer := net.Pipe()
	t.Cleanup(func() {
		_ = firstPeer.Close()
		_ = secondPeer.Close()
	})

	firstWorkConn := NewWorkConn(msg.NewConn(firstConn, msg.NewReadWriter(firstConn, "")))
	secondWorkConn := NewWorkConn(msg.NewConn(secondServer, msg.NewReadWriter(secondServer, "")))
	secondRequested := make(chan struct{})
	var requestCount atomic.Int32
	ctx := context.Background()
	baseProxy := &BaseProxy{
		name:       cfg.Name,
		rc:         &controller.ResourceController{UDPPortManager: portManager},
		serverCfg:  &v1.ServerConfig{ProxyBindAddr: "127.0.0.1", UDPPacketSize: 1500},
		configurer: cfg,
		ctx:        ctx,
		xl:         xlog.FromContextSafe(ctx),
		getWorkConnFn: func() (*WorkConn, error) {
			switch requestCount.Add(1) {
			case 1:
				return firstWorkConn, nil
			case 2:
				close(secondRequested)
				return secondWorkConn, nil
			default:
				return nil, errors.New("no more work connections")
			}
		},
	}
	pxy := NewUDPProxy(baseProxy).(*UDPProxy)
	_, err = pxy.Run()
	require.NoError(t, err)
	t.Cleanup(pxy.Close)

	firstStartRead := make(chan error, 1)
	go func() {
		var start msg.StartWorkConn
		firstStartRead <- msg.NewConn(firstPeer, msg.NewReadWriter(firstPeer, "")).ReadMsgInto(&start)
	}()
	select {
	case err = <-firstStartRead:
		require.NoError(t, err)
	case <-time.After(2 * time.Second):
		t.Fatal("first UDP work connection did not start")
	}

	firstConn.armWrite.Store(true)
	packet := &msg.UDPPacket{Content: []byte("preserve-across-reconnect")}
	pxy.sendCh <- packet
	requireUDPTestSignal(t, firstConn.writeStarted, "first UDP sender did not start its packet write")
	require.NoError(t, firstPeer.Close())

	// The dispatcher must not request the replacement while the old sender is
	// still blocked. Starting it early would create two consumers of sendCh.
	select {
	case <-secondRequested:
		t.Fatal("replacement work connection started before old sender joined")
	case <-time.After(50 * time.Millisecond):
	}

	secondStartRead := make(chan error, 1)
	go func() {
		var start msg.StartWorkConn
		secondStartRead <- msg.NewConn(secondPeer, msg.NewReadWriter(secondPeer, "")).ReadMsgInto(&start)
	}()
	close(firstConn.releaseWrite)
	requireUDPTestSignal(t, secondRequested, "replacement UDP work connection was not requested")
	select {
	case err = <-secondStartRead:
		require.NoError(t, err)
	case <-time.After(2 * time.Second):
		t.Fatal("replacement UDP work connection did not start")
	}

	secondRW, err := msg.NewUDPPacketReadWriter(secondPeer, "", "")
	require.NoError(t, err)
	packetRead := make(chan *msg.UDPPacket, 1)
	packetReadErr := make(chan error, 1)
	go func() {
		raw, readErr := secondRW.ReadMsg()
		if readErr != nil {
			packetReadErr <- readErr
			return
		}
		got, ok := raw.(*msg.UDPPacket)
		if !ok {
			packetReadErr <- fmt.Errorf("replacement message type %T, want *msg.UDPPacket", raw)
			return
		}
		packetRead <- got
	}()
	select {
	case err = <-packetReadErr:
		t.Fatalf("read handed-off UDP packet: %v", err)
	case got := <-packetRead:
		require.Equal(t, packet.Content, got.Content)
	case <-time.After(2 * time.Second):
		t.Fatal("failed packet was not handed off to replacement work connection")
	}
}

func TestUDPWorkConnRequestClosesLateConnAndExits(t *testing.T) {
	lateConn, peerConn := net.Pipe()
	t.Cleanup(func() { _ = peerConn.Close() })
	trackedConn := newUDPTrackedCloseConn(lateConn)
	requestStarted := make(chan struct{})
	releaseRequest := make(chan struct{})
	doneCh := make(chan struct{})

	request := newUDPWorkConnRequest(func() (net.Conn, error) {
		close(requestStarted)
		<-releaseRequest
		return trackedConn, nil
	})
	waitDone := make(chan struct{})
	go func() {
		defer close(waitDone)
		result, ok := request.wait(doneCh)
		if ok {
			result.close()
		}
	}()
	requireUDPTestSignal(t, requestStarted, "UDP async request did not start")
	close(doneCh)
	requireUDPTestSignal(t, waitDone, "UDP async request wait did not stop on shutdown")
	select {
	case <-request.doneCh:
		t.Fatal("UDP async request exited before the blocked call was released")
	default:
	}

	close(releaseRequest)
	requireUDPTestSignal(t, trackedConn.closed, "late UDP work connection was not closed")
	requireUDPTestSignal(t, request.doneCh, "UDP async request goroutine did not exit")
}

func requireUDPChannelOpen[T any](t *testing.T, ch <-chan T) {
	t.Helper()
	select {
	case _, ok := <-ch:
		require.True(t, ok, "channel was closed")
	default:
	}
}

func requireUDPTestSignal(t *testing.T, ch <-chan struct{}, failure string) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatal(failure)
	}
}

type signalingConn struct {
	net.Conn
	readStarted  chan struct{}
	writeStarted chan struct{}
	readOnce     sync.Once
	writeOnce    sync.Once
	armWrite     atomic.Bool
}

func newSignalingConn(conn net.Conn) *signalingConn {
	return &signalingConn{
		Conn:         conn,
		readStarted:  make(chan struct{}),
		writeStarted: make(chan struct{}),
	}
}

func (c *signalingConn) Read(buf []byte) (int, error) {
	c.readOnce.Do(func() { close(c.readStarted) })
	return c.Conn.Read(buf)
}

func (c *signalingConn) Write(buf []byte) (int, error) {
	if c.armWrite.Load() {
		c.writeOnce.Do(func() { close(c.writeStarted) })
	}
	return c.Conn.Write(buf)
}

type udpTrackedCloseConn struct {
	net.Conn
	closed    chan struct{}
	closeOnce sync.Once
	reads     atomic.Int32
}

type udpGatedWriteFailureConn struct {
	net.Conn
	armWrite     atomic.Bool
	writeStarted chan struct{}
	releaseWrite chan struct{}
	writeOnce    sync.Once
}

func (c *udpGatedWriteFailureConn) Write(buf []byte) (int, error) {
	if !c.armWrite.Load() {
		return c.Conn.Write(buf)
	}
	c.writeOnce.Do(func() { close(c.writeStarted) })
	<-c.releaseWrite
	return 0, errors.New("forced packet write failure")
}

func newUDPTrackedCloseConn(conn net.Conn) *udpTrackedCloseConn {
	return &udpTrackedCloseConn{
		Conn:   conn,
		closed: make(chan struct{}),
	}
}

func (c *udpTrackedCloseConn) Read(buf []byte) (int, error) {
	c.reads.Add(1)
	return c.Conn.Read(buf)
}

func (c *udpTrackedCloseConn) Close() error {
	err := c.Conn.Close()
	c.closeOnce.Do(func() { close(c.closed) })
	return err
}
