// XUDP extension: visitor-side P2P UDP with relay fallback.

package visitor

import (
	"context"
	"fmt"
	"net"
	"strconv"
	"sync"
	"time"

	"github.com/fatedier/golib/errors"
	"github.com/fatedier/golib/pool"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
	"github.com/fatedier/frp/pkg/naming"
	"github.com/fatedier/frp/pkg/nathole"
	"github.com/fatedier/frp/pkg/proto/udp"
	netpkg "github.com/fatedier/frp/pkg/util/net"
	"github.com/fatedier/frp/pkg/util/util"
	"github.com/fatedier/frp/pkg/util/xlog"
)

const (
	xudpP2PTypeData byte = 0
	xudpP2PTypePing byte = 1
	xudpP2PTypePong byte = 2
)

type XUDPVisitor struct {
	*BaseVisitor

	cfg *v1.XUDPVisitorConfig

	mu       sync.Mutex
	udpConn  *net.UDPConn
	readCh   chan *msg.UDPPacket
	sendCh   chan *msg.UDPPacket
	closeCh  chan struct{}
	cancel   func()
	closed   bool
}

func (sv *XUDPVisitor) Run() (err error) {
	ctx, cancel := context.WithCancel(sv.ctx)
	sv.ctx = ctx
	sv.cancel = cancel

	xl := xlog.FromContextSafe(sv.ctx)

	addr, err := net.ResolveUDPAddr("udp", net.JoinHostPort(sv.cfg.BindAddr, strconv.Itoa(sv.cfg.BindPort)))
	if err != nil {
		return fmt.Errorf("xudp resolve udp addr error: %v", err)
	}

	sv.udpConn, err = net.ListenUDP("udp", addr)
	if err != nil {
		return fmt.Errorf("xudp listen udp port %s error: %v", addr.String(), err)
	}

	sv.readCh = make(chan *msg.UDPPacket, 1024)
	sv.sendCh = make(chan *msg.UDPPacket, 1024)
	sv.closeCh = make(chan struct{})

	xl.Infof("xudp start to work, listen on %s", addr)

	go sv.dispatcher()
	go udp.ForwardUserConn(sv.udpConn, sv.readCh, sv.sendCh, int(sv.clientCfg.UDPPacketSize))
	return
}

// dispatcher is the single consumer of sendCh. It tries P2P first; when P2P
// fails it falls back to relay, which (like SUDP) runs synchronously so the
// relay worker is the sole consumer of sendCh while the tunnel is alive.
func (sv *XUDPVisitor) dispatcher() {
	xl := xlog.FromContextSafe(sv.ctx)

	for {
		var firstPkt *msg.UDPPacket
		select {
		case firstPkt = <-sv.sendCh:
			if firstPkt == nil {
				xl.Infof("xudp visitor closed")
				return
			}
		case <-sv.closeCh:
			return
		}

		// Try P2P first. On success the P2P worker goroutine takes over
		// sendCh; the dispatcher waits for the tunnel to close.
		if done, ok := sv.tryP2P(firstPkt); ok {
			xl.Infof("xudp tunnel established via p2p")
			select {
			case <-done:
				xl.Infof("xudp p2p tunnel closed, waiting for next packet")
			case <-sv.closeCh:
				return
			}
			continue
		}

		xl.Infof("xudp P2P failed, falling back to relay")

		// Relay runs synchronously until the relay connection ends.
		if !sv.tryRelay(firstPkt) {
			xl.Warnf("xudp relay failed, waiting for next packet")
			continue
		}
		xl.Infof("xudp relay worker closed, waiting for next packet")
	}
}

