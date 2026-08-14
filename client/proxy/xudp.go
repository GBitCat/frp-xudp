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
	"context"
	"encoding/binary"
	"net"
	"reflect"
	"strconv"
	"time"

	"github.com/fatedier/golib/errors"

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
	reader *bufio.Reader
}

func (bc *bufferedConn) Read(p []byte) (int, error) {
	return bc.reader.Read(p)
}

type XUDPProxy struct {
	*BaseProxy
	cfg *v1.XUDPProxyConfig

	localAddr *net.UDPAddr
}

func NewXUDPProxy(baseProxy *BaseProxy, cfg v1.ProxyConfigurer) Proxy {
	unwrapped, ok := cfg.(*v1.XUDPProxyConfig)
	if !ok {
		return nil
	}
	return &XUDPProxy{
		BaseProxy: baseProxy,
		cfg:       unwrapped,
	}
}

func (pxy *XUDPProxy) Run() (err error) {
	pxy.localAddr, err = net.ResolveUDPAddr("udp",
		net.JoinHostPort(pxy.cfg.LocalIP, strconv.Itoa(pxy.cfg.LocalPort)))
	return
}

func (pxy *XUDPProxy) Close() {
	pxy.mu.Lock()
	defer pxy.mu.Unlock()
}

// InWorkConn receives a work connection from the server. It peeks at the
// first bytes to decide whether this is a P2P work connection (carrying a
// NatHoleSid message) or a relay work connection (carrying UDP packets).
func (pxy *XUDPProxy) InWorkConn(conn net.Conn, m *msg.StartWorkConn) {
	xl := pxy.xl
	// Note: do NOT close conn here. handleRelayWorkConn starts background
	// goroutines that own the connection and udp.Forwarder returns
	// immediately; closing here would kill the relay tunnel instantly.

	wireProtocol := pxy.clientCfg.Transport.WireProtocol
	bufReader := bufio.NewReaderSize(conn, 65536)

	// Set a read deadline for the peek so relay connections do not hang
	// waiting for NatHoleSid that will never arrive.
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))

	var isP2P bool
	switch wireProtocol {
	case wire.ProtocolV2:
		// V2: need at least 10 bytes (8-byte frame header + 2-byte message type)
		peekBytes, err := bufReader.Peek(10)
		if err == nil && len(peekBytes) >= 10 {
			frameType := binary.BigEndian.Uint16(peekBytes[0:2])
			msgType := binary.BigEndian.Uint16(peekBytes[8:10])
			isP2P = frameType == wire.FrameTypeMessage && msgType == msg.V2TypeNatHoleSid
		}
	default:
		// V1: 1 byte message type, TypeNatHoleSid = '5'
		peekBytes, err := bufReader.Peek(1)
		if err == nil && peekBytes[0] == msg.TypeNatHoleSid {
			isP2P = true
		}
	}

	_ = conn.SetReadDeadline(time.Time{})
	bc := &bufferedConn{Conn: conn, reader: bufReader}

	if isP2P {
		xl.Infof("xudp p2p mode work connection")
		pxy.handleP2PWorkConn(bc, m)
	} else {
		xl.Infof("xudp relay mode work connection")
		pxy.handleRelayWorkConn(bc, m)
	}
}

