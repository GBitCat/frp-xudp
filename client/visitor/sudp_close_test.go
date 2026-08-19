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

package visitor

import (
	"context"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
)

func TestSUDPVisitorConcurrentCloseUnblocksWorkerProducer(t *testing.T) {
	workerConn, peerConn := net.Pipe()
	t.Cleanup(func() { _ = peerConn.Close() })

	sv := &SUDPVisitor{
		BaseVisitor: &BaseVisitor{
			clientCfg: &v1.ClientCommonConfig{},
			ctx:       context.Background(),
		},
		cfg:          &v1.SUDPVisitorConfig{},
		checkCloseCh: make(chan struct{}),
		readCh:       make(chan *msg.UDPPacket),
		sendCh:       make(chan *msg.UDPPacket),
	}

	workerDone := make(chan struct{})
	go func() {
		sv.worker(workerConn, nil)
		close(workerDone)
	}()

	peerRW, err := msg.NewUDPPacketReadWriter(peerConn, "", "")
	require.NoError(t, err)
	peer := msg.NewConn(peerConn, peerRW)
	require.NoError(t, peer.WriteMsg(&msg.UDPPacket{
		Content:    []byte("blocked producer"),
		RemoteAddr: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 7000},
	}))

	var wg sync.WaitGroup
	for range 32 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			sv.Close()
		}()
	}
	wg.Wait()

	select {
	case <-workerDone:
	case <-time.After(time.Second):
		t.Fatal("SUDP worker remained blocked sending to readCh after Close")
	}

	requireChannelOpen(t, sv.readCh)
	requireChannelOpen(t, sv.sendCh)
}

func TestSUDPVisitorConcurrentCloseUnblocksFirstPacketAndJoinsWorker(t *testing.T) {
	workConn := newSUDPBlockingConn()
	sv := &SUDPVisitor{
		BaseVisitor: &BaseVisitor{
			clientCfg: &v1.ClientCommonConfig{},
			ctx:       context.Background(),
		},
		cfg:          &v1.SUDPVisitorConfig{},
		checkCloseCh: make(chan struct{}),
		readCh:       make(chan *msg.UDPPacket),
		sendCh:       make(chan *msg.UDPPacket),
	}

	sv.workers.Add(1)
	workerDone := make(chan struct{})
	go func() {
		defer sv.workers.Done()
		defer close(workerDone)
		sv.worker(workConn, &msg.UDPPacket{
			Content:    []byte("peer never reads this first packet"),
			RemoteAddr: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 7000},
		})
	}()

	requireSignal(t, workConn.readStarted, "SUDP worker did not block in ReadMsg")
	requireSignal(t, workConn.writeStarted, "SUDP worker did not block writing the first packet")

	closeDone := make(chan struct{})
	go func() {
		defer close(closeDone)
		var wg sync.WaitGroup
		for range 32 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				sv.Close()
			}()
		}
		wg.Wait()
	}()

	requireSignal(t, closeDone, "concurrent SUDP Close calls did not return")
	requireSignal(t, workerDone, "SUDP Close returned before the blocked worker exited")
	requireChannelOpen(t, sv.readCh)
	requireChannelOpen(t, sv.sendCh)
}

func TestSUDPVisitorCloseJoinsDispatcherAndForwarder(t *testing.T) {
	sv := &SUDPVisitor{
		BaseVisitor: &BaseVisitor{
			clientCfg: &v1.ClientCommonConfig{UDPPacketSize: 1500},
			ctx:       context.Background(),
		},
		cfg: &v1.SUDPVisitorConfig{
			VisitorBaseConfig: v1.VisitorBaseConfig{
				BindAddr: "127.0.0.1",
				BindPort: 0,
			},
		},
		checkCloseCh: make(chan struct{}),
	}
	require.NoError(t, sv.Run())

	closeDone := make(chan struct{})
	go func() {
		sv.Close()
		close(closeDone)
	}()
	requireSignal(t, closeDone, "SUDP Close did not join dispatcher and ForwardUserConn")

	_, err := sv.udpConn.WriteToUDP([]byte("closed"), sv.udpConn.LocalAddr().(*net.UDPAddr))
	require.Error(t, err, "SUDP Close must close the owned UDP socket")
	requireChannelOpen(t, sv.readCh)
	requireChannelOpen(t, sv.sendCh)
}

func TestSUDPVisitorRunIsSingleUseAndCloseBeforeRunWins(t *testing.T) {
	sv := newSUDPRunTestVisitor()
	require.NoError(t, sv.Run())
	firstConn := sv.udpConn

	require.Error(t, sv.Run(), "a second Run must not replace the published socket")
	require.Same(t, firstConn, sv.udpConn)

	sv.Close()
	require.Error(t, sv.Run(), "Run after Close must be rejected")

	closedBeforeRun := newSUDPRunTestVisitor()
	closedBeforeRun.Close()
	require.Error(t, closedBeforeRun.Run(), "Close-before-Run must be rejected")
}