// tryP2P attempts NAT hole punching and starts a P2P forwarding worker.
// On success it returns a channel that is closed when the P2P tunnel ends.
func (sv *XUDPVisitor) tryP2P(firstPkt *msg.UDPPacket) (<-chan struct{}, bool) {
	xl := xlog.FromContextSafe(sv.ctx)

	// PreCheck
	targetProxyName := naming.BuildTargetServerProxyName(sv.clientCfg.User, sv.cfg.ServerUser, sv.cfg.ServerName)
	if err := nathole.PreCheck(sv.ctx, sv.helper.MsgTransporter(), targetProxyName, 5*time.Second); err != nil {
		xl.Warnf("xudp P2P preCheck error: %v", err)
		return nil, false
	}

	// Prepare NAT traversal
	var opts nathole.PrepareOptions
	if sv.cfg.NatTraversal != nil && sv.cfg.NatTraversal.DisableAssistedAddrs {
		opts.DisableAssistedAddrs = true
	}

	prepareResult, err := nathole.Prepare([]string{sv.clientCfg.NatHoleSTUNServer}, opts)
	if err != nil {
		xl.Warnf("xudp P2P prepare error: %v", err)
		return nil, false
	}

	xl.Infof("xudp P2P nathole prepare success, nat type: %s, behavior: %s, addresses: %v",
		prepareResult.NatType, prepareResult.Behavior, prepareResult.Addrs)

	listenConn := prepareResult.ListenConn

	// Send NatHoleVisitor to server
	now := time.Now().Unix()
	transactionID := nathole.NewTransactionID()
	natHoleVisitorMsg := &msg.NatHoleVisitor{
		TransactionID: transactionID,
		ProxyName:     targetProxyName,
		Protocol:      "xudp",
		SignKey:       util.GetAuthKey(sv.cfg.SecretKey, now),
		Timestamp:     now,
		MappedAddrs:   prepareResult.Addrs,
		AssistedAddrs: prepareResult.AssistedAddrs,
	}

	xl.Tracef("xudp P2P exchange info start")
	natHoleRespMsg, err := nathole.ExchangeInfo(sv.ctx, sv.helper.MsgTransporter(), transactionID, natHoleVisitorMsg, 5*time.Second)
	if err != nil {
		listenConn.Close()
		xl.Warnf("xudp P2P exchange info error: %v", err)
		return nil, false
	}

	xl.Infof("xudp P2P get natHoleRespMsg, sid [%s], candidate address %v",
		natHoleRespMsg.Sid, natHoleRespMsg.CandidateAddrs)

	newListenConn, raddr, err := nathole.MakeHole(sv.ctx, listenConn, natHoleRespMsg, []byte(sv.cfg.SecretKey))
	if err != nil {
		listenConn.Close()
		xl.Warnf("xudp P2P make hole error: %v", err)
		return nil, false
	}

	xl.Infof("xudp P2P hole established, sid [%s], remoteAddr [%s]", natHoleRespMsg.Sid, raddr)

	done := make(chan struct{})
	go func() {
		defer close(done)
		sv.p2pWorker(newListenConn, raddr, firstPkt)
	}()
	return done, true
}

// p2pWorker handles the P2P UDP tunnel: reads from the P2P connection and
// puts packets on readCh, and reads from sendCh and encodes packets to send
// through the P2P connection.
func (sv *XUDPVisitor) p2pWorker(p2pConn *net.UDPConn, raddr *net.UDPAddr, firstPkt *msg.UDPPacket) {
	xl := xlog.FromContextSafe(sv.ctx)
	defer p2pConn.Close()

	// Send the first packet that triggered the connection
	if firstPkt != nil {
		if err := sv.sendP2PPacket(p2pConn, raddr, firstPkt); err != nil {
			xl.Warnf("xudp P2P send first packet error: %v", err)
			return
		}
	}

	// P2P reader: read from P2P connection, decode, put on readCh
	readerDone := make(chan struct{})
	go func() {
		defer close(readerDone)
		buf := pool.GetBuf(int(sv.clientCfg.UDPPacketSize) + 1024)
		defer pool.PutBuf(buf)
		for {
			select {
			case <-sv.closeCh:
				return
			default:
			}
			_ = p2pConn.SetReadDeadline(time.Now().Add(60 * time.Second))
			n, _, err := p2pConn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			if n < 1 {
				continue
			}
			switch buf[0] {
			case xudpP2PTypeData:
				pkt, err := msg.DecodeUDPPacketBinary(buf[1:n])
				if err != nil {
					continue
				}
				if err := errors.PanicToError(func() {
					sv.readCh <- pkt
				}); err != nil {
					return
				}
			case xudpP2PTypePong:
				// Heartbeat response, keep connection alive
			}
		}
	}()

	// P2P sender: read from sendCh, encode, write to P2P connection
	senderDone := make(chan struct{})
	go func() {
		defer close(senderDone)
		for {
			var pkt *msg.UDPPacket
			select {
			case pkt = <-sv.sendCh:
				if pkt == nil {
					return
				}
			case <-sv.closeCh:
				return
			case <-readerDone:
				return
			}
			if err := sv.sendP2PPacket(p2pConn, raddr, pkt); err != nil {
				return
			}
		}
	}()

	// Heartbeat ticker
	ticker := time.NewTicker(20 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-sv.closeCh:
			return
		case <-readerDone:
			return
		case <-senderDone:
			return
		case <-ticker.C:
			if _, err := p2pConn.WriteToUDP([]byte{xudpP2PTypePing}, raddr); err != nil {
				return
			}
		}
	}
}

