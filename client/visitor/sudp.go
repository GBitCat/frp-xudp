// Copyright 2017 fatedier, fatedier@gmail.com
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
	"fmt"
	"net"
	"strconv"
	"sync"
	"time"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
	"github.com/fatedier/frp/pkg/proto/udp"
	netpkg "github.com/fatedier/frp/pkg/util/net"
	"github.com/fatedier/frp/pkg/util/xlog"
)

type SUDPVisitor struct {
	*BaseVisitor

	checkCloseCh chan struct{}
	// udpConn is the listener of udp packet
	udpConn *net.UDPConn
	readCh  chan *msg.UDPPacket
	sendCh  chan *msg.UDPPacket

	workers     sync.WaitGroup
	lifecycleMu sync.Mutex
	lifecycle   sudpLifecycleState

	// listenUDPFn is nil in production. It allows startup/commit races to be
	// tested with a real socket without making net.ListenUDP cancellable.
	listenUDPFn func(string, *net.UDPAddr) (*net.UDPConn, error)
	// beforeCommitFn is nil in production and only gates the test commit point.
	beforeCommitFn func()

	// These hooks are nil in production. They keep the dispatcher retry and
	// connection-creation semantics directly testable without changing the
	// connection or channel ownership model.
	newVisitorConnFn func() (net.Conn, func(), error)
	retryInterval    time.Duration

	cfg *v1.SUDPVisitorConfig
}

type sudpLifecycleState uint8

const (
	sudpNotStarted sudpLifecycleState = iota
	sudpStarting
	sudpRunning
	sudpClosed
)

type sudpVisitorConnResult struct {
	conn      net.Conn
	recycleFn func()
	err       error
}

func (r sudpVisitorConnResult) recycle() {
	if r.conn != nil {
		_ = r.conn.Close()
	}
	if r.recycleFn != nil {
		r.recycleFn()
	}
}

type sudpVisitorConnRequest struct {
	resultCh chan sudpVisitorConnResult
	doneCh   chan struct{}

	mu       sync.Mutex
	canceled bool
}

func newSUDPVisitorConnRequest(
	getConn func() (net.Conn, func(), error),
) *sudpVisitorConnRequest {
	req := &sudpVisitorConnRequest{
		resultCh: make(chan sudpVisitorConnResult, 1),
		doneCh:   make(chan struct{}),
	}
	// getNewVisitorConn ultimately uses an API without cancellation support. Do
	// not add this goroutine to workers: the lower-level connection deadlines
	// guarantee that it eventually returns, while this delivery wrapper owns and
	// recycles any result that arrives after shutdown.
	go func() {
		defer close(req.doneCh)
		conn, recycleFn, err := getConn()
		result := sudpVisitorConnResult{conn: conn, recycleFn: recycleFn, err: err}

		req.mu.Lock()
		if req.canceled {
			req.mu.Unlock()
			result.recycle()
			return
		}
		// There is one producer and the channel has capacity one. Keep this send
		// explicitly non-blocking so a dispatcher exit can never strand it.
		select {
		case req.resultCh <- result:
			req.mu.Unlock()
		default:
			req.mu.Unlock()
			result.recycle()
		}
	}()
	return req
}

func (r *sudpVisitorConnRequest) wait(closeCh <-chan struct{}) (sudpVisitorConnResult, bool) {
	select {
	case result := <-r.resultCh:
		// Prefer shutdown if it became visible at the same time as the result.
		select {
		case <-closeCh:
			r.cancel()
			result.recycle()
			return sudpVisitorConnResult{}, false
		default:
			return result, true
		}
	case <-closeCh:
		r.cancel()
		return sudpVisitorConnResult{}, false
	}
}

func (r *sudpVisitorConnRequest) cancel() {
	r.mu.Lock()
	r.canceled = true
	var result *sudpVisitorConnResult
	select {
	case delivered := <-r.resultCh:
		result = &delivered
	default:
	}
	r.mu.Unlock()

	if result != nil {
		result.recycle()
	}
}

