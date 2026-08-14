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

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
	"github.com/fatedier/frp/pkg/naming"
	"github.com/fatedier/frp/pkg/nathole"
	"github.com/fatedier/frp/pkg/proto/udp"
	netpkg "github.com/fatedier/frp/pkg/util/net"
	"github.com/fatedier/frp/pkg/util/util"
	"github.com/fatedier/frp/pkg/util/xlog"
	xudpstate "github.com/fatedier/frp/pkg/xudp/state"
	xudptransport "github.com/fatedier/frp/pkg/xudp/transport"
)

type XUDPVisitor struct {
	*BaseVisitor

	cfg *v1.XUDPVisitorConfig

	mu      sync.Mutex
	state   *xudpstate.Machine
	udpConn *net.UDPConn
	readCh  chan *msg.UDPPacket
	sendCh  chan *msg.UDPPacket
	closeCh chan struct{}
	cancel  func()
	closed  bool
}

type xudpActiveTransport interface {
	SendPacket(*msg.UDPPacket) error
	ReceivePacket(context.Context) (*msg.UDPPacket, error)
	Close() error
}

type p2pActiveTransport struct {
	conn xudptransport.DatagramTransport
}

func (t *p2pActiveTransport) SendPacket(pkt *msg.UDPPacket) error {
	body, err := msg.EncodeUDPPacketBinary(pkt)
	if err != nil {
		return err
	}
	if len(body) > t.conn.MaxDatagramPayloadSize() {
		return fmt.Errorf("xudp datagram size %d exceeds limit %d", len(body), t.conn.MaxDatagramPayloadSize())
	}
	return t.conn.SendDatagram(body)
}

func (t *p2pActiveTransport) ReceivePacket(ctx context.Context) (*msg.UDPPacket, error) {
	data, err := t.conn.ReceiveDatagram(ctx)
	if err != nil {
		return nil, err
	}
	return msg.DecodeUDPPacketBinary(data)
}

func (t *p2pActiveTransport) Close() error {
	return t.conn.Close()
}

type relayActiveTransport struct {
	conn *msg.Conn
}

func (t *relayActiveTransport) SendPacket(pkt *msg.UDPPacket) error {
	return t.conn.WriteMsg(pkt)
}

func (t *relayActiveTransport) ReceivePacket(_ context.Context) (*msg.UDPPacket, error) {
	for {
		_ = t.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		rawMsg, err := t.conn.ReadMsg()
		_ = t.conn.SetReadDeadline(time.Time{})
		if err != nil {
			return nil, err
		}
		switch m := rawMsg.(type) {
		case *msg.Ping:
			continue
		case *msg.UDPPacket:
			return m, nil
		}
	}
}

func (t *relayActiveTransport) Close() error {
	return t.conn.Close()
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
	sv.state = xudpstate.NewMachine()

	xl.Infof("xudp start to work, listen on %s", addr)

	go sv.dispatcher()
	go udp.ForwardUserConn(sv.udpConn, sv.readCh, sv.sendCh, int(sv.clientCfg.UDPPacketSize))
	return
}

// dispatcher is the single consumer of sendCh. It starts a persistent XUDP
// session after the first application datagram and keeps P2P/relay transport
// switching inside that session.
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

		sv.runSession(firstPkt)
	}
}

func (sv *XUDPVisitor) runSession(firstPkt *msg.UDPPacket) {
	xl := xlog.FromContextSafe(sv.ctx)
	generation := sv.state.BeginSession()
	pendingPacket := firstPkt
	backoff := time.Second

	for {
		select {
		case <-sv.closeCh:
			return
		default:
		}

		if conn, epoch, ok := sv.dialP2P(generation); ok {
			xl.Infof("xudp tunnel established via p2p")
			sv.runActiveTransport(&p2pActiveTransport{conn: conn}, generation, epoch, pendingPacket, nil)
			pendingPacket = nil
		} else {
			xl.Infof("xudp P2P failed, falling back to relay")
		}

		// P2P ended or failed. Relay is the fallback and is also responsible
		// for periodically probing P2P recovery while it remains active.
		if sv.runRelayWithP2PRecovery(generation, pendingPacket) {
			pendingPacket = nil
			continue
		}

		select {
		case <-sv.closeCh:
			return
		case <-time.After(backoff):
		}
		if backoff < 30*time.Second {
			backoff *= 2
		}
	}
}

