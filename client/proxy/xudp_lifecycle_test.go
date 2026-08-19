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

//go:build !frps

package proxy

import (
	"context"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
	"github.com/fatedier/frp/pkg/nathole"
	plugin "github.com/fatedier/frp/pkg/plugin/client"
	"github.com/fatedier/frp/pkg/util/xlog"
	xudptransport "github.com/fatedier/frp/pkg/xudp/transport"
	quic "github.com/quic-go/quic-go"
)

type xudpLifecycleTestPlugin struct {
	closeCount atomic.Int32
}

func (*xudpLifecycleTestPlugin) Name() string { return "xudp-lifecycle-test" }

func (*xudpLifecycleTestPlugin) Handle(context.Context, *plugin.ConnectionInfo) {}

func (p *xudpLifecycleTestPlugin) Close() error {
	p.closeCount.Add(1)
	return nil
}

func newXUDPLifecycleTestProxy() *XUDPProxy {
	pxy := &XUDPProxy{BaseProxy: &BaseProxy{
		ctx: context.Background(),
		xl:  xlog.New(),
	}}
	pxy.initLifecycle()
	return pxy
}

func newProductionXUDPLifecycleTestProxy() *XUDPProxy {
	pxy := newXUDPLifecycleTestProxy()
	pxy.BaseProxy.baseCfg = &v1.ProxyBaseConfig{}
	pxy.BaseProxy.clientCfg = &v1.ClientCommonConfig{UDPPacketSize: 1500}
	pxy.cfg = &v1.XUDPProxyConfig{}
	return pxy
}

func promoteProductionXUDPConn(t *testing.T, pxy *XUDPProxy) (*xudpConnLifecycle, net.Conn, net.Conn) {
	t.Helper()
	conn, peer := net.Pipe()
	id, ok := pxy.registerPending(conn)
	if !ok {
		_ = conn.Close()
		_ = peer.Close()
		t.Fatal("registerPending rejected production-path test connection")
	}
	lc, ok := pxy.promotePending(id, conn)
	if !ok {
		_ = conn.Close()
		_ = peer.Close()
		t.Fatal("promotePending rejected production-path test connection")
	}
	lc.addCloser(func() { _ = conn.Close() })
	return lc, conn, peer
}

func activateXUDPLifecycleTestConn(t *testing.T, pxy *XUDPProxy) (*xudpConnLifecycle, net.Conn, <-chan struct{}) {
	t.Helper()
	conn, peer := net.Pipe()
	id, ok := pxy.registerPending(conn)
	if !ok {
		_ = conn.Close()
		_ = peer.Close()
		t.Fatal("registerPending rejected an open test connection")
	}
	lc, ok := pxy.promotePending(id, conn)
	if !ok {
		_ = conn.Close()
		_ = peer.Close()
		t.Fatal("promotePending rejected an open test connection")
	}
	lc.addCloser(func() { _ = conn.Close() })
	joined := make(chan struct{})
	go func() {
		<-lc.ctx.Done()
		pxy.finishActive(lc)
		close(joined)
	}()
	t.Cleanup(func() {
		_ = peer.Close()
		pxy.Close()
	})
	return lc, peer, joined
}

func TestXUDPProxyCloseCancelsAndJoinsActiveP2PAndRelay(t *testing.T) {
	for _, mode := range []string{"p2p", "relay"} {
		t.Run(mode, func(t *testing.T) {
			pxy := newXUDPLifecycleTestProxy()
			plugin := &xudpLifecycleTestPlugin{}
			pxy.proxyPlugin = plugin
			var closeCount atomic.Int32
			lc, peer, joined := activateXUDPLifecycleTestConn(t, pxy)
			lc.addCloser(func() { closeCount.Add(1) })

			closeDone := make(chan struct{})
			var closeCallers sync.WaitGroup
			for i := 0; i < 16; i++ {
				closeCallers.Add(1)
				go func() {
					defer closeCallers.Done()
					pxy.Close()
				}()
			}
			go func() {
				closeCallers.Wait()
				close(closeDone)
			}()
			select {
			case <-closeDone:
			case <-time.After(time.Second):
				t.Fatal("XUDPProxy.Close did not join the active connection")
			}
			select {
			case <-joined:
			case <-time.After(time.Second):
				t.Fatal("active XUDP worker group did not join")
			}
			if _, err := peer.Read(make([]byte, 1)); err == nil {
				t.Fatal("Close did not close the active work connection")
			}
			if got := closeCount.Load(); got != 1 {
				t.Fatalf("%s active closer count = %d, want 1", mode, got)
			}
			if got := plugin.closeCount.Load(); got != 1 {
				t.Fatalf("%s BaseProxy plugin Close count = %d, want 1", mode, got)
			}
			pxy.Close()
			if got := plugin.closeCount.Load(); got != 1 {
				t.Fatalf("repeated %s XUDPProxy.Close invoked BaseProxy Close again: %d", mode, got)
			}
		})
	}
}

