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
	"errors"
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
)

func TestSUDPDispatcherRetainsFirstPacketAndPreservesFIFO(t *testing.T) {
	sv := newSUDPDispatcherTestVisitor()
	sv.retryInterval = 5 * time.Millisecond
	const failures = 3

	var attempts atomic.Int32
	attemptCh := make(chan int, failures+1)
	peerCh := make(chan net.Conn, 1)
	sv.newVisitorConnFn = func() (net.Conn, func(), error) {
		attempt := int(attempts.Add(1))
		attemptCh <- attempt
		if attempt <= failures {
			return nil, func() {}, errors.New("connection unavailable")
		}
		workConn, peerConn := net.Pipe()
		peerCh <- peerConn
		return workConn, func() {}, nil
	}

	first := sudpTestPacket("first")
	sv.sendCh <- first
	dispatcherDone := make(chan struct{})
	go func() {
		defer close(dispatcherDone)
		sv.dispatcher()
	}()

	for want := 1; want <= failures; want++ {
		select {
		case got := <-attemptCh:
			require.Equal(t, want, got)
		case <-time.After(time.Second):
			t.Fatalf("connection attempt %d did not happen", want)
		}
	}

	// These packets arrive while first is pending. The dispatcher must leave
	// them in sendCh so the worker observes them after first, in FIFO order.
	second := sudpTestPacket("second")
	third := sudpTestPacket("third")
	sv.sendCh <- second
	sv.sendCh <- third

	select {
	case got := <-attemptCh:
		require.Equal(t, failures+1, got)
	case <-time.After(time.Second):
		t.Fatal("successful connection attempt did not happen")
	}

	peerConn := <-peerCh
	peer := msg.NewConn(peerConn, mustSUDPReadWriter(t, peerConn))
	got := make([]string, 0, 3)
	for range 3 {
		raw, err := peer.ReadMsg()
		require.NoError(t, err)
		packet, ok := raw.(*msg.UDPPacket)
		require.True(t, ok)
		got = append(got, string(packet.Content))
	}
	require.Equal(t, []string{"first", "second", "third"}, got)

	_ = peerConn.Close()
	sv.Close()
	select {
	case <-dispatcherDone:
	case <-time.After(time.Second):
		t.Fatal("SUDP dispatcher did not stop after Close")
	}
	require.Equal(t, int32(failures+1), attempts.Load())
}

func TestSUDPDispatcherDoesNotResendAmbiguousFirstWrite(t *testing.T) {
	sv := newSUDPDispatcherTestVisitor()
	workConn := newSUDPWriteFailConn()
	var attempts atomic.Int32
	attempted := make(chan struct{})
	sv.newVisitorConnFn = func() (net.Conn, func(), error) {
		attempts.Add(1)
		close(attempted)
		return workConn, func() {}, nil
	}
	sv.sendCh <- sudpTestPacket("ambiguous")

	dispatcherDone := make(chan struct{})
	go func() {
		defer close(dispatcherDone)
		sv.dispatcher()
	}()
	requireSignal(t, attempted, "SUDP dispatcher did not create the worker connection")

	// The first WriteMsg fails. It is a delivery-uncertain event, so the
	// packet must not be put back into sendCh or trigger another connection.
	deadline := time.Now().Add(time.Second)
	for workConn.writeCount.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	require.Equal(t, int32(1), workConn.writeCount.Load())
	time.Sleep(20 * time.Millisecond)
	require.Equal(t, int32(1), attempts.Load())

	sv.Close()
	requireSignal(t, dispatcherDone, "SUDP dispatcher did not stop after ambiguous write")
}