// SUDP Run start listen a udp port
func (sv *SUDPVisitor) Run() (err error) {
	sv.lifecycleMu.Lock()
	if sv.lifecycle != sudpNotStarted {
		state := sv.lifecycle
		sv.lifecycleMu.Unlock()
		if state == sudpClosed {
			return fmt.Errorf("sudp visitor is closed")
		}
		return fmt.Errorf("sudp visitor is already running")
	}
	if sv.checkCloseCh == nil {
		sv.checkCloseCh = make(chan struct{})
	}
	sv.lifecycle = sudpStarting
	sv.lifecycleMu.Unlock()

	xl := xlog.FromContextSafe(sv.ctx)

	addr, err := net.ResolveUDPAddr("udp", net.JoinHostPort(sv.cfg.BindAddr, strconv.Itoa(sv.cfg.BindPort)))
	if err != nil {
		return sv.failStartup(fmt.Errorf("sudp ResolveUDPAddr error: %v", err))
	}

	listenUDP := sv.listenUDPFn
	if listenUDP == nil {
		listenUDP = net.ListenUDP
	}
	udpConn, err := listenUDP("udp", addr)
	if err != nil {
		return sv.failStartup(fmt.Errorf("listen udp port %s error: %v", addr.String(), err))
	}

	readCh := make(chan *msg.UDPPacket, 1024)
	sendCh := make(chan *msg.UDPPacket, 1024)
	if sv.beforeCommitFn != nil {
		sv.beforeCommitFn()
	}

	// Commit all shared resources and the worker count atomically. Close can
	// mark the visitor closed while ListenUDP is in progress; in that case the
	// temporary socket is never published and is closed by this goroutine.
	sv.lifecycleMu.Lock()
	if sv.lifecycle != sudpStarting {
		sv.lifecycleMu.Unlock()
		_ = udpConn.Close()
		return fmt.Errorf("sudp visitor was closed during startup")
	}
	sv.udpConn = udpConn
	sv.readCh = readCh
	sv.sendCh = sendCh
	sv.workers.Add(2)
	sv.lifecycle = sudpRunning
	sv.lifecycleMu.Unlock()

	xl.Infof("sudp start to work, listen on %s", addr)

	go func() {
		defer sv.workers.Done()
		sv.dispatcher()
	}()
	go func() {
		defer sv.workers.Done()
		udp.ForwardUserConn(udpConn, readCh, sendCh, int(sv.clientCfg.UDPPacketSize))
	}()

	return
}

func (sv *SUDPVisitor) failStartup(err error) error {
	shouldCloseBase := false
	sv.lifecycleMu.Lock()
	if sv.lifecycle == sudpStarting {
		sv.lifecycle = sudpClosed
		if sv.checkCloseCh == nil {
			sv.checkCloseCh = make(chan struct{})
		}
		close(sv.checkCloseCh)
		shouldCloseBase = true
	}
	sv.lifecycleMu.Unlock()
	if shouldCloseBase {
		sv.BaseVisitor.Close()
	}
	return err
}

func (sv *SUDPVisitor) dispatcher() {
	xl := xlog.FromContextSafe(sv.ctx)

	var pendingPacket *msg.UDPPacket

	for {
		if pendingPacket == nil {
			select {
			case pendingPacket = <-sv.sendCh:
				if pendingPacket == nil {
					xl.Infof("frpc sudp visitor proxy is closed")
					return
				}
			case <-sv.checkCloseCh:
				xl.Infof("frpc sudp visitor proxy is closed")
				return
			}
		}

		request := newSUDPVisitorConnRequest(sv.newVisitorConn)
		result, ok := request.wait(sv.checkCloseCh)
		if !ok {
			xl.Infof("frpc sudp visitor proxy is closed")
			return
		}
		if result.err != nil {
			// No worker was created, so pendingPacket has not crossed the
			// delivery boundary. Keep it and retry after a cancellable,
			// bounded delay. Do not consume sendCh while waiting: packets
			// arriving behind it remain FIFO in sendCh for the worker.
			result.recycle()
			xl.Warnf("newVisitorConn to frps error: %v, try to reconnect", result.err)
			if !sv.waitForConnRetry() {
				return
			}
			continue
		}

		// Ownership crosses the delivery boundary here. worker writes this
		// packet at most once; a failed/ambiguous WriteMsg is deliberately not
		// returned to pendingPacket because replay could duplicate it remotely.
		firstPacket := pendingPacket
		pendingPacket = nil
		func() {
			defer result.recycle()
			sv.worker(result.conn, firstPacket)
		}()

		select {
		case <-sv.checkCloseCh:
			return
		default:
		}
	}
}

func (sv *SUDPVisitor) newVisitorConn() (net.Conn, func(), error) {
	if sv.newVisitorConnFn != nil {
		return sv.newVisitorConnFn()
	}
	return sv.getNewVisitorConn()
}

func (sv *SUDPVisitor) waitForConnRetry() bool {
	interval := sv.retryInterval
	if interval <= 0 {
		interval = time.Second
	}
	timer := time.NewTimer(interval)
	defer timer.Stop()
	select {
	case <-timer.C:
		return true
	case <-sv.checkCloseCh:
		return false
	}
}