func TestSUDPVisitorCloseDuringListenClosesTemporarySocket(t *testing.T) {
	sv := newSUDPRunTestVisitor()
	listenStarted := make(chan struct{})
	releaseListen := make(chan struct{})
	temporaryConnCh := make(chan *net.UDPConn, 1)
	sv.listenUDPFn = func(network string, addr *net.UDPAddr) (*net.UDPConn, error) {
		conn, err := net.ListenUDP(network, addr)
		if err == nil {
			temporaryConnCh <- conn
		}
		close(listenStarted)
		<-releaseListen
		return conn, err
	}

	runDone := make(chan error, 1)
	go func() { runDone <- sv.Run() }()
	requireSignal(t, listenStarted, "SUDP Run did not enter the listen phase")

	closeDone := make(chan struct{})
	go func() {
		sv.Close()
		close(closeDone)
	}()
	requireSignal(t, closeDone, "SUDP Close blocked while ListenUDP was in progress")

	close(releaseListen)
	require.Error(t, <-runDone, "Run must fail after Close wins during startup")
	temporaryConn := <-temporaryConnCh
	_, err := temporaryConn.WriteToUDP([]byte("closed"), temporaryConn.LocalAddr().(*net.UDPAddr))
	require.Error(t, err, "temporary socket must be closed when startup loses the commit race")
}

func TestSUDPVisitorCloseCommitRaceDoesNotPublishWorkers(t *testing.T) {
	sv := newSUDPRunTestVisitor()
	commitStarted := make(chan struct{})
	releaseCommit := make(chan struct{})
	temporaryConnCh := make(chan *net.UDPConn, 1)
	sv.listenUDPFn = func(network string, addr *net.UDPAddr) (*net.UDPConn, error) {
		conn, err := net.ListenUDP(network, addr)
		if err == nil {
			temporaryConnCh <- conn
		}
		return conn, err
	}
	sv.beforeCommitFn = func() {
		close(commitStarted)
		<-releaseCommit
	}

	runDone := make(chan error, 1)
	go func() { runDone <- sv.Run() }()
	requireSignal(t, commitStarted, "SUDP Run did not reach the commit boundary")

	closeDone := make(chan struct{})
	go func() {
		sv.Close()
		close(closeDone)
	}()
	requireSignal(t, closeDone, "SUDP Close blocked at the Run commit boundary")

	close(releaseCommit)
	require.Error(t, <-runDone, "Run must fail when Close wins the commit race")
	require.Nil(t, sv.udpConn, "a losing startup must not publish udpConn")
	require.Nil(t, sv.readCh, "a losing startup must not publish readCh")
	require.Nil(t, sv.sendCh, "a losing startup must not publish sendCh")
	temporaryConn := <-temporaryConnCh
	_, err := temporaryConn.WriteToUDP([]byte("closed"), temporaryConn.LocalAddr().(*net.UDPAddr))
	require.Error(t, err, "temporary socket must be closed after a failed commit")
}

func TestSUDPVisitorConcurrentRunAndCloseHasOneOwner(t *testing.T) {
	for range 20 {
		sv := newSUDPRunTestVisitor()
		commitReady := make(chan struct{})
		releaseCommit := make(chan struct{})
		sv.beforeCommitFn = func() {
			close(commitReady)
			<-releaseCommit
		}

		runDone := make(chan error, 1)
		go func() { runDone <- sv.Run() }()
		requireSignal(t, commitReady, "SUDP Run did not reach commit")

		var closeWG sync.WaitGroup
		for range 8 {
			closeWG.Add(1)
			go func() {
				defer closeWG.Done()
				sv.Close()
			}()
		}
		closeWG.Wait()
		close(releaseCommit)
		require.Error(t, <-runDone)
		sv.Close()
	}
}