func TestXUDPProxyCloseRejectsAndClosesNewWorkConn(t *testing.T) {
	pxy := newXUDPLifecycleTestProxy()
	pxy.Close()

	conn, peer := net.Pipe()
	defer peer.Close()
	done := make(chan struct{})
	go func() {
		pxy.InWorkConn(conn, nil)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("InWorkConn did not reject a connection after Close")
	}
	if _, err := peer.Read(make([]byte, 1)); err == nil {
		t.Fatal("rejected work connection remained open")
	}
}

func TestXUDPProxyCloseDoesNotWaitForPendingPrepareAndRejectsLatePromotion(t *testing.T) {
	pxy := newProductionXUDPLifecycleTestProxy()
	conn, peer := net.Pipe()
	defer peer.Close()
	id, ok := pxy.registerPending(conn)
	if !ok {
		t.Fatal("registerPending failed")
	}

	prepareStarted := make(chan struct{})
	prepareRelease := make(chan struct{})
	var preparedConn *net.UDPConn
	pxy.prepareNAT = func([]string, nathole.PrepareOptions) (*nathole.PrepareResult, error) {
		close(prepareStarted)
		<-prepareRelease
		var err error
		preparedConn, err = net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
		if err != nil {
			return nil, err
		}
		return &nathole.PrepareResult{ListenConn: preparedConn}, nil
	}
	prepareDone := make(chan struct{})
	go func() {
		pending := pxy.handleP2PWorkConn(id, conn, conn, nil)
		if pending {
			pxy.finishPending(id, conn)
		}
		close(prepareDone)
	}()
	if err := msg.NewReadWriter(peer, "").WriteMsg(&msg.NatHoleSid{Sid: "late"}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-prepareStarted:
	case <-time.After(time.Second):
		t.Fatal("production pending Prepare hook did not start")
	}

	closeDone := make(chan struct{})
	go func() {
		pxy.Close()
		close(closeDone)
	}()
	select {
	case <-closeDone:
	case <-time.After(200 * time.Millisecond):
		t.Fatal("Close waited for the contextless pending Prepare operation")
	}
	close(prepareRelease)
	select {
	case <-prepareDone:
	case <-time.After(time.Second):
		t.Fatal("late pending Prepare result did not finish and release its connection")
	}
	if preparedConn == nil {
		t.Fatal("Prepare hook did not return a real UDP connection")
	}
	buf := make([]byte, 1)
	_, _, err := preparedConn.ReadFromUDP(buf)
	if err == nil {
		t.Fatal("late Prepare ListenConn remained open after Close")
	}
	pxy.lifecycleMu.Lock()
	activeCount := len(pxy.activeConns)
	pxy.lifecycleMu.Unlock()
	if activeCount != 0 {
		t.Fatalf("late pending Prepare unexpectedly entered active connections: %d", activeCount)
	}
}

func TestXUDPWorkerGroupJoinsAllWorkersAfterRelayEOFAndCancelsHeartbeat(t *testing.T) {
	pxy := newXUDPLifecycleTestProxy()
	lc := &xudpConnLifecycle{ctx: nil}
	lc.ctx, lc.cancel = context.WithCancel(context.Background())
	defer lc.stop()

	var joined atomic.Int32
	pxy.runXUDPWorkers(lc,
		func(context.Context) { joined.Add(1) }, // relay reader observes EOF
		func(ctx context.Context) { <-ctx.Done(); joined.Add(1) },
		func(ctx context.Context) {
			ticker := time.NewTicker(time.Millisecond)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					joined.Add(1)
					return
				case <-ticker.C:
				}
			}
		},
		func(ctx context.Context) { <-ctx.Done(); joined.Add(1) }, // ManagedForwarder
	)
	if got := joined.Load(); got != 4 {
		t.Fatalf("relay worker join count = %d, want 4", got)
	}
}

