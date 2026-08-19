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
	"bufio"
	"bytes"
	"context"
	stderrors "errors"
	"fmt"
	"io"
	"net"
	"reflect"
	"strconv"
	"sync"
	"time"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
	"github.com/fatedier/frp/pkg/naming"
	"github.com/fatedier/frp/pkg/nathole"
	"github.com/fatedier/frp/pkg/proto/udp"
	"github.com/fatedier/frp/pkg/proto/wire"
	netpkg "github.com/fatedier/frp/pkg/util/net"
	xudptransport "github.com/fatedier/frp/pkg/xudp/transport"
)

func init() {
	RegisterProxyFactory(reflect.TypeFor[*v1.XUDPProxyConfig](), NewXUDPProxy)
}

// bufferedConn wraps a net.Conn so that reads go through a bufio.Reader
// (which may hold peeked-but-unconsumed data) while writes go to the
// underlying connection.
type bufferedConn struct {
	net.Conn
	reader io.Reader
}

func (bc *bufferedConn) Read(p []byte) (int, error) {
	return bc.reader.Read(p)
}

type XUDPProxy struct {
	*BaseProxy
	cfg *v1.XUDPProxyConfig

	localAddr         *net.UDPAddr
	heartbeatInterval time.Duration
	prepareNAT        func([]string, nathole.PrepareOptions) (*nathole.PrepareResult, error)

	lifecycleOnce   sync.Once
	lifecycleCtx    context.Context
	lifecycleCancel context.CancelFunc
	lifecycleMu     sync.Mutex
	closed          bool
	nextConnID      uint64
	pendingConns    map[uint64]net.Conn
	activeConns     map[uint64]*xudpConnLifecycle
	activeWG        sync.WaitGroup
	closeOnce       sync.Once
	baseCloseOnce   sync.Once
}

// xudpConnLifecycle is the cancellation and resource-ownership boundary for
// one Relay or P2P data plane. Closers can be registered while setup advances;
// registration after stop closes the resource immediately.
type xudpConnLifecycle struct {
	id     uint64
	ctx    context.Context
	cancel context.CancelFunc

	mu      sync.Mutex
	stopped bool
	closers []func()
}

func (lc *xudpConnLifecycle) addCloser(closer func()) {
	if closer == nil {
		return
	}
	lc.mu.Lock()
	if !lc.stopped {
		lc.closers = append(lc.closers, closer)
		lc.mu.Unlock()
		return
	}
	lc.mu.Unlock()
	closer()
}

func (lc *xudpConnLifecycle) stop() {
	lc.mu.Lock()
	if lc.stopped {
		lc.mu.Unlock()
		return
	}
	lc.stopped = true
	closers := append([]func(){}, lc.closers...)
	lc.closers = nil
	lc.cancel()
	lc.mu.Unlock()

	for _, closer := range closers {
		closer()
	}
}

func NewXUDPProxy(baseProxy *BaseProxy, cfg v1.ProxyConfigurer) Proxy {
	unwrapped, ok := cfg.(*v1.XUDPProxyConfig)
	if !ok {
		return nil
	}
	pxy := &XUDPProxy{
		BaseProxy: baseProxy,
		cfg:       unwrapped,
	}
	pxy.initLifecycle()
	return pxy
}

func (pxy *XUDPProxy) Run() (err error) {
	pxy.initLifecycle()
	pxy.localAddr, err = net.ResolveUDPAddr("udp",
		net.JoinHostPort(pxy.cfg.LocalIP, strconv.Itoa(pxy.cfg.LocalPort)))
	return
}

func (pxy *XUDPProxy) initLifecycle() {
	pxy.lifecycleOnce.Do(func() {
		parent := pxy.ctx
		if parent == nil {
			parent = context.Background()
		}
		pxy.lifecycleCtx, pxy.lifecycleCancel = context.WithCancel(parent)
		pxy.pendingConns = make(map[uint64]net.Conn)
		pxy.activeConns = make(map[uint64]*xudpConnLifecycle)
	})
}

func (pxy *XUDPProxy) Close() {
	pxy.initLifecycle()
	pxy.closeOnce.Do(func() {
		pxy.lifecycleMu.Lock()
		pxy.closed = true
		pxy.lifecycleCancel()
		pending := make([]net.Conn, 0, len(pxy.pendingConns))
		for _, conn := range pxy.pendingConns {
			pending = append(pending, conn)
		}
		active := make([]*xudpConnLifecycle, 0, len(pxy.activeConns))
		for _, lc := range pxy.activeConns {
			active = append(active, lc)
		}
		pxy.lifecycleMu.Unlock()

		for _, conn := range pending {
			_ = conn.Close()
		}
		for _, lc := range active {
			lc.stop()
		}
		pxy.activeWG.Wait()
		pxy.baseCloseOnce.Do(pxy.BaseProxy.Close)
	})
}

