// XUDP extension: visitor-side P2P UDP with relay fallback.

package visitor

import (
	"context"
	stderrors "errors"
	"fmt"
	"io"
	"math/rand"
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

	mu            sync.Mutex
	state         *xudpstate.Machine
	udpConn       *net.UDPConn
	readCh        chan *msg.UDPPacket
	sendCh        chan *msg.UDPPacket
	closeCh       chan struct{}
	cancel        func()
	closed        bool
	runOnce       bool
	workers       sync.WaitGroup
	closeDone     chan struct{}
	activeClosers map[uint64]func()
	nextActiveID  uint64
	prepareNAT    func([]string, nathole.PrepareOptions) (*nathole.PrepareResult, error)

	// These hooks keep recovery orchestration testable without changing the
	// production dial implementations. A nil hook uses the real dialer.
	p2PDialer      func(uint64) (xudptransport.DatagramTransport, bool)
	relayDialer    func(uint64) (*msg.Conn, uint64, bool)
	recoveryWait   func(time.Duration) <-chan time.Time
	recoveryJitter func(time.Duration) time.Duration
	// recoveryJitterDisabled makes the schedule deterministic for tests and
	// controlled experiments while keeping bounded jitter enabled by default.
	recoveryJitterDisabled bool
}

var recoveryBackoff = [...]time.Duration{time.Second, 2 * time.Second, 5 * time.Second, 10 * time.Second, 30 * time.Second}

func (sv *XUDPVisitor) nextRecoveryDelay(attempt int) time.Duration {
	if attempt >= len(recoveryBackoff) {
		attempt = len(recoveryBackoff) - 1
	}
	base := recoveryBackoff[attempt]
	if sv.recoveryJitterDisabled {
		return base
	}
	if sv.recoveryJitter != nil {
		return boundRecoveryDelay(base, sv.recoveryJitter(base))
	}
	// Keep the probe delay within +/-20% of the bounded exponential schedule.
	jitter := base / 5
	return base - jitter + time.Duration(rand.Int63n(int64(2*jitter)+1))
}

func boundRecoveryDelay(base, delay time.Duration) time.Duration {
	jitter := base / 5
	minDelay := base - jitter
	maxDelay := base + jitter
	if delay < minDelay {
		return minDelay
	}
	if delay > maxDelay {
		return maxDelay
	}
	return delay
}

type xudpActiveTransport interface {
	SendPacket(*msg.UDPPacket) error
	ReceivePacket(context.Context) (*msg.UDPPacket, error)
	Close() error
}

type activeTransportResult struct {
	// pendingPacket is the earliest packet removed from the session FIFO that
	// was not successfully sent. The caller must hand it directly to the next
	// transport before that transport starts consuming sendCh.
	pendingPacket *msg.UDPPacket
}

type xudpPrepareResult struct {
	result *nathole.PrepareResult
	err    error
}

// xudpPrepareRequest owns the result of nathole.Prepare, whose API has no
// context. The call itself is intentionally not part of the visitor worker
// group: Close must not wait for an unbounded STUN operation. Once canceled,
// any late ListenConn is closed by the producer before it returns.
type xudpPrepareRequest struct {
	resultCh chan xudpPrepareResult

	mu       sync.Mutex
	canceled bool
}

func newXUDPPrepareRequest(
	prepare func([]string, nathole.PrepareOptions) (*nathole.PrepareResult, error),
	servers []string,
	opts nathole.PrepareOptions,
) *xudpPrepareRequest {
	r := &xudpPrepareRequest{resultCh: make(chan xudpPrepareResult, 1)}
	go func() {
		result, err := prepare(servers, opts)
		item := xudpPrepareResult{result: result, err: err}

		r.mu.Lock()
		if r.canceled {
			r.mu.Unlock()
			item.recycle()
			return
		}
		select {
		case r.resultCh <- item:
			r.mu.Unlock()
		default:
			r.mu.Unlock()
			item.recycle()
		}
	}()
	return r
}