func (sv *XUDPVisitor) dialP2P(generation uint64) (xudptransport.DatagramTransport, uint64, bool) {
	xl := xlog.FromContextSafe(sv.ctx)

	sv.state.SetPhase(xudpstate.PhaseNATHolePrepare)

	targetProxyName := naming.BuildTargetServerProxyName(sv.clientCfg.User, sv.cfg.ServerUser, sv.cfg.ServerName)
	if err := nathole.PreCheck(sv.ctx, sv.helper.MsgTransporter(), targetProxyName, 5*time.Second); err != nil {
		xl.Warnf("xudp P2P preCheck error: %v", err)
		return nil, 0, false
	}

	sv.state.SetPhase(xudpstate.PhasePunching)

	var opts nathole.PrepareOptions
	if sv.cfg.NatTraversal != nil && sv.cfg.NatTraversal.DisableAssistedAddrs {
		opts.DisableAssistedAddrs = true
	}

	prepareResult, err := nathole.Prepare([]string{sv.clientCfg.NatHoleSTUNServer}, opts)
	if err != nil {
		xl.Warnf("xudp P2P prepare error: %v", err)
		return nil, 0, false
	}

	xl.Infof("xudp P2P nathole prepare success, nat type: %s, behavior: %s, addresses: %v",
		prepareResult.NatType, prepareResult.Behavior, prepareResult.Addrs)

	listenConn := prepareResult.ListenConn
	quicIdentity, err := xudptransport.GenerateIdentity()
	if err != nil {
		listenConn.Close()
		xl.Warnf("xudp P2P generate quic identity error: %v", err)
		return nil, 0, false
	}

	now := time.Now().Unix()
	transactionID := nathole.NewTransactionID()
	natHoleVisitorMsg := &msg.NatHoleVisitor{
		TransactionID:   transactionID,
		ProxyName:       targetProxyName,
		Protocol:        "xudp",
		SignKey:         util.GetAuthKey(sv.cfg.SecretKey, now),
		Timestamp:       now,
		MappedAddrs:     prepareResult.Addrs,
		AssistedAddrs:   prepareResult.AssistedAddrs,
		QUICFingerprint: quicIdentity.Fingerprint(),
	}

	xl.Tracef("xudp P2P exchange info start")
	natHoleRespMsg, err := nathole.ExchangeInfo(sv.ctx, sv.helper.MsgTransporter(), transactionID, natHoleVisitorMsg, 5*time.Second)
	if err != nil {
		listenConn.Close()
		xl.Warnf("xudp P2P exchange info error: %v", err)
		return nil, 0, false
	}

	xl.Infof("xudp P2P get natHoleRespMsg, sid [%s], candidate address %v",
		natHoleRespMsg.Sid, natHoleRespMsg.CandidateAddrs)

	newListenConn, raddr, err := nathole.MakeHole(sv.ctx, listenConn, natHoleRespMsg, []byte(sv.cfg.SecretKey))
	if err != nil {
		listenConn.Close()
		xl.Warnf("xudp P2P make hole error: %v", err)
		return nil, 0, false
	}

	xl.Infof("xudp P2P hole established, sid [%s], remoteAddr [%s]", natHoleRespMsg.Sid, raddr)

	sv.state.SetPhase(xudpstate.PhaseQUICHandshake)

	tlsConfig, err := xudptransport.ClientTLSConfig(quicIdentity, natHoleRespMsg.QUICFingerprint)
	if err != nil {
		newListenConn.Close()
		xl.Warnf("xudp P2P create quic tls config error: %v", err)
		return nil, 0, false
	}

	quicOpts := xudptransport.OptionsFromClientCfg(sv.clientCfg)
	dialCtx, cancel := context.WithTimeout(sv.ctx, 10*time.Second)
	conn, err := xudptransport.Dial(dialCtx, newListenConn, raddr, tlsConfig, quicOpts)
	cancel()
	if err != nil {
		newListenConn.Close()
		xl.Warnf("xudp P2P dial quic datagram error: %v", err)
		return nil, 0, false
	}

	xl.Infof("xudp P2P quic datagram connection established, localAddr [%s], remoteAddr [%s]", conn.LocalAddr(), conn.RemoteAddr())
	_, epoch := sv.state.BeginTransport(xudpstate.PhaseP2PReady)
	return conn, epoch, true
}