func TestSUDPVisitorConnRequestCloseReturnsBeforeBlockedConnectServer(t *testing.T) {
	lateConn, peerConn := net.Pipe()
	t.Cleanup(func() { _ = peerConn.Close() })
	trackedConn := newSUDPTrackedCloseConn(lateConn)
	fake := &blockingConnectServerFake{
		conn:     msg.NewConn(trackedConn, msg.NewReadWriter(trackedConn, "")),
		started:  make(chan struct{}),
		release:  make(chan struct{}),
		returned: make(chan struct{}),
	}
	recycled := make(chan struct{})
	var recycleOnce sync.Once

	sv := &SUDPVisitor{
		BaseVisitor:  &BaseVisitor{ctx: context.Background()},
		checkCloseCh: make(chan struct{}),
	}
	request := newSUDPVisitorConnRequest(func() (net.Conn, func(), error) {
		conn, err := fake.ConnectServer()
		return conn, func() {
			recycleOnce.Do(func() { close(recycled) })
		}, err
	})

	sv.workers.Add(1)
	dispatcherDone := make(chan struct{})
	go func() {
		defer sv.workers.Done()
		defer close(dispatcherDone)
		result, ok := request.wait(sv.checkCloseCh)
		if ok {
			result.recycle()
		}
	}()
	requireSignal(t, fake.started, "SUDP request did not enter ConnectServer")

	closeDone := make(chan struct{})
	go func() {
		sv.Close()
		close(closeDone)
	}()
	requireSignal(t, closeDone, "SUDP Close waited for blocked ConnectServer")
	requireSignal(t, dispatcherDone, "SUDP dispatcher wait did not stop on Close")
	select {
	case <-request.doneCh:
		t.Fatal("SUDP async request exited before blocked ConnectServer was released")
	default:
	}

	close(fake.release)
	requireSignal(t, fake.returned, "SUDP ConnectServer did not return after release")
	requireSignal(t, trackedConn.closed, "late SUDP visitor connection was not closed")
	requireSignal(t, recycled, "late SUDP visitor connection was not recycled")
	requireSignal(t, request.doneCh, "SUDP async request goroutine did not exit")
}

func requireChannelOpen[T any](t *testing.T, ch <-chan T) {
	t.Helper()
	select {
	case _, ok := <-ch:
		require.True(t, ok, "channel was closed")
	default:
	}
}

func requireSignal(t *testing.T, ch <-chan struct{}, failure string) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatal(failure)
	}
}

func newSUDPRunTestVisitor() *SUDPVisitor {
	return &SUDPVisitor{
		BaseVisitor: &BaseVisitor{
			clientCfg: &v1.ClientCommonConfig{UDPPacketSize: 1500},
			ctx:       context.Background(),
		},
		cfg: &v1.SUDPVisitorConfig{
			VisitorBaseConfig: v1.VisitorBaseConfig{
				BindAddr: "127.0.0.1",
				BindPort: 0,
			},
		},
	}
}

type sudpBlockingConn struct {
	readStarted  chan struct{}
	writeStarted chan struct{}
	closed       chan struct{}
	readOnce     sync.Once
	writeOnce    sync.Once
	closeOnce    sync.Once
}

func newSUDPBlockingConn() *sudpBlockingConn {
	return &sudpBlockingConn{
		readStarted:  make(chan struct{}),
		writeStarted: make(chan struct{}),
		closed:       make(chan struct{}),
	}
}

func (c *sudpBlockingConn) Read([]byte) (int, error) {
	c.readOnce.Do(func() { close(c.readStarted) })
	<-c.closed
	return 0, io.ErrClosedPipe
}

func (c *sudpBlockingConn) Write([]byte) (int, error) {
	c.writeOnce.Do(func() { close(c.writeStarted) })
	<-c.closed
	return 0, io.ErrClosedPipe
}

func (c *sudpBlockingConn) Close() error {
	c.closeOnce.Do(func() { close(c.closed) })
	return nil
}

func (c *sudpBlockingConn) LocalAddr() net.Addr              { return blockingAddr("local") }
func (c *sudpBlockingConn) RemoteAddr() net.Addr             { return blockingAddr("remote") }
func (c *sudpBlockingConn) SetDeadline(time.Time) error      { return nil }
func (c *sudpBlockingConn) SetReadDeadline(time.Time) error  { return nil }
func (c *sudpBlockingConn) SetWriteDeadline(time.Time) error { return nil }

type blockingAddr string

func (a blockingAddr) Network() string { return "pipe" }
func (a blockingAddr) String() string  { return string(a) }

type blockingConnectServerFake struct {
	conn     *msg.Conn
	started  chan struct{}
	release  chan struct{}
	returned chan struct{}
}

func (f *blockingConnectServerFake) ConnectServer() (*msg.Conn, error) {
	close(f.started)
	<-f.release
	close(f.returned)
	return f.conn, nil
}

type sudpTrackedCloseConn struct {
	net.Conn
	closed    chan struct{}
	closeOnce sync.Once
}

func newSUDPTrackedCloseConn(conn net.Conn) *sudpTrackedCloseConn {
	return &sudpTrackedCloseConn{
		Conn:   conn,
		closed: make(chan struct{}),
	}
}

func (c *sudpTrackedCloseConn) Close() error {
	err := c.Conn.Close()
	c.closeOnce.Do(func() { close(c.closed) })
	return err
}
