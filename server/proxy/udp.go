// Copyright 2019 fatedier, fatedier@gmail.com
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
	"fmt"
	"io"
	"net"
	"reflect"
	"strconv"
	"sync"
	"time"

	libio "github.com/fatedier/golib/io"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
	"github.com/fatedier/frp/pkg/proto/udp"
	"github.com/fatedier/frp/pkg/util/limit"
	netpkg "github.com/fatedier/frp/pkg/util/net"
	"github.com/fatedier/frp/server/metrics"
)

func init() {
	RegisterProxyFactory(reflect.TypeFor[*v1.UDPProxyConfig](), NewUDPProxy)
}

type UDPProxy struct {
	*BaseProxy
	cfg *v1.UDPProxyConfig

	realBindPort int

	// udpConn is the listener of udp packages
	udpConn *net.UDPConn

	// there are always only one workConn at the same time
	// get another one if it closed
	workConn net.Conn

	// sendCh is used for sending packages to workConn
	sendCh chan *msg.UDPPacket

	// readCh is used for reading packages from workConn
	readCh chan *msg.UDPPacket

	// reconnectCh notifies the dispatcher that the current workConn is closed.
	reconnectCh chan struct{}

	// doneCh is the sole proxy-lifetime shutdown signal.
	doneCh chan struct{}

	workers      sync.WaitGroup
	shutdownOnce sync.Once
	releaseOnce  sync.Once
	isClosed     bool
}

type udpWorkConnResult struct {
	conn net.Conn
	err  error
}

func (r udpWorkConnResult) close() {
	if r.conn != nil {
		_ = r.conn.Close()
	}
}

type udpWorkConnRequest struct {
	resultCh chan udpWorkConnResult
	doneCh   chan struct{}

	mu       sync.Mutex
	canceled bool
}

func newUDPWorkConnRequest(getConn func() (net.Conn, error)) *udpWorkConnRequest {
	req := &udpWorkConnRequest{
		resultCh: make(chan udpWorkConnResult, 1),
		doneCh:   make(chan struct{}),
	}
	// GetWorkConnFromPool has no cancellation API. Keep this request outside the
	// main workers WaitGroup: its existing lower-level deadlines ensure eventual
	// return, and this wrapper closes any work connection delivered after doneCh.
	go func() {
		defer close(req.doneCh)
		conn, err := getConn()
		result := udpWorkConnResult{conn: conn, err: err}

		req.mu.Lock()
		if req.canceled {
			req.mu.Unlock()
			result.close()
			return
		}
		// There is one producer and the channel has capacity one. Keep this send
		// explicitly non-blocking so shutdown can never leave the caller stuck.
		select {
		case req.resultCh <- result:
			req.mu.Unlock()
		default:
			req.mu.Unlock()
			result.close()
		}
	}()
	return req
}

func (r *udpWorkConnRequest) wait(doneCh <-chan struct{}) (udpWorkConnResult, bool) {
	select {
	case result := <-r.resultCh:
		// Prefer shutdown if it became visible at the same time as the result.
		select {
		case <-doneCh:
			r.cancel()
			result.close()
			return udpWorkConnResult{}, false
		default:
			return result, true
		}
	case <-doneCh:
		r.cancel()
		return udpWorkConnResult{}, false
	}
}

func (r *udpWorkConnRequest) cancel() {
	r.mu.Lock()
	r.canceled = true
	var result *udpWorkConnResult
	select {
	case delivered := <-r.resultCh:
		result = &delivered
	default:
	}
	r.mu.Unlock()

	if result != nil {
		result.close()
	}
}

func NewUDPProxy(baseProxy *BaseProxy) Proxy {
	unwrapped, ok := baseProxy.GetConfigurer().(*v1.UDPProxyConfig)
	if !ok {
		return nil
	}
	baseProxy.usedPortsNum = 1
	return &UDPProxy{
		BaseProxy: baseProxy,
		cfg:       unwrapped,
	}
}