func (sv *XUDPVisitor) dialRelay(generation uint64) (*msg.Conn, uint64, bool) {
	xl := xlog.FromContextSafe(sv.ctx)
	xl.Infof("xudp relay: dialing relay visitor conn")

	sv.state.SetPhase(xudpstate.PhaseRelayConnect)

	rawConn, err := sv.dialRawVisitorConn(sv.cfg.GetBaseConfig())
	if err != nil {
		xl.Warnf("xudp relay dial error: %v", err)
		return nil, 0, false
	}
	xl.Infof("xudp relay: relay visitor conn established %s", rawConn.RemoteAddr().String())

	rwc, recycleFn, err := wrapVisitorConn(rawConn, sv.cfg.GetBaseConfig())
	if err != nil {
		rawConn.Close()
		xl.Warnf("xudp relay wrap error: %v", err)
		return nil, 0, false
	}
	defer recycleFn()

	workConn := netpkg.WrapReadWriteCloserToConn(rwc, rawConn)
	payloadRW, err := msg.NewUDPPacketReadWriter(workConn, sv.clientCfg.Transport.WireProtocol, udpPacketCodecFromHelper(sv.helper))
	if err != nil {
		rawConn.Close()
		xl.Warnf("xudp relay create packet reader error: %v", err)
		return nil, 0, false
	}

	payloadConn := msg.NewConn(workConn, payloadRW)
	_, epoch := sv.state.BeginTransport(xudpstate.PhaseRelayReady)
	return payloadConn, epoch, true
}

func (sv *XUDPVisitor) runActiveTransport(
	transport xudpActiveTransport,
	generation, epoch uint64,
	firstPkt *msg.UDPPacket,
	cancel <-chan struct{},
) {
	xl := xlog.FromContextSafe(sv.ctx)
	defer transport.Close()

	if firstPkt != nil {
		if !sv.state.IsCurrent(generation, epoch) {
			return
		}
		if err := transport.SendPacket(firstPkt); err != nil {
			xl.Warnf("xudp active transport send first packet error: %v", err)
			return
		}
	}

	readerDone := make(chan struct{})
	go func() {
		defer close(readerDone)
		for {
			if !sv.state.IsCurrent(generation, epoch) {
				return
			}
			pkt, err := transport.ReceivePacket(sv.ctx)
			if err != nil {
				return
			}
			if err := errors.PanicToError(func() {
				sv.readCh <- pkt
			}); err != nil {
				return
			}
		}
	}()

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
			case <-cancel:
				return
			case <-readerDone:
				return
			case <-sv.closeCh:
				return
			}
			if !sv.state.IsCurrent(generation, epoch) {
				return
			}
			if err := transport.SendPacket(pkt); err != nil {
				return
			}
		}
	}()

	select {
	case <-cancel:
	case <-sv.closeCh:
	case <-readerDone:
	case <-senderDone:
	}
}

func (sv *XUDPVisitor) runRelayWithP2PRecovery(generation uint64, firstPkt *msg.UDPPacket) bool {
	xl := xlog.FromContextSafe(sv.ctx)

	relayConn, relayEpoch, ok := sv.dialRelay(generation)
	if !ok {
		xl.Warnf("xudp relay failed")
		return false
	}

	relayCancel := make(chan struct{})
	relayDone := make(chan struct{})
	go func() {
		defer close(relayDone)
		sv.runActiveTransport(&relayActiveTransport{conn: relayConn}, generation, relayEpoch, firstPkt, relayCancel)
	}()

	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-sv.closeCh:
			close(relayCancel)
			return false
		case <-relayDone:
			sv.state.SetPhase(xudpstate.PhaseClosed)
			return false
		case <-ticker.C:
			conn, p2pEpoch, ok := sv.dialP2P(generation)
			if !ok {
				continue
			}

			xl.Infof("xudp relay recovered P2P path")
			close(relayCancel)
			<-relayDone
			sv.runActiveTransport(&p2pActiveTransport{conn: conn}, generation, p2pEpoch, nil, nil)
			return true
		}
	}
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