func (pxy *XUDPProxy) registerPending(conn net.Conn) (uint64, bool) {
	pxy.initLifecycle()
	pxy.lifecycleMu.Lock()
	defer pxy.lifecycleMu.Unlock()
	if pxy.closed {
		return 0, false
	}
	pxy.nextConnID++
	id := pxy.nextConnID
	pxy.pendingConns[id] = conn
	return id, true
}

func (pxy *XUDPProxy) finishPending(id uint64, conn net.Conn) {
	pxy.lifecycleMu.Lock()
	if pxy.pendingConns[id] == conn {
		delete(pxy.pendingConns, id)
	}
	pxy.lifecycleMu.Unlock()
	_ = conn.Close()
}

// promotePending atomically moves a setup connection into the data-plane
// WaitGroup. Holding lifecycleMu across the closed check, map insertion, and
// WaitGroup.Add prevents Add racing with Close's Wait.
func (pxy *XUDPProxy) promotePending(id uint64, conn net.Conn) (*xudpConnLifecycle, bool) {
	pxy.lifecycleMu.Lock()
	defer pxy.lifecycleMu.Unlock()
	if pxy.pendingConns[id] != conn {
		return nil, false
	}
	delete(pxy.pendingConns, id)
	if pxy.closed {
		return nil, false
	}
	ctx, cancel := context.WithCancel(pxy.lifecycleCtx)
	lc := &xudpConnLifecycle{id: id, ctx: ctx, cancel: cancel}
	pxy.activeWG.Add(1)
	pxy.activeConns[id] = lc
	return lc, true
}

func (pxy *XUDPProxy) finishActive(lc *xudpConnLifecycle) {
	lc.stop()
	pxy.lifecycleMu.Lock()
	if pxy.activeConns[lc.id] == lc {
		delete(pxy.activeConns, lc.id)
	}
	pxy.lifecycleMu.Unlock()
	pxy.activeWG.Done()
}

// InWorkConn receives a work connection from the server. New servers identify
// the connection role explicitly. An empty role is reserved for compatibility
// with older servers and is classified by fully decoding one message.
func (pxy *XUDPProxy) InWorkConn(conn net.Conn, m *msg.StartWorkConn) {
	xl := pxy.xl
	pendingID, ok := pxy.registerPending(conn)
	if !ok {
		_ = conn.Close()
		return
	}
	pending := true
	defer func() {
		if pending {
			pxy.finishPending(pendingID, conn)
		}
	}()

	role, routedConn, err := classifyXUDPWorkConn(conn, m, pxy.clientCfg.Transport.WireProtocol)
	if err != nil {
		xl.Warnf("reject xudp work connection: %v", err)
		return
	}

	if role == msg.XUDPWorkConnRoleP2P {
		xl.Infof("xudp p2p mode work connection")
		pending = pxy.handleP2PWorkConn(pendingID, conn, routedConn, m)
	} else {
		xl.Infof("xudp relay mode work connection")
		lc, promoted := pxy.promotePending(pendingID, conn)
		if !promoted {
			return
		}
		pending = false
		lc.addCloser(func() { _ = conn.Close() })
		defer pxy.finishActive(lc)
		pxy.handleRelayWorkConn(lc, routedConn, m)
	}
}

func classifyXUDPWorkConn(conn net.Conn, m *msg.StartWorkConn, wireProtocol string) (string, net.Conn, error) {
	role := ""
	if m != nil {
		role = m.XUDPRole
	}
	switch role {
	case msg.XUDPWorkConnRoleP2P, msg.XUDPWorkConnRoleRelay:
		return role, conn, nil
	case "":
		return classifyLegacyXUDPWorkConn(conn, wireProtocol)
	default:
		return "", conn, fmt.Errorf("unknown StartWorkConn role %q", role)
	}
}