func (pxy *UDPProxy) Run() (remoteAddr string, err error) {
	xl := pxy.xl
	pxy.realBindPort, err = pxy.rc.UDPPortManager.Acquire(pxy.name, pxy.cfg.RemotePort)
	if err != nil {
		return "", fmt.Errorf("acquire port %d error: %v", pxy.cfg.RemotePort, err)
	}
	defer func() {
		if err != nil {
			pxy.releasePort()
		}
	}()

	remoteAddr = fmt.Sprintf(":%d", pxy.realBindPort)
	pxy.cfg.RemotePort = pxy.realBindPort
	addr, errRet := net.ResolveUDPAddr("udp", net.JoinHostPort(pxy.serverCfg.ProxyBindAddr, strconv.Itoa(pxy.realBindPort)))
	if errRet != nil {
		err = errRet
		return
	}
	udpConn, errRet := net.ListenUDP("udp", addr)
	if errRet != nil {
		err = errRet
		xl.Warnf("listen udp port error: %v", err)
		return
	}
	xl.Infof("udp proxy listen port [%d]", pxy.cfg.RemotePort)

	pxy.udpConn = udpConn
	pxy.sendCh = make(chan *msg.UDPPacket, 1024)
	pxy.readCh = make(chan *msg.UDPPacket, 1024)
	pxy.reconnectCh = make(chan struct{}, 1)
	pxy.doneCh = make(chan struct{})

	// read message from workConn, if it returns any error, notify proxy to start a new workConn
	workConnReaderFn := func(payloadConn *msg.Conn) {
		for {
			var (
				rawMsg msg.Message
				errRet error
			)
			xl.Tracef("loop waiting message from udp workConn")
			// client will send heartbeat in workConn for keeping alive
			_ = payloadConn.SetReadDeadline(time.Now().Add(time.Duration(60) * time.Second))
			if rawMsg, errRet = payloadConn.ReadMsg(); errRet != nil {
				xl.Warnf("read from workConn for udp error: %v", errRet)
				_ = payloadConn.Close()
				// Notify the dispatcher without racing with proxy shutdown.
				select {
				case pxy.reconnectCh <- struct{}{}:
				case <-pxy.doneCh:
				}
				return
			}
			if err := payloadConn.SetReadDeadline(time.Time{}); err != nil {
				xl.Warnf("set read deadline error: %v", err)
			}
			switch m := rawMsg.(type) {
			case *msg.Ping:
				xl.Tracef("udp work conn get ping message")
				continue
			case *msg.UDPPacket:
				if pxy.deliverWorkConnPacket(m) {
					xl.Tracef("get udp message from workConn, len: %d", len(m.Content))
					metrics.Server.AddTrafficOut(
						pxy.GetName(),
						pxy.GetConfigurer().GetBaseConfig().Type,
						int64(len(m.Content)),
					)
				} else {
					_ = payloadConn.Close()
					xl.Infof("reader goroutine for udp work connection closed")
					return
				}
			}
		}
	}

	// send message to workConn
	workConnSenderFn := func(payloadConn *msg.Conn, ctx context.Context, firstPacket *msg.UDPPacket) *msg.UDPPacket {
		pendingPacket := firstPacket
		for {
			if pendingPacket == nil {
				select {
				case pendingPacket = <-pxy.sendCh:
				case <-ctx.Done():
					xl.Infof("sender goroutine for udp work connection closed")
					return nil
				case <-pxy.doneCh:
					xl.Infof("sender goroutine for udp work connection closed")
					return nil
				}
			}

			// Cancellation can race with receiving from sendCh. Preserve a packet
			// already removed from the shared FIFO instead of attempting it on a
			// connection the dispatcher is replacing.
			select {
			case <-ctx.Done():
				return pendingPacket
			case <-pxy.doneCh:
				return pendingPacket
			default:
			}

			if err := payloadConn.WriteMsg(pendingPacket); err != nil {
				xl.Infof("sender goroutine for udp work connection closed: %v", err)
				_ = payloadConn.Close()
				return pendingPacket
			}
			xl.Tracef("send message to udp workConn, len: %d", len(pendingPacket.Content))
			metrics.Server.AddTrafficIn(
				pxy.GetName(),
				pxy.GetConfigurer().GetBaseConfig().Type,
				int64(len(pendingPacket.Content)),
			)
			pendingPacket = nil
		}
	}

	pxy.workers.Add(2)
	go func() {
		defer pxy.workers.Done()
		// Sleep a while for waiting control send the NewProxyResp to client.
		select {
		case <-time.After(500 * time.Millisecond):
		case <-pxy.doneCh:
			return
		}
		var pendingPacket *msg.UDPPacket
		for {
			select {
			case <-pxy.doneCh:
				return
			default:
			}

			request := newUDPWorkConnRequest(func() (net.Conn, error) {
				return pxy.GetWorkConnFromPool(nil, nil)
			})
			result, ok := request.wait(pxy.doneCh)
			if !ok {
				return
			}
			workConn, err := result.conn, result.err
			if err != nil {
				result.close()
				select {
				case <-time.After(time.Second):
				case <-pxy.doneCh:
					return
				}
				continue
			}

			var rwc io.ReadWriteCloser = workConn
			if pxy.cfg.Transport.UseEncryption {
				rwc, err = libio.WithEncryption(rwc, pxy.encryptionKey)
				if err != nil {
					xl.Errorf("create encryption stream error: %v", err)
					workConn.Close()
					continue
				}
			}
			if pxy.cfg.Transport.UseCompression {
				rwc = libio.WithCompression(rwc)
			}

			if pxy.GetLimiter() != nil {
				rwc = libio.WrapReadWriteCloser(limit.NewReader(rwc, pxy.GetLimiter()), limit.NewWriter(rwc, pxy.GetLimiter()), func() error {
					return rwc.Close()
				})
			}

			wrappedWorkConn := netpkg.WrapReadWriteCloserToConn(rwc, workConn)
			// Plain UDP payload follows the negotiated wire protocol for message framing.
			payloadRW, err := msg.NewUDPPacketReadWriter(wrappedWorkConn, pxy.wireProtocol, pxy.udpPacketCodec)
			if err != nil {
				xl.Errorf("create UDP packet read writer: %v", err)
				wrappedWorkConn.Close()
				continue
			}
			if !pxy.replaceWorkConn(wrappedWorkConn) {
				return
			}
			payloadConn := msg.NewConn(wrappedWorkConn, payloadRW)
			ctx, cancel := context.WithCancel(context.Background())
			var connectionWorkers sync.WaitGroup
			senderDone := make(chan *msg.UDPPacket, 1)
			firstPacket := pendingPacket
			pendingPacket = nil
			connectionWorkers.Add(2)
			pxy.workers.Add(2)
			go func() {
				defer connectionWorkers.Done()
				defer pxy.workers.Done()
				workConnReaderFn(payloadConn)
			}()
			go func() {
				defer connectionWorkers.Done()
				defer pxy.workers.Done()
				senderDone <- workConnSenderFn(payloadConn, ctx, firstPacket)
			}()
			shuttingDown := false
			select {
			case <-pxy.reconnectCh:
			case <-pxy.doneCh:
				shuttingDown = true
			}
			cancel()
			_ = payloadConn.Close()
			// Join both workers before obtaining or publishing another workConn.
			// This preserves single-consumer ownership of sendCh across reconnects.
			connectionWorkers.Wait()
			pendingPacket = <-senderDone
			if shuttingDown {
				return
			}
		}
	}()

	// Read from user connections and send wrapped udp message to sendCh (forwarded by workConn).
	// Client will transfor udp message to local udp service and waiting for response for a while.
	// Response will be wrapped to be forwarded by work connection to server.
	go func() {
		udp.ForwardUserConn(udpConn, pxy.readCh, pxy.sendCh, int(pxy.serverCfg.UDPPacketSize))
		// This goroutine may initiate shutdown, so remove it from the worker set
		// before calling Close and waiting for all remaining workers.
		pxy.workers.Done()
		pxy.Close()
	}()
	return remoteAddr, nil
}