func TestXUDPRelayProductionPathEOFHeartbeatForwarderAndActiveClose(t *testing.T) {
	echoConn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer echoConn.Close()
	echoSeen := make(chan struct{})
	go func() {
		buf := make([]byte, 1500)
		n, addr, readErr := echoConn.ReadFromUDP(buf)
		if readErr == nil {
			close(echoSeen)
			_, _ = echoConn.WriteToUDP(buf[:n], addr)
		}
	}()

	pxy := newProductionXUDPLifecycleTestProxy()
	pxy.localAddr = echoConn.LocalAddr().(*net.UDPAddr)
	pxy.heartbeatInterval = 2 * time.Millisecond
	lc, conn, peer := promoteProductionXUDPConn(t, pxy)
	workDone := make(chan struct{})
	go func() {
		pxy.handleRelayWorkConn(lc, conn, nil)
		pxy.finishActive(lc)
		close(workDone)
	}()

	// This exercises the real payload reader, ManagedForwarder, UDP echo,
	// sender and heartbeat rather than calling the worker group directly.
	workRW := msg.NewReadWriter(peer, "")
	remoteAddr := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 7004}
	if err := workRW.WriteMsg(&msg.UDPPacket{Content: []byte("relay"), RemoteAddr: remoteAddr}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-echoSeen:
	case <-time.After(time.Second):
		t.Fatal("real relay ManagedForwarder did not forward the UDP packet")
	}

	gotHeartbeat, gotResponse := false, false
	_ = peer.SetReadDeadline(time.Now().Add(time.Second))
	for !gotHeartbeat || !gotResponse {
		m, readErr := workRW.ReadMsg()
		if readErr != nil {
			t.Fatalf("read real relay output: %v", readErr)
		}
		switch m.(type) {
		case *msg.Ping:
			gotHeartbeat = true
		case *msg.UDPPacket:
			gotResponse = true
		}
	}

	// The peer close produces a real EOF in handleRelayWorkConn. All four
	// workers, including ManagedForwarder, must be joined before return.
	_ = peer.Close()
	select {
	case <-workDone:
	case <-time.After(time.Second):
		t.Fatal("real relay production path did not join after EOF")
	}
	pxy.Close()
}

type xudpP2PFailureTransport struct {
	receiveErr error
	sendErr    error
	receives   atomic.Int32
	sends      atomic.Int32
}

type productionFakeDatagramTransport struct {
	receive func(context.Context) ([]byte, error)
	send    func([]byte) error
	closes  atomic.Int32
	reads   atomic.Int32
	writes  atomic.Int32
}

func (t *productionFakeDatagramTransport) SendDatagram(data []byte) error {
	t.writes.Add(1)
	if t.send != nil {
		return t.send(data)
	}
	return nil
}

func (t *productionFakeDatagramTransport) ReceiveDatagram(ctx context.Context) ([]byte, error) {
	t.reads.Add(1)
	return t.receive(ctx)
}

func (*productionFakeDatagramTransport) MaxDatagramPayloadSize() int { return 1200 }
func (*productionFakeDatagramTransport) ConnectionState() quic.ConnectionState {
	return quic.ConnectionState{}
}
func (*productionFakeDatagramTransport) VerifyPeerFingerprint(string) error { return nil }
func (t *productionFakeDatagramTransport) Close() error {
	t.closes.Add(1)
	return nil
}
func (*productionFakeDatagramTransport) LocalAddr() net.Addr  { return &net.UDPAddr{} }
func (*productionFakeDatagramTransport) RemoteAddr() net.Addr { return &net.UDPAddr{} }

func startActiveP2PForward(t *testing.T, pxy *XUDPProxy, transport xudptransport.DatagramTransport) (*xudpConnLifecycle, net.Conn, net.Conn, <-chan struct{}) {
	t.Helper()
	lc, conn, peer := promoteProductionXUDPConn(t, pxy)
	done := make(chan struct{})
	go func() {
		pxy.forwardP2PQUICDatagram(lc, transport)
		pxy.finishActive(lc)
		close(done)
	}()
	return lc, conn, peer, done
}

func TestXUDPP2PProductionReceiveFailureJoinsRealForwarder(t *testing.T) {
	pxy := newProductionXUDPLifecycleTestProxy()
	transport := &productionFakeDatagramTransport{
		receive: func(context.Context) ([]byte, error) { return nil, net.ErrClosed },
	}
	_, _, peer, done := startActiveP2PForward(t, pxy, transport)
	defer peer.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("real P2P receive failure did not join forwarder and sender")
	}
	if transport.reads.Load() != 1 {
		t.Fatalf("real P2P ReceiveDatagram calls = %d, want 1", transport.reads.Load())
	}
	pxy.Close()
}