func classifyLegacyXUDPWorkConn(conn net.Conn, wireProtocol string) (string, net.Conn, error) {
	bufReader := bufio.NewReaderSize(conn, wire.DefaultMaxFramePayloadSize)
	var captured bytes.Buffer
	probe := &bufferedConn{Conn: conn, reader: io.TeeReader(bufReader, &captured)}

	// Old relay connections may not carry data immediately. Bound the legacy
	// probe, then replay every consumed byte before handing the connection off.
	if err := conn.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return "", conn, fmt.Errorf("set legacy xudp probe read deadline: %w", err)
	}
	decoded, err := msg.NewReadWriter(probe, wireProtocol).ReadMsg()
	if clearErr := conn.SetReadDeadline(time.Time{}); clearErr != nil {
		return "", conn, fmt.Errorf("clear legacy xudp probe read deadline: %w", clearErr)
	}

	replay := &bufferedConn{
		Conn:   conn,
		reader: io.MultiReader(bytes.NewReader(captured.Bytes()), bufReader),
	}
	if err != nil {
		return msg.XUDPWorkConnRoleRelay, replay, nil
	}
	natHoleSid, ok := decoded.(*msg.NatHoleSid)
	if ok && natHoleSid.Sid != "" && natHoleSid.Nonce == "xudp" {
		return msg.XUDPWorkConnRoleP2P, replay, nil
	}
	return msg.XUDPWorkConnRoleRelay, replay, nil
}

// handleP2PWorkConn returns whether the caller still owns the pending work
// connection. nathole.Prepare has no context API, so it deliberately runs
// before promotion into the active data-plane WaitGroup. Close can close the
// pending work connection without waiting for Prepare; a late Prepare result
// is rejected by promotePending and its socket is released.
func (pxy *XUDPProxy) handleP2PWorkConn(pendingID uint64, originalConn, conn net.Conn, _ *msg.StartWorkConn) (pending bool) {
	xl := pxy.xl
	pending = true

	// Read NatHoleSid
	workMsgConn := msg.NewConn(conn, msg.NewReadWriter(conn, pxy.clientCfg.Transport.WireProtocol))
	var natHoleSidMsg msg.NatHoleSid
	if err := workMsgConn.ReadMsgInto(&natHoleSidMsg); err != nil {
		xl.Errorf("xudp read natHoleSid error: %v", err)
		return pending
	}

	// Prepare NAT traversal
	var opts nathole.PrepareOptions
	if pxy.cfg.NatTraversal != nil && pxy.cfg.NatTraversal.DisableAssistedAddrs {
		opts.DisableAssistedAddrs = true
	}

	xl.Tracef("xudp nathole prepare start")
	prepare := pxy.prepareNAT
	if prepare == nil {
		prepare = nathole.Prepare
	}
	prepareResult, err := prepare([]string{pxy.clientCfg.NatHoleSTUNServer}, opts)
	if err != nil {
		xl.Warnf("xudp nathole prepare error: %v", err)
		return pending
	}
	lc, promoted := pxy.promotePending(pendingID, originalConn)
	if !promoted {
		_ = prepareResult.ListenConn.Close()
		return pending
	}
	pending = false
	lc.addCloser(func() { _ = originalConn.Close() })
	lc.addCloser(func() { _ = prepareResult.ListenConn.Close() })
	defer pxy.finishActive(lc)

	xl.Infof("xudp nathole prepare success, nat type: %s, behavior: %s, addresses: %v, assistedAddresses: %v",
		prepareResult.NatType, prepareResult.Behavior, prepareResult.Addrs, prepareResult.AssistedAddrs)

	quicIdentity, err := xudptransport.GenerateIdentity()
	if err != nil {
		xl.Warnf("xudp generate quic identity error: %v", err)
		return pending
	}

	// Send NatHoleClient to server and get response
	transactionID := nathole.NewTransactionID()
	natHoleClientMsg := &msg.NatHoleClient{
		TransactionID:   transactionID,
		ProxyName:       naming.AddUserPrefix(pxy.clientCfg.User, pxy.cfg.Name),
		Sid:             natHoleSidMsg.Sid,
		MappedAddrs:     prepareResult.Addrs,
		AssistedAddrs:   prepareResult.AssistedAddrs,
		QUICFingerprint: quicIdentity.Fingerprint(),
	}

	xl.Tracef("xudp nathole exchange info start")
	natHoleRespMsg, err := nathole.ExchangeInfo(lc.ctx, pxy.msgTransporter, transactionID, natHoleClientMsg, 5*time.Second)
	if err != nil {
		xl.Warnf("xudp nathole exchange info error: %v", err)
		return pending
	}

	xl.Infof("xudp get natHoleRespMsg, sid [%s], protocol [%s], candidate address %v, assisted address %v",
		natHoleRespMsg.Sid, natHoleRespMsg.Protocol, natHoleRespMsg.CandidateAddrs, natHoleRespMsg.AssistedAddrs)

	listenConn := prepareResult.ListenConn
	newListenConn, raddr, err := nathole.MakeHole(lc.ctx, listenConn, natHoleRespMsg, []byte(pxy.cfg.Secretkey))
	if err != nil {
		xl.Warnf("xudp make hole error: %v", err)
		_ = pxy.msgTransporter.Send(&msg.NatHoleReport{Sid: natHoleRespMsg.Sid, Success: false})
		return pending
	}
	listenConn = newListenConn
	if listenConn != prepareResult.ListenConn {
		lc.addCloser(func() { _ = listenConn.Close() })
	}
	xl.Infof("xudp nat hole established, sid [%s], remoteAddr [%s]", natHoleRespMsg.Sid, raddr)
	xl.Debugf("xudp transferring UDP socket ownership to QUIC, localAddr [%s]", listenConn.LocalAddr())

	_ = pxy.msgTransporter.Send(&msg.NatHoleReport{Sid: natHoleRespMsg.Sid, Success: true})

	// The NAT hole remains responsible for finding the UDP path. QUIC
	// DATAGRAM is established on top of that path and owns the data-plane
	// security for XUDP.
	pxy.listenByQUICDatagram(lc, listenConn, quicIdentity, natHoleRespMsg.QUICFingerprint)
	return pending
}