func TestSUDPDispatcherRetryBackoffIsBoundedAndCloseCancelable(t *testing.T) {
	sv := newSUDPDispatcherTestVisitor()
	sv.retryInterval = 30 * time.Millisecond
	var attempts atomic.Int32
	firstAttempt := make(chan struct{})
	sv.newVisitorConnFn = func() (net.Conn, func(), error) {
		if attempts.Add(1) == 1 {
			close(firstAttempt)
		}
		return nil, func() {}, errors.New("still unavailable")
	}
	sv.sendCh <- sudpTestPacket("pending")

	dispatcherDone := make(chan struct{})
	go func() {
		defer close(dispatcherDone)
		sv.dispatcher()
	}()
	requireSignal(t, firstAttempt, "SUDP dispatcher did not start the first connection attempt")

	// The retry timer is a gate, not a tight loop. There may be the initial
	// attempt plus at most three 30ms retries in this interval.
	time.Sleep(100 * time.Millisecond)
	countBeforeClose := attempts.Load()
	require.GreaterOrEqual(t, countBeforeClose, int32(2))
	require.LessOrEqual(t, countBeforeClose, int32(4))

	closeStarted := time.Now()
	sv.Close()
	require.Less(t, time.Since(closeStarted), 200*time.Millisecond)
	requireSignal(t, dispatcherDone, "SUDP dispatcher remained in retry backoff after Close")
}

func TestSUDPDispatcherCloseCancelsBlockedConnectionRequest(t *testing.T) {
	sv := newSUDPDispatcherTestVisitor()
	sv.sendCh <- sudpTestPacket("pending")
	entered := make(chan struct{})
	release := make(chan struct{})
	var attempts atomic.Int32
	sv.newVisitorConnFn = func() (net.Conn, func(), error) {
		attempts.Add(1)
		close(entered)
		<-release
		return nil, func() {}, errors.New("late connection failure")
	}

	dispatcherDone := make(chan struct{})
	go func() {
		defer close(dispatcherDone)
		sv.dispatcher()
	}()
	requireSignal(t, entered, "SUDP dispatcher did not enter the connection request")

	closeDone := make(chan struct{})
	go func() {
		sv.Close()
		close(closeDone)
	}()
	requireSignal(t, closeDone, "SUDP Close waited for a blocked connection request")
	requireSignal(t, dispatcherDone, "SUDP dispatcher did not stop after blocked request cancellation")

	close(release)
	require.Equal(t, int32(1), attempts.Load())
}

func newSUDPDispatcherTestVisitor() *SUDPVisitor {
	return &SUDPVisitor{
		BaseVisitor: &BaseVisitor{
			clientCfg: &v1.ClientCommonConfig{},
			ctx:       context.Background(),
		},
		cfg:          &v1.SUDPVisitorConfig{},
		checkCloseCh: make(chan struct{}),
		readCh:       make(chan *msg.UDPPacket, 8),
		sendCh:       make(chan *msg.UDPPacket, 8),
	}
}

func sudpTestPacket(content string) *msg.UDPPacket {
	return &msg.UDPPacket{Content: []byte(content)}
}

func mustSUDPReadWriter(t *testing.T, conn net.Conn) msg.ReadWriter {
	t.Helper()
	rw, err := msg.NewUDPPacketReadWriter(conn, "", "")
	require.NoError(t, err)
	return rw
}

type sudpWriteFailConn struct {
	closed     chan struct{}
	closeOnce  atomic.Bool
	writeCount atomic.Int32
}

func newSUDPWriteFailConn() *sudpWriteFailConn {
	return &sudpWriteFailConn{closed: make(chan struct{})}
}

func (c *sudpWriteFailConn) Read([]byte) (int, error) {
	<-c.closed
	return 0, io.ErrClosedPipe
}

func (c *sudpWriteFailConn) Write([]byte) (int, error) {
	c.writeCount.Add(1)
	return 0, errors.New("ambiguous write failure")
}

func (c *sudpWriteFailConn) Close() error {
	if c.closeOnce.CompareAndSwap(false, true) {
		close(c.closed)
	}
	return nil
}

func (c *sudpWriteFailConn) LocalAddr() net.Addr              { return sudpTestAddr("local") }
func (c *sudpWriteFailConn) RemoteAddr() net.Addr             { return sudpTestAddr("remote") }
func (c *sudpWriteFailConn) SetDeadline(time.Time) error      { return nil }
func (c *sudpWriteFailConn) SetReadDeadline(time.Time) error  { return nil }
func (c *sudpWriteFailConn) SetWriteDeadline(time.Time) error { return nil }

type sudpTestAddr string

func (a sudpTestAddr) Network() string { return "sudp-test" }
func (a sudpTestAddr) String() string  { return string(a) }