func (sv *XUDPVisitor) sendP2PPacket(p2pConn *net.UDPConn, raddr *net.UDPAddr, pkt *msg.UDPPacket) error {
	body, err := msg.EncodeUDPPacketBinary(pkt)
	if err != nil {
		return err
	}
	datagram := make([]byte, 1+len(body))
	datagram[0] = xudpP2PTypeData
	copy(datagram[1:], body)
	_, err = p2pConn.WriteToUDP(datagram, raddr)
	return err
}

// tryRelay establishes a relay connection through frps (like SUDP) and runs
// the relay worker synchronously until the connection ends.
func (sv *XUDPVisitor) tryRelay(firstPkt *msg.UDPPacket) bool {
	xl := xlog.FromContextSafe(sv.ctx)
	xl.Infof("xudp relay: dialing relay visitor conn")

	rawConn, err := sv.dialRawVisitorConn(sv.cfg.GetBaseConfig())
	if err != nil {
		xl.Warnf("xudp relay dial error: %v", err)
		return false
	}
	xl.Infof("xudp relay: relay visitor conn established %s", rawConn.RemoteAddr().String())

	rwc, recycleFn, err := wrapVisitorConn(rawConn, sv.cfg.GetBaseConfig())
	if err != nil {
		rawConn.Close()
		xl.Warnf("xudp relay wrap error: %v", err)
		return false
	}
	defer recycleFn()

	workConn := netpkg.WrapReadWriteCloserToConn(rwc, rawConn)
	payloadRW, err := msg.NewUDPPacketReadWriter(workConn, sv.clientCfg.Transport.WireProtocol, udpPacketCodecFromHelper(sv.helper))
	if err != nil {
		rawConn.Close()
		xl.Warnf("xudp relay create packet reader error: %v", err)
		return false
	}

	payloadConn := msg.NewConn(workConn, payloadRW)
	sv.relayWorker(payloadConn, firstPkt)
	return true
}

// relayWorker handles the relay tunnel: reads from the relay work conn and
// puts packets on readCh, and reads from sendCh and sends packets through
// the relay work conn.
func (sv *XUDPVisitor) relayWorker(payloadConn *msg.Conn, firstPkt *msg.UDPPacket) {
	xl := xlog.FromContextSafe(sv.ctx)
	defer func() {
		payloadConn.Close()
		xl.Infof("xudp relay worker closed")
	}()

	closeCh := make(chan struct{})

	// Relay reader: read from relay work conn, put on readCh
	readerDone := make(chan struct{})
	go func() {
		defer close(readerDone)
		for {
			_ = payloadConn.SetReadDeadline(time.Now().Add(60 * time.Second))
			rawMsg, err := payloadConn.ReadMsg()
			if err != nil {
				xl.Warnf("xudp relay reader error: %v", err)
				return
			}
			_ = payloadConn.SetReadDeadline(time.Time{})
			switch m := rawMsg.(type) {
			case *msg.Ping:
				continue
			case *msg.UDPPacket:
				if err := errors.PanicToError(func() {
					sv.readCh <- m
				}); err != nil {
					return
				}
			}
		}
	}()

	// Relay sender: read from sendCh, write to relay work conn
	// Send first packet first
	senderDone := make(chan struct{})
	go func() {
		defer close(senderDone)
		if firstPkt != nil {
			xl.Infof("xudp relay: sender writing first packet, len %d", len(firstPkt.Content))
			if err := payloadConn.WriteMsg(firstPkt); err != nil {
				xl.Warnf("xudp relay: sender write first packet error: %v", err)
				return
			}
			xl.Infof("xudp relay: first packet written")
		}
		for {
			var pkt *msg.UDPPacket
			select {
			case pkt = <-sv.sendCh:
				if pkt == nil {
					return
				}
			case <-readerDone:
				return
			case <-closeCh:
				return
			}
			if err := payloadConn.WriteMsg(pkt); err != nil {
				xl.Warnf("xudp relay: sender write error: %v", err)
				return
			}
		}
	}()

	<-readerDone
	close(closeCh)
	<-senderDone
}

func (sv *XUDPVisitor) Close() {
	xl := xlog.FromContextSafe(sv.ctx)
	xl.Warnf("xudp visitor Close() called")

	sv.mu.Lock()
	defer sv.mu.Unlock()

	if sv.closed {
		return
	}
	sv.closed = true

	if sv.cancel != nil {
		sv.cancel()
	}
	sv.BaseVisitor.Close()
	if sv.udpConn != nil {
		sv.udpConn.Close()
	}
	close(sv.closeCh)
	close(sv.readCh)
	close(sv.sendCh)
}