func (r xudpPrepareResult) recycle() {
	if r.result != nil && r.result.ListenConn != nil {
		_ = r.result.ListenConn.Close()
	}
}

func (r *xudpPrepareRequest) wait(closeCh <-chan struct{}) (xudpPrepareResult, bool) {
	select {
	case result := <-r.resultCh:
		select {
		case <-closeCh:
			r.cancel()
			result.recycle()
			return xudpPrepareResult{}, false
		default:
			return result, true
		}
	case <-closeCh:
		r.cancel()
		return xudpPrepareResult{}, false
	}
}

func (r *xudpPrepareRequest) cancel() {
	r.mu.Lock()
	r.canceled = true
	var late *xudpPrepareResult
	select {
	case result := <-r.resultCh:
		late = &result
	default:
	}
	r.mu.Unlock()
	if late != nil {
		late.recycle()
	}
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
		return fmt.Errorf("%w: size %d exceeds limit %d", xudptransport.ErrDatagramTooLarge, len(body), t.conn.MaxDatagramPayloadSize())
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

// xudpRelayReadWriteCloser keeps pooled compression resources owned by the
// relay connection until the connection is actually closed. Returning these
// objects while msg.Conn is still live lets another connection reset and reuse
// the same reader or writer.
type xudpRelayReadWriteCloser struct {
	io.ReadWriteCloser
	recycleFn func()

	closeOnce sync.Once
	closeErr  error
}

func (c *xudpRelayReadWriteCloser) Close() error {
	c.closeOnce.Do(func() {
		c.closeErr = c.ReadWriteCloser.Close()
		if c.recycleFn != nil {
			c.recycleFn()
		}
	})
	return c.closeErr
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
	sv.mu.Lock()
	if sv.closed {
		sv.mu.Unlock()
		return fmt.Errorf("xudp visitor is closed")
	}
	if sv.runOnce {
		sv.mu.Unlock()
		return fmt.Errorf("xudp visitor Run called more than once")
	}
	sv.runOnce = true

	ctx, cancel := context.WithCancel(sv.ctx)
	sv.ctx = ctx
	sv.cancel = cancel

	xl := xlog.FromContextSafe(sv.ctx)

	addr, err := net.ResolveUDPAddr("udp", net.JoinHostPort(sv.cfg.BindAddr, strconv.Itoa(sv.cfg.BindPort)))
	if err != nil {
		sv.mu.Unlock()
		return fmt.Errorf("xudp resolve udp addr error: %v", err)
	}

	sv.udpConn, err = net.ListenUDP("udp", addr)
	if err != nil {
		sv.mu.Unlock()
		return fmt.Errorf("xudp listen udp port %s error: %v", addr.String(), err)
	}

	sv.readCh = make(chan *msg.UDPPacket, 1024)
	sv.sendCh = make(chan *msg.UDPPacket, 1024)
	sv.closeCh = make(chan struct{})
	sv.state = xudpstate.NewMachine()
	sv.closeDone = make(chan struct{})
	sv.activeClosers = make(map[uint64]func())
	sv.workers.Add(2)

	xl.Infof("xudp start to work, listen on %s", addr)

	go func() {
		defer sv.workers.Done()
		sv.dispatcher()
	}()
	go func() {
		defer sv.workers.Done()
		udp.ForwardUserConn(sv.udpConn, sv.readCh, sv.sendCh, int(sv.clientCfg.UDPPacketSize))
	}()
	sv.mu.Unlock()
	return
}

// registerActiveCloser makes Close able to wake a transport even when the
// transport is blocked outside the visitor context. Registration is serialized
// with the closed transition, so a transport can never escape after Close.
func (sv *XUDPVisitor) registerActiveCloser(closer func()) func() {
	if closer == nil {
		return func() {}
	}
	sv.mu.Lock()
	if sv.closed {
		sv.mu.Unlock()
		closer()
		return nil
	}
	if sv.activeClosers == nil {
		// Direct runActiveTransport tests do not start the visitor lifecycle.
		sv.mu.Unlock()
		return func() {}
	}
	sv.nextActiveID++
	id := sv.nextActiveID
	sv.activeClosers[id] = closer
	sv.mu.Unlock()
	return func() {
		sv.mu.Lock()
		delete(sv.activeClosers, id)
		sv.mu.Unlock()
	}
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

		if conn, ok := sv.dialP2PForGeneration(generation); ok {
			epoch, activated := sv.state.BeginTransport(generation, xudpstate.PhaseP2PReady)
			if !activated {
				_ = conn.Close()
				return
			}
			xl.Infof("xudp tunnel established via p2p")
			result := sv.runActiveTransport(&p2pActiveTransport{conn: conn}, generation, epoch, pendingPacket, nil)
			pendingPacket = result.pendingPacket
		} else {
			xl.Infof("xudp P2P failed, falling back to relay")
		}
		select {
		case <-sv.closeCh:
			return
		default:
		}

		// P2P ended or failed. Relay is the fallback and is also responsible
		// for periodically probing P2P recovery while it remains active.
		recovered, nextPending := sv.runRelayWithP2PRecovery(generation, pendingPacket)
		pendingPacket = nextPending
		if recovered {
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

func (sv *XUDPVisitor) dialP2P(generation uint64) (xudptransport.DatagramTransport, bool) {
	xl := xlog.FromContextSafe(sv.ctx)
	phase, _, _ := sv.state.Snapshot()
	setPhase := func(next xudpstate.Phase) bool {
		if phase == xudpstate.PhaseRecovering {
			return sv.state.SetPhaseForGeneration(generation, xudpstate.PhaseRecovering)
		}
		return sv.state.SetPhaseForGeneration(generation, next)
	}

	if !setPhase(xudpstate.PhaseNATHolePrepare) {
		return nil, false
	}

	targetProxyName := naming.BuildTargetServerProxyName(sv.clientCfg.User, sv.cfg.ServerUser, sv.cfg.ServerName)
	if err := nathole.PreCheck(sv.ctx, sv.helper.MsgTransporter(), targetProxyName, 5*time.Second); err != nil {
		xl.Warnf("xudp P2P preCheck error: %v", err)
		return nil, false
	}

	if !setPhase(xudpstate.PhasePunching) {
		return nil, false
	}

	var opts nathole.PrepareOptions
	if sv.cfg.NatTraversal != nil && sv.cfg.NatTraversal.DisableAssistedAddrs {
		opts.DisableAssistedAddrs = true
	}

	prepare := sv.prepareNAT
	if prepare == nil {
		prepare = nathole.Prepare
	}
	prepareRequest := newXUDPPrepareRequest(
		prepare,
		[]string{sv.clientCfg.NatHoleSTUNServer},
		opts,
	)
	prepareResultItem, ok := prepareRequest.wait(sv.closeCh)
	if !ok {
		return nil, false
	}
	prepareResult, err := prepareResultItem.result, prepareResultItem.err
	if err != nil {
		prepareResultItem.recycle()
		xl.Warnf("xudp P2P prepare error: %v", err)
		return nil, false
	}
	if prepareResult == nil || prepareResult.ListenConn == nil {
		xl.Warnf("xudp P2P prepare returned no listen connection")
		prepareResultItem.recycle()
		return nil, false
	}

	xl.Infof("xudp P2P nathole prepare success, nat type: %s, behavior: %s, addresses: %v",
		prepareResult.NatType, prepareResult.Behavior, prepareResult.Addrs)

	listenConn := prepareResult.ListenConn
	quicIdentity, err := xudptransport.GenerateIdentity()
	if err != nil {
		listenConn.Close()
		xl.Warnf("xudp P2P generate quic identity error: %v", err)
		return nil, false
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
	// The socket remains caller-owned until Dial succeeds. Dial closes it on
	// handshake failure; the defensive defer covers every earlier return and
	// also makes ownership explicit at this call site.
	ownsListenConn := true
	defer func() {
		if ownsListenConn {
			_ = newListenConn.Close()
		}
	}()

	if !setPhase(xudpstate.PhaseQUICHandshake) {
		newListenConn.Close()
		return nil, false
	}

	tlsConfig, err := xudptransport.ClientTLSConfig(quicIdentity, natHoleRespMsg.QUICFingerprint)
	if err != nil {
		newListenConn.Close()
		xl.Warnf("xudp P2P create quic tls config error: %v", err)
		return nil, false
	}

	quicOpts := xudptransport.OptionsFromClientCfg(sv.clientCfg)
	dialCtx, cancel := context.WithTimeout(sv.ctx, 10*time.Second)
	conn, err := xudptransport.Dial(dialCtx, newListenConn, raddr, tlsConfig, quicOpts)
	cancel()
	if err != nil {
		newListenConn.Close()
		xl.Warnf("xudp P2P dial quic datagram error: %v", err)
		return nil, false
	}
	ownsListenConn = false
	if err := conn.VerifyPeerFingerprint(natHoleRespMsg.QUICFingerprint); err != nil {
		_ = conn.Close()
		xl.Warnf("xudp P2P quic peer authentication failed: %v", err)
		return nil, false
	}

	xl.Infof("xudp P2P quic datagram connection established, localAddr [%s], remoteAddr [%s]", conn.LocalAddr(), conn.RemoteAddr())
	quicState := conn.ConnectionState()
	xl.Infof("xudp P2P quic connection state: version [%s], datagrams remote [%t]",
		quicState.Version, quicState.SupportsDatagrams.Remote)
	// A successful dial is only a candidate. The caller activates it after the
	// current data-plane sender has stopped, so two transports can never consume
	// the shared send channel under different epochs.
	return conn, true
}

func (sv *XUDPVisitor) dialRelay(generation uint64) (*msg.Conn, uint64, bool) {
	xl := xlog.FromContextSafe(sv.ctx)
	xl.Infof("xudp relay: dialing relay visitor conn")

	if !sv.state.SetPhaseForGeneration(generation, xudpstate.PhaseRelayConnect) {
		return nil, 0, false
	}

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

	relayRWC := &xudpRelayReadWriteCloser{
		ReadWriteCloser: rwc,
		recycleFn:       recycleFn,
	}
	workConn := netpkg.WrapReadWriteCloserToConn(relayRWC, rawConn)
	payloadRW, err := msg.NewUDPPacketReadWriter(workConn, sv.clientCfg.Transport.WireProtocol, udpPacketCodecFromHelper(sv.helper))
	if err != nil {
		_ = workConn.Close()
		xl.Warnf("xudp relay create packet reader error: %v", err)
		return nil, 0, false
	}

	payloadConn := msg.NewConn(workConn, payloadRW)
	epoch, ok := sv.state.BeginTransport(generation, xudpstate.PhaseRelayReady)
	if !ok {
		_ = payloadConn.Close()
		return nil, 0, false
	}
	return payloadConn, epoch, true
}

func (sv *XUDPVisitor) dialP2PForGeneration(generation uint64) (xudptransport.DatagramTransport, bool) {
	if sv.p2PDialer != nil {
		return sv.p2PDialer(generation)
	}
	return sv.dialP2P(generation)
}

func (sv *XUDPVisitor) dialRelayForGeneration(generation uint64) (*msg.Conn, uint64, bool) {
	if sv.relayDialer != nil {
		return sv.relayDialer(generation)
	}
	return sv.dialRelay(generation)
}

func (sv *XUDPVisitor) runActiveTransport(
	transport xudpActiveTransport,
	generation, epoch uint64,
	firstPkt *msg.UDPPacket,
	cancel <-chan struct{},
) activeTransportResult {
	xl := xlog.FromContextSafe(sv.ctx)
	result := activeTransportResult{pendingPacket: firstPkt}
	transportCtx, stopTransport := context.WithCancel(sv.ctx)
	defer stopTransport()

	var closeOnce sync.Once
	closeTransport := func() {
		closeOnce.Do(func() {
			stopTransport()
			_ = transport.Close()
		})
	}
	unregister := sv.registerActiveCloser(closeTransport)
	if unregister == nil {
		return result
	}
	defer unregister()
	controlDone := make(chan struct{})
	defer close(controlDone)
	go func() {
		select {
		case <-cancel:
			closeTransport()
		case <-transportCtx.Done():
			closeTransport()
		case <-controlDone:
		}
	}()

	if firstPkt != nil {
		if !sv.state.IsCurrent(generation, epoch) {
			closeTransport()
			return result
		}
		if err := transport.SendPacket(firstPkt); err != nil {
			if stderrors.Is(err, xudptransport.ErrDatagramTooLarge) {
				xl.Warnf("xudp active transport dropped oversized first packet: %v", err)
				result.pendingPacket = nil
			} else {
				xl.Warnf("xudp active transport send first packet error: %v", err)
				closeTransport()
				return result
			}
		} else {
			// SendPacket returning nil is the transport's delivery boundary. A
			// concurrent cancel after this point must not cause a duplicate send.
			result.pendingPacket = nil
			if !sv.state.IsCurrent(generation, epoch) {
				closeTransport()
				return result
			}
		}
	}

	readerDone := make(chan struct{})
	go func() {
		defer close(readerDone)
		for {
			if !sv.state.IsCurrent(generation, epoch) {
				return
			}
			pkt, err := transport.ReceivePacket(transportCtx)
			if err != nil {
				return
			}
			// The epoch may change while ReceivePacket is in flight. Do not let
			// a packet from the old transport enter the new session's read path.
			if !sv.state.IsCurrent(generation, epoch) {
				return
			}
			if err := errors.PanicToError(func() {
				select {
				case sv.readCh <- pkt:
				case <-transportCtx.Done():
				}
			}); err != nil {
				return
			}
		}
	}()

	var handoffPacket *msg.UDPPacket
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
			case <-transportCtx.Done():
				return
			}
			// Cancellation may become ready in the same select that dequeues pkt.
			// Recheck before starting the send and preserve the dequeued packet if
			// this transport is no longer allowed to own it.
			select {
			case <-cancel:
				handoffPacket = pkt
				return
			case <-readerDone:
				handoffPacket = pkt
				return
			case <-sv.closeCh:
				handoffPacket = pkt
				return
			case <-transportCtx.Done():
				handoffPacket = pkt
				return
			default:
			}
			if !sv.state.IsCurrent(generation, epoch) {
				handoffPacket = pkt
				return
			}
			if err := transport.SendPacket(pkt); err != nil {
				if stderrors.Is(err, xudptransport.ErrDatagramTooLarge) {
					xl.Warnf("xudp active transport dropped oversized packet: %v", err)
					continue
				}
				// The packet left sendCh but the transport did not accept it. Hand it
				// directly to the next transport instead of re-enqueueing and risking
				// reordering or a full-channel deadlock.
				handoffPacket = pkt
				return
			}
			// A nil error means the packet was accepted. If cancel or an epoch
			// change raced with that success, stop without handing it off so it is
			// never sent twice.
			if !sv.state.IsCurrent(generation, epoch) {
				return
			}
		}
	}()

	select {
	case <-cancel:
		closeTransport()
	case <-sv.closeCh:
		closeTransport()
	case <-transportCtx.Done():
		closeTransport()
	case <-readerDone:
		closeTransport()
	case <-senderDone:
		closeTransport()
	}
	// Closing the transport above is what wakes the other worker if it is
	// blocked in ReceivePacket or SendPacket. Always wait for both workers so
	// an old transport cannot continue consuming the shared send channel.
	<-readerDone
	<-senderDone
	result.pendingPacket = handoffPacket
	return result
}

func (sv *XUDPVisitor) runRelayWithP2PRecovery(generation uint64, firstPkt *msg.UDPPacket) (bool, *msg.UDPPacket) {
	xl := xlog.FromContextSafe(sv.ctx)

	relayConn, relayEpoch, ok := sv.dialRelayForGeneration(generation)
	if !ok {
		xl.Warnf("xudp relay failed")
		return false, firstPkt
	}

	relayCancel := make(chan struct{})
	relayDone := make(chan activeTransportResult, 1)
	go func() {
		relayDone <- sv.runActiveTransport(&relayActiveTransport{conn: relayConn}, generation, relayEpoch, firstPkt, relayCancel)
	}()

	wait := sv.recoveryWait
	if wait == nil {
		wait = func(delay time.Duration) <-chan time.Time { return time.After(delay) }
	}
	probeAttempt := 0

	for {
		delay := sv.nextRecoveryDelay(probeAttempt)
		probeAttempt++
		probeReady := wait(delay)
		select {
		case <-sv.closeCh:
			close(relayCancel)
			// Join the relay before returning so no worker or connection can
			// outlive the session owner after visitor Close.
			relayResult := <-relayDone
			return false, relayResult.pendingPacket
		case relayResult := <-relayDone:
			sv.state.SetPhaseForTransport(generation, relayEpoch, xudpstate.PhaseClosed)
			return false, relayResult.pendingPacket
		case <-probeReady:
			sv.state.SetPhaseForGeneration(generation, xudpstate.PhaseRecovering)
			conn, ok := sv.dialP2PForGeneration(generation)
			if !ok {
				// dialP2P reports intermediate phases while probing. The relay
				// transport remains live and authoritative, so restore its phase
				// after every failed probe.
				sv.state.SetPhaseForTransport(generation, relayEpoch, xudpstate.PhaseRelayReady)
				continue
			}

			xl.Infof("xudp relay recovered P2P path")
			close(relayCancel)
			relayResult := <-relayDone

			// Candidate establishment must not advance the epoch. Keep relay as
			// the sole data plane until its sender has stopped and been joined;
			// only then publish the P2P epoch and let it consume sendCh.
			select {
			case <-sv.closeCh:
				_ = conn.Close()
				return false, relayResult.pendingPacket
			default:
			}
			p2pEpoch, activated := sv.state.BeginTransport(generation, xudpstate.PhaseP2PReady)
			if !activated {
				_ = conn.Close()
				return false, relayResult.pendingPacket
			}
			// The relay's unsent packet is synchronously attempted first. Only
			// after that attempt does runActiveTransport start the P2P sender that
			// consumes later packets from sendCh, preserving FIFO order.
			p2pResult := sv.runActiveTransport(
				&p2pActiveTransport{conn: conn}, generation, p2pEpoch, relayResult.pendingPacket, nil,
			)
			return true, p2pResult.pendingPacket
		}
	}
}

func (sv *XUDPVisitor) Close() {
	sv.mu.Lock()
	if sv.closed {
		done := sv.closeDone
		sv.mu.Unlock()
		if done != nil {
			<-done
		}
		return
	}
	sv.closed = true
	if sv.closeDone == nil {
		sv.closeDone = make(chan struct{})
	}
	done := sv.closeDone
	closeCh := sv.closeCh
	udpConn := sv.udpConn
	cancel := sv.cancel
	activeClosers := make([]func(), 0, len(sv.activeClosers))
	for id, closer := range sv.activeClosers {
		activeClosers = append(activeClosers, closer)
		delete(sv.activeClosers, id)
	}
	workers := &sv.workers
	if cancel != nil {
		cancel()
	}
	sv.BaseVisitor.Close()
	if udpConn != nil {
		_ = udpConn.Close()
	}
	if closeCh != nil {
		close(closeCh)
	}
	sv.mu.Unlock()

	for _, closer := range activeClosers {
		closer()
	}
	// Run registers every top-level controllable goroutine before publishing
	// the running state. Close therefore cannot race Wait with a later Add.
	workers.Wait()
	close(done)
}