func (sv *SUDPVisitor) worker(workConn net.Conn, firstPacket *msg.UDPPacket) {
	xl := xlog.FromContextSafe(sv.ctx)
	xl.Debugf("starting sudp proxy worker")
	payloadRW, err := msg.NewUDPPacketReadWriter(workConn, sv.clientCfg.Transport.WireProtocol, udpPacketCodecFromHelper(sv.helper))
	if err != nil {
		xl.Errorf("create SUDP packet read writer: %v", err)
		_ = workConn.Close()
		return
	}
	payloadConn := msg.NewConn(workConn, payloadRW)

	wg := &sync.WaitGroup{}
	wg.Add(3)
	workerCloseCh := make(chan struct{})
	var closeWorkerOnce sync.Once
	closeWorker := func() {
		closeWorkerOnce.Do(func() { close(workerCloseCh) })
	}

	// Closing the proxy must interrupt both a blocked first-packet write and a
	// blocked read. Closing payloadConn is the common cancellation mechanism for
	// the two directions.
	go func() {
		defer wg.Done()
		select {
		case <-sv.checkCloseCh:
		case <-workerCloseCh:
		}
		_ = payloadConn.Close()
	}()

	// udp service -> frpc -> frps -> frpc visitor -> user
	workConnReaderFn := func(payloadConn *msg.Conn) {
		defer func() {
			closeWorker()
			payloadConn.Close()
			wg.Done()
		}()

		for {
			var (
				rawMsg msg.Message
				errRet error
			)

			// frpc will send heartbeat in workConn to frpc visitor for keeping alive
			_ = payloadConn.SetReadDeadline(time.Now().Add(60 * time.Second))
			if rawMsg, errRet = payloadConn.ReadMsg(); errRet != nil {
				xl.Warnf("read from workconn for user udp conn error: %v", errRet)
				return
			}

			_ = payloadConn.SetReadDeadline(time.Time{})
			switch m := rawMsg.(type) {
			case *msg.Ping:
				xl.Debugf("frpc visitor get ping message from frpc")
				continue
			case *msg.UDPPacket:
				select {
				case sv.readCh <- m:
					xl.Tracef("frpc visitor get udp packet from workConn, len: %d", len(m.Content))
				case <-sv.checkCloseCh:
					xl.Infof("reader goroutine for udp work connection closed")
					return
				case <-workerCloseCh:
					xl.Infof("reader goroutine for udp work connection closed")
					return
				}
			}
		}
	}

	// udp service <- frpc <- frps <- frpc visitor <- user
	workConnSenderFn := func(payloadConn *msg.Conn) {
		defer func() {
			closeWorker()
			payloadConn.Close()
			wg.Done()
		}()

		var errRet error
		if firstPacket != nil {
			if errRet = payloadConn.WriteMsg(firstPacket); errRet != nil {
				xl.Warnf("sender goroutine for udp work connection closed: %v", errRet)
				return
			}
			xl.Tracef("send udp package to workConn, len: %d", len(firstPacket.Content))
		}

		for {
			select {
			case udpMsg := <-sv.sendCh:
				if errRet = payloadConn.WriteMsg(udpMsg); errRet != nil {
					xl.Warnf("sender goroutine for udp work connection closed: %v", errRet)
					return
				}
				xl.Tracef("send udp package to workConn, len: %d", len(udpMsg.Content))
			case <-workerCloseCh:
				return
			case <-sv.checkCloseCh:
				return
			}
		}
	}

	go workConnReaderFn(payloadConn)
	go workConnSenderFn(payloadConn)

	wg.Wait()
	xl.Infof("sudp worker is closed")
}

func (sv *SUDPVisitor) getNewVisitorConn() (net.Conn, func(), error) {
	rawConn, err := sv.dialRawVisitorConn(sv.cfg.GetBaseConfig())
	if err != nil {
		return nil, func() {}, err
	}
	rwc, recycleFn, err := wrapVisitorConn(rawConn, sv.cfg.GetBaseConfig())
	if err != nil {
		rawConn.Close()
		return nil, func() {}, err
	}
	return netpkg.WrapReadWriteCloserToConn(rwc, rawConn), recycleFn, nil
}

func (sv *SUDPVisitor) Close() {
	sv.lifecycleMu.Lock()
	if sv.lifecycle == sudpClosed {
		sv.lifecycleMu.Unlock()
		sv.workers.Wait()
		return
	}
	sv.lifecycle = sudpClosed
	if sv.checkCloseCh == nil {
		sv.checkCloseCh = make(chan struct{})
	}
	close(sv.checkCloseCh)
	udpConn := sv.udpConn
	sv.lifecycleMu.Unlock()

	// The state is closed before any external cleanup, so a concurrent Run
	// cannot commit a new socket or add workers after this Wait.
	sv.BaseVisitor.Close()
	if udpConn != nil {
		_ = udpConn.Close()
	}
	sv.workers.Wait()
}