// handleP2PWorkConn processes a P2P work connection: reads NatHoleSid,
// performs NAT hole punching, and then forwards UDP through the P2P tunnel.
func (pxy *XUDPProxy) handleP2PWorkConn(conn net.Conn, _ *msg.StartWorkConn) {
	xl := pxy.xl

	// Read NatHoleSid
	workMsgConn := msg.NewConn(conn, msg.NewReadWriter(conn, pxy.clientCfg.Transport.WireProtocol))
	var natHoleSidMsg msg.NatHoleSid
	if err := workMsgConn.ReadMsgInto(&natHoleSidMsg); err != nil {
		xl.Errorf("xudp read natHoleSid error: %v", err)
		return
	}

	// Prepare NAT traversal
	var opts nathole.PrepareOptions
	if pxy.cfg.NatTraversal != nil && pxy.cfg.NatTraversal.DisableAssistedAddrs {
		opts.DisableAssistedAddrs = true
	}

	xl.Tracef("xudp nathole prepare start")
	prepareResult, err := nathole.Prepare([]string{pxy.clientCfg.NatHoleSTUNServer}, opts)
	if err != nil {
		xl.Warnf("xudp nathole prepare error: %v", err)
		return
	}

	xl.Infof("xudp nathole prepare success, nat type: %s, behavior: %s, addresses: %v, assistedAddresses: %v",
		prepareResult.NatType, prepareResult.Behavior, prepareResult.Addrs, prepareResult.AssistedAddrs)
	defer prepareResult.ListenConn.Close()

	quicIdentity, err := xudptransport.GenerateIdentity()
	if err != nil {
		xl.Warnf("xudp generate quic identity error: %v", err)
		return
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
	natHoleRespMsg, err := nathole.ExchangeInfo(pxy.ctx, pxy.msgTransporter, transactionID, natHoleClientMsg, 5*time.Second)
	if err != nil {
		xl.Warnf("xudp nathole exchange info error: %v", err)
		return
	}

	xl.Infof("xudp get natHoleRespMsg, sid [%s], protocol [%s], candidate address %v, assisted address %v",
		natHoleRespMsg.Sid, natHoleRespMsg.Protocol, natHoleRespMsg.CandidateAddrs, natHoleRespMsg.AssistedAddrs)

	listenConn := prepareResult.ListenConn
	newListenConn, raddr, err := nathole.MakeHole(pxy.ctx, listenConn, natHoleRespMsg, []byte(pxy.cfg.Secretkey))
	if err != nil {
		listenConn.Close()
		xl.Warnf("xudp make hole error: %v", err)
		_ = pxy.msgTransporter.Send(&msg.NatHoleReport{Sid: natHoleRespMsg.Sid, Success: false})
		return
	}
	listenConn = newListenConn
	xl.Infof("xudp nat hole established, sid [%s], remoteAddr [%s]", natHoleRespMsg.Sid, raddr)

	_ = pxy.msgTransporter.Send(&msg.NatHoleReport{Sid: natHoleRespMsg.Sid, Success: true})

	// The NAT hole remains responsible for finding the UDP path. QUIC
	// DATAGRAM is established on top of that path and owns the data-plane
	// security for XUDP.
	pxy.listenByQUICDatagram(listenConn, quicIdentity, natHoleRespMsg.QUICFingerprint)
}

func (pxy *XUDPProxy) listenByQUICDatagram(listenConn *net.UDPConn, identity *xudptransport.Identity, expectedClientFingerprint string) {
	xl := pxy.xl

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
	defer listener.Close()

	acceptCtx, cancel := context.WithTimeout(pxy.ctx, 10*time.Second)
	defer cancel()
	conn, err := listener.Accept(acceptCtx)
	if err != nil {
		xl.Warnf("xudp accept quic connection error: %v", err)
		return
	}
	if err := conn.VerifyPeerFingerprint(expectedClientFingerprint); err != nil {
		_ = conn.Close()
		xl.Warnf("xudp quic peer authentication failed: %v", err)
		return
	}

	xl.Infof("xudp quic datagram connection established, remoteAddr [%s]", conn.RemoteAddr())
	pxy.forwardP2PQUICDatagram(conn)
}

// forwardP2PQUICDatagram bridges QUIC DATAGRAMs and the local UDP service.
func (pxy *XUDPProxy) forwardP2PQUICDatagram(conn xudptransport.DatagramTransport) {
	xl := pxy.xl

	// readCh carries UDP packets from the P2P QUIC connection to the local service.
	// sendCh carries UDP packets from the local service to the P2P QUIC connection.
	readCh := make(chan *msg.UDPPacket, 1024)
	sendCh := make(chan msg.Message, 1024)

	go udp.Forwarder(pxy.localAddr, readCh, sendCh,
		int(pxy.clientCfg.UDPPacketSize), pxy.cfg.Transport.ProxyProtocolVersion)

	readerDone := make(chan struct{})
	go func() {
		defer close(readerDone)
		defer close(readCh)
		for {
			data, err := conn.ReceiveDatagram(pxy.ctx)
			if err != nil {
				xl.Debugf("xudp p2p quic receive error: %v", err)
				return
			}
			pkt, err := msg.DecodeUDPPacketBinary(data)
			if err != nil {
				xl.Warnf("xudp decode p2p quic data packet error: %v", err)
				continue
			}
			if err := errors.PanicToError(func() {
				readCh <- pkt
			}); err != nil {
				xl.Debugf("xudp p2p quic reader closed")
				return
			}
		}
	}()

	senderDone := make(chan struct{})
	go func() {
		defer close(senderDone)
		for {
			select {
			case <-pxy.ctx.Done():
				return
			case <-readerDone:
				return
			case raw := <-sendCh:
				pkt, ok := raw.(*msg.UDPPacket)
				if !ok {
					continue
				}
				body, err := msg.EncodeUDPPacketBinary(pkt)
				if err != nil {
					xl.Warnf("xudp encode p2p quic data packet error: %v", err)
					continue
				}
				if len(body) > conn.MaxDatagramPayloadSize() {
					xl.Warnf("xudp p2p quic datagram too large: %d > %d", len(body), conn.MaxDatagramPayloadSize())
					continue
				}
				if err := conn.SendDatagram(body); err != nil {
					xl.Warnf("xudp p2p quic write error: %v", err)
					return
				}
			}
		}
	}()

	select {
	case <-pxy.ctx.Done():
	case <-readerDone:
	case <-senderDone:
	}
	_ = conn.Close()
}

// handleRelayWorkConn forwards UDP packets through the frps relay
// (identical to SUDP behavior).
func (pxy *XUDPProxy) handleRelayWorkConn(conn net.Conn, _ *msg.StartWorkConn) {
	xl := pxy.xl
	xl.Infof("incoming a new work connection for xudp relay proxy, %s", conn.RemoteAddr().String())

	remote, _, err := pxy.wrapWorkConn(conn, pxy.encryptionKey)
	if err != nil {
		xl.Errorf("wrap work connection: %v", err)
		return
	}

	workConn := netpkg.WrapReadWriteCloserToConn(remote, conn)
	payloadRW, err := msg.NewUDPPacketReadWriter(workConn, pxy.clientCfg.Transport.WireProtocol, pxy.udpPacketCodec)
	if err != nil {
		xl.Errorf("create UDP packet read writer: %v", err)
		workConn.Close()
		return
	}

	readCh := make(chan *msg.UDPPacket, 1024)
	sendCh := make(chan msg.Message, 1024)

	workConnReaderFn := func(rw msg.ReadWriter, readCh chan *msg.UDPPacket) {
		for {
			var udpMsg msg.UDPPacket
			if errRet := rw.ReadMsgInto(&udpMsg); errRet != nil {
				xl.Warnf("read from workConn for xudp relay error: %v", errRet)
				return
			}
			if errRet := errors.PanicToError(func() {
				readCh <- &udpMsg
			}); errRet != nil {
				xl.Infof("reader goroutine for xudp relay work connection closed")
				return
			}
		}
	}

	workConnSenderFn := func(rw msg.ReadWriter, sendCh chan msg.Message) {
		defer func() {
			xl.Infof("writer goroutine for xudp relay work connection closed")
		}()
		var errRet error
		for rawMsg := range sendCh {
			if errRet = rw.WriteMsg(rawMsg); errRet != nil {
				xl.Errorf("xudp relay work write error: %v", errRet)
				return
			}
		}
	}

	heartbeatFn := func(sendCh chan msg.Message) {
		var errRet error
		for {
			time.Sleep(30 * time.Second)
			if errRet = errors.PanicToError(func() {
				sendCh <- &msg.Ping{}
			}); errRet != nil {
				xl.Tracef("heartbeat goroutine for xudp relay work connection closed")
				break
			}
		}
	}

	go workConnSenderFn(payloadRW, sendCh)
	go workConnReaderFn(payloadRW, readCh)
	go heartbeatFn(sendCh)

	udp.Forwarder(pxy.localAddr, readCh, sendCh,
		int(pxy.clientCfg.UDPPacketSize), pxy.cfg.Transport.ProxyProtocolVersion)
}