func (pxy *XUDPProxy) listenByQUICDatagram(lc *xudpConnLifecycle, listenConn *net.UDPConn, identity *xudptransport.Identity, expectedClientFingerprint string) {
	xl := pxy.xl
	// Listen takes ownership of this socket on success. Keep a defensive
	// cleanup here as well so TLS setup, listener setup, Accept timeout, and
	// peer authentication failures cannot leak the socket returned by MakeHole.
	defer listenConn.Close()

	tlsConfig, err := xudptransport.ServerTLSConfig(identity, expectedClientFingerprint)
	if err != nil {
		xl.Warnf("xudp create quic tls config error: %v", err)
		return
	}
	listener, err := xudptransport.Listen(listenConn, tlsConfig, xudptransport.OptionsFromClientCfg(pxy.clientCfg))
	if err != nil {
		xl.Warnf("xudp create quic listener error: %v", err)
		return
	}
	lc.addCloser(func() { _ = listener.Close() })
	defer func() {
		_ = listener.Close()
		xl.Debugf("xudp p2p QUIC listener closed")
	}()
	xl.Infof("xudp p2p QUIC listener starting, localAddr [%s]", listenConn.LocalAddr())

	acceptCtx, cancel := context.WithTimeout(lc.ctx, 10*time.Second)
	defer cancel()
	xl.Infof("xudp p2p waiting for QUIC connection")
	conn, err := listener.Accept(acceptCtx)
	if err != nil {
		xl.Warnf("xudp accept quic connection error: %v", err)
		return
	}
	xl.Infof("xudp p2p QUIC connection accepted, remoteAddr [%s]", conn.RemoteAddr())
	if err := conn.VerifyPeerFingerprint(expectedClientFingerprint); err != nil {
		_ = conn.Close()
		xl.Warnf("xudp quic peer authentication failed: %v", err)
		return
	}
	lc.addCloser(func() { _ = conn.Close() })

	xl.Infof("xudp p2p QUIC datagram transport ready, remoteAddr [%s]", conn.RemoteAddr())
	pxy.forwardP2PQUICDatagram(lc, conn)
}

// runXUDPWorkers gives one Relay/P2P connection structured concurrency: the
// first worker to finish cancels the connection and closes all registered
// resources, and this function does not return until every worker has joined.
func (pxy *XUDPProxy) runXUDPWorkers(lc *xudpConnLifecycle, workers ...func(context.Context)) {
	var wg sync.WaitGroup
	wg.Add(len(workers))
	for _, worker := range workers {
		worker := worker
		go func() {
			defer wg.Done()
			defer lc.stop()
			worker(lc.ctx)
		}()
	}
	wg.Wait()
}