func TestXUDPP2PProductionSendFailureJoinsRealForwarder(t *testing.T) {
	echoConn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer echoConn.Close()
	echoDone := make(chan struct{})
	go func() {
		buf := make([]byte, 1500)
		n, addr, readErr := echoConn.ReadFromUDP(buf)
		if readErr == nil {
			_, _ = echoConn.WriteToUDP(buf[:n], addr)
			close(echoDone)
		}
	}()

	packet, err := msg.EncodeUDPPacketBinary(&msg.UDPPacket{
		Content:    []byte("p2p"),
		RemoteAddr: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 7005},
	})
	if err != nil {
		t.Fatal(err)
	}
	transport := &productionFakeDatagramTransport{
		receive: func(ctx context.Context) ([]byte, error) {
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			default:
				return packet, nil
			}
		},
		send: func([]byte) error { return net.ErrClosed },
	}
	pxy := newProductionXUDPLifecycleTestProxy()
	pxy.localAddr = echoConn.LocalAddr().(*net.UDPAddr)
	_, _, peer, done := startActiveP2PForward(t, pxy, transport)
	defer peer.Close()
	select {
	case <-echoDone:
	case <-time.After(time.Second):
		t.Fatal("real P2P ManagedForwarder did not send the received datagram to UDP")
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("real P2P SendDatagram failure did not join receive and forwarder")
	}
	if transport.writes.Load() == 0 {
		t.Fatal("real P2P sender never called SendDatagram")
	}
	pxy.Close()
}

func TestXUDPP2PProductionCloseUsesActiveRegistration(t *testing.T) {
	started := make(chan struct{})
	transport := &productionFakeDatagramTransport{
		receive: func(ctx context.Context) ([]byte, error) {
			close(started)
			<-ctx.Done()
			return nil, ctx.Err()
		},
	}
	pxy := newProductionXUDPLifecycleTestProxy()
	_, conn, peer, done := startActiveP2PForward(t, pxy, transport)
	defer peer.Close()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("real P2P receiver did not start")
	}
	closeDone := make(chan struct{})
	go func() {
		pxy.Close()
		close(closeDone)
	}()
	select {
	case <-closeDone:
	case <-time.After(time.Second):
		t.Fatal("XUDPProxy.Close did not join the real active P2P path")
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("real active P2P goroutine remained after Close")
	}
	if _, err := conn.Write([]byte("closed")); err == nil {
		t.Fatal("active work connection remained open after XUDPProxy.Close")
	}
}

func (t *xudpP2PFailureTransport) ReceiveDatagram(context.Context) ([]byte, error) {
	t.receives.Add(1)
	return nil, t.receiveErr
}

func (t *xudpP2PFailureTransport) SendDatagram([]byte) error {
	t.sends.Add(1)
	return t.sendErr
}

func TestXUDPP2PReceiveFailureCancelsSendAndForwarderAndJoins(t *testing.T) {
	pxy := newXUDPLifecycleTestProxy()
	lc := &xudpConnLifecycle{}
	lc.ctx, lc.cancel = context.WithCancel(context.Background())
	defer lc.stop()
	transport := &xudpP2PFailureTransport{receiveErr: net.ErrClosed}
	var joined atomic.Int32

	pxy.runXUDPWorkers(lc,
		func(ctx context.Context) {
			_, _ = transport.ReceiveDatagram(ctx)
			joined.Add(1)
		},
		func(ctx context.Context) { <-ctx.Done(); joined.Add(1) },
		func(ctx context.Context) { <-ctx.Done(); joined.Add(1) },
	)
	if transport.receives.Load() != 1 || joined.Load() != 3 {
		t.Fatalf("receive failure did not join/cancel full P2P group: receives=%d joined=%d", transport.receives.Load(), joined.Load())
	}
}

func TestXUDPP2PSendFailureCancelsReceiveAndForwarderAndJoins(t *testing.T) {
	pxy := newXUDPLifecycleTestProxy()
	lc := &xudpConnLifecycle{}
	lc.ctx, lc.cancel = context.WithCancel(context.Background())
	defer lc.stop()
	transport := &xudpP2PFailureTransport{sendErr: net.ErrClosed}
	var joined atomic.Int32

	pxy.runXUDPWorkers(lc,
		func(ctx context.Context) { <-ctx.Done(); joined.Add(1) },
		func(context.Context) {
			_ = transport.SendDatagram([]byte("packet"))
			joined.Add(1)
		},
		func(ctx context.Context) { <-ctx.Done(); joined.Add(1) },
	)
	if transport.sends.Load() != 1 || joined.Load() != 3 {
		t.Fatalf("send failure did not join/cancel full P2P group: sends=%d joined=%d", transport.sends.Load(), joined.Load())
	}
}

func TestXUDPLifecycleCloserRegisteredAfterStopRunsImmediately(t *testing.T) {
	lc := &xudpConnLifecycle{}
	lc.ctx, lc.cancel = context.WithCancel(context.Background())
	lc.stop()
	closed := make(chan struct{})
	lc.addCloser(func() { close(closed) })
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("late resource registered after stop was not closed")
	}
}