func (pxy *UDPProxy) deliverWorkConnPacket(packet *msg.UDPPacket) bool {
	select {
	case pxy.readCh <- packet:
		return true
	case <-pxy.doneCh:
		return false
	}
}

func (pxy *UDPProxy) replaceWorkConn(workConn net.Conn) bool {
	pxy.mu.Lock()
	if pxy.isClosed {
		pxy.mu.Unlock()
		_ = workConn.Close()
		return false
	}
	oldWorkConn := pxy.workConn
	pxy.workConn = workConn
	pxy.mu.Unlock()

	if oldWorkConn != nil {
		_ = oldWorkConn.Close()
	}
	return true
}

func (pxy *UDPProxy) Close() {
	pxy.initiateShutdown()
	pxy.workers.Wait()
	pxy.releasePort()
}

func (pxy *UDPProxy) initiateShutdown() {
	pxy.shutdownOnce.Do(func() {
		pxy.mu.Lock()
		pxy.isClosed = true
		if pxy.doneCh != nil {
			close(pxy.doneCh)
		}
		workConn := pxy.workConn
		pxy.workConn = nil
		udpConn := pxy.udpConn
		pxy.mu.Unlock()

		pxy.BaseProxy.Close()
		if workConn != nil {
			_ = workConn.Close()
		}
		if udpConn != nil {
			_ = udpConn.Close()
		}
	})
}

func (pxy *UDPProxy) releasePort() {
	pxy.releaseOnce.Do(func() {
		if pxy.realBindPort > 0 && pxy.rc != nil && pxy.rc.UDPPortManager != nil {
			pxy.rc.UDPPortManager.Release(pxy.realBindPort)
		}
	})
}