// forwardP2PQUICDatagram bridges QUIC DATAGRAMs and the local UDP service.
func (pxy *XUDPProxy) forwardP2PQUICDatagram(lc *xudpConnLifecycle, conn xudptransport.DatagramTransport) {
	xl := pxy.xl

	// readCh carries UDP packets from the P2P QUIC connection to the local service.
	// sendCh carries UDP packets from the local service to the P2P QUIC connection.
	readCh := make(chan *msg.UDPPacket, 1024)
	sendCh := make(chan msg.Message, 1024)

	pxy.runXUDPWorkers(lc,
		func(ctx context.Context) {
			for {
				data, err := conn.ReceiveDatagram(ctx)
				if err != nil {
					xl.Debugf("xudp p2p quic receive error: %v", err)
					return
				}
				pkt, err := msg.DecodeUDPPacketBinary(data)
				if err != nil {
					xl.Warnf("xudp decode p2p quic data packet error: %v", err)
					continue
				}
				select {
				case <-ctx.Done():
					return
				case readCh <- pkt:
				}
			}
		},
		func(ctx context.Context) {
			for {
				select {
				case <-ctx.Done():
					return
				case raw, ok := <-sendCh:
					if !ok {
						return
					}
					pkt, ok := raw.(*msg.UDPPacket)
					if !ok {
						continue
					}
					body, err := msg.EncodeUDPPacketBinary(pkt)
					if err != nil {
						xl.Warnf("xudp encode p2p quic data packet error: %v", err)
						continue
					}
					limit := conn.MaxDatagramPayloadSize()
					if err := xudptransport.ValidateDatagramSizeAgainstLimit(len(body), limit); err != nil {
						xl.Warnf("xudp p2p quic datagram too large: %d > %d", len(body), limit)
						continue
					}
					if err := conn.SendDatagram(body); err != nil {
						if stderrors.Is(err, xudptransport.ErrDatagramTooLarge) {
							xl.Warnf("xudp p2p quic datagram too large: %v", err)
							continue
						}
						xl.Warnf("xudp p2p quic write error: %v", err)
						return
					}
				}
			}
		},
		func(ctx context.Context) {
			udp.ManagedForwarder(ctx, pxy.localAddr, readCh, sendCh,
				int(pxy.clientCfg.UDPPacketSize), pxy.cfg.Transport.ProxyProtocolVersion)
		},
	)
}

// handleRelayWorkConn forwards UDP packets through the frps relay
// (identical to SUDP behavior).
func (pxy *XUDPProxy) handleRelayWorkConn(lc *xudpConnLifecycle, conn net.Conn, _ *msg.StartWorkConn) {
	xl := pxy.xl
	xl.Infof("incoming a new work connection for xudp relay proxy, %s", conn.RemoteAddr().String())

	remote, recycleFn, err := pxy.wrapWorkConn(conn, pxy.encryptionKey)
	if err != nil {
		xl.Errorf("wrap work connection: %v", err)
		return
	}
	if recycleFn != nil {
		defer recycleFn()
	}

	workConn := netpkg.WrapReadWriteCloserToConn(remote, conn)
	lc.addCloser(func() { _ = workConn.Close() })
	payloadRW, err := msg.NewUDPPacketReadWriter(workConn, pxy.clientCfg.Transport.WireProtocol, pxy.udpPacketCodec)
	if err != nil {
		xl.Errorf("create UDP packet read writer: %v", err)
		workConn.Close()
		return
	}

	readCh := make(chan *msg.UDPPacket, 1024)
	sendCh := make(chan msg.Message, 1024)

	heartbeatInterval := pxy.heartbeatInterval
	if heartbeatInterval <= 0 {
		heartbeatInterval = 30 * time.Second
	}

	pxy.runXUDPWorkers(lc,
		func(ctx context.Context) {
			for {
				var udpMsg msg.UDPPacket
				if errRet := payloadRW.ReadMsgInto(&udpMsg); errRet != nil {
					xl.Warnf("read from workConn for xudp relay error: %v", errRet)
					return
				}
				select {
				case <-ctx.Done():
					return
				case readCh <- &udpMsg:
				}
			}
		},
		func(ctx context.Context) {
			defer xl.Infof("writer goroutine for xudp relay work connection closed")
			for {
				select {
				case <-ctx.Done():
					return
				case rawMsg, ok := <-sendCh:
					if !ok {
						return
					}
					if errRet := payloadRW.WriteMsg(rawMsg); errRet != nil {
						xl.Errorf("xudp relay work write error: %v", errRet)
						return
					}
				}
			}
		},
		func(ctx context.Context) {
			ticker := time.NewTicker(heartbeatInterval)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					xl.Tracef("heartbeat goroutine for xudp relay work connection closed")
					return
				case <-ticker.C:
					select {
					case <-ctx.Done():
						return
					case sendCh <- &msg.Ping{}:
					}
				}
			}
		},
		func(ctx context.Context) {
			udp.ManagedForwarder(ctx, pxy.localAddr, readCh, sendCh,
				int(pxy.clientCfg.UDPPacketSize), pxy.cfg.Transport.ProxyProtocolVersion)
		},
	)
}
