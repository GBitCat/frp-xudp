package visitor

import (
	"context"
	"fmt"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/fatedier/frp/pkg/msg"
	xudpstate "github.com/fatedier/frp/pkg/xudp/state"
	xudptransport "github.com/fatedier/frp/pkg/xudp/transport"
	quic "github.com/quic-go/quic-go"
)

func newRecoveryTestVisitor() *XUDPVisitor {
	return &XUDPVisitor{
		BaseVisitor: &BaseVisitor{ctx: context.Background()},
		state:       xudpstate.NewMachine(),
		readCh:      make(chan *msg.UDPPacket, 1),
		sendCh:      make(chan *msg.UDPPacket, 1),
		closeCh:     make(chan struct{}),
	}
}

func TestRecoveryOldTransportCannotWriteAfterEpochSwitch(t *testing.T) {
	t.Parallel()

	visitor := newRecoveryTestVisitor()
	generation := visitor.state.BeginSession()
	relayEpoch, ok := visitor.state.BeginTransport(generation, xudpstate.PhaseRelayReady)
	if !ok {
		t.Fatal("failed to start relay transport")
	}
	p2pEpoch, ok := visitor.state.BeginTransport(generation, xudpstate.PhaseP2PReady)
	if !ok {
		t.Fatal("failed to start P2P transport")
	}

	if visitor.state.IsCurrent(generation, relayEpoch) {
		t.Fatal("relay transport remained current after P2P epoch started")
	}
	if !visitor.state.IsCurrent(generation, p2pEpoch) {
		t.Fatal("new P2P transport is not current")
	}

	oldTransport := &fakeXUDPActiveTransport{
		sentCh:   make(chan struct{}, 1),
		closedCh: make(chan struct{}),
	}
	visitor.runActiveTransport(oldTransport, generation, relayEpoch, &msg.UDPPacket{}, nil)

	oldTransport.mu.Lock()
	sends := oldTransport.sends
	oldTransport.mu.Unlock()
	if sends != 0 {
		t.Fatalf("stale relay transport SendPacket calls = %d, want 0", sends)
	}
	selectClosed(t, oldTransport.closedCh, "stale relay transport")
}

func TestRecoveryOldGenerationCannotWriteAfterNewSession(t *testing.T) {
	t.Parallel()

	visitor := newRecoveryTestVisitor()
	oldGeneration := visitor.state.BeginSession()
	oldEpoch, ok := visitor.state.BeginTransport(oldGeneration, xudpstate.PhaseP2PReady)
	if !ok {
		t.Fatal("failed to start old transport")
	}
	newGeneration := visitor.state.BeginSession()
	if oldGeneration == newGeneration {
		t.Fatal("session generation did not advance")
	}

	oldTransport := &fakeXUDPActiveTransport{
		sentCh:   make(chan struct{}, 1),
		closedCh: make(chan struct{}),
	}
	visitor.runActiveTransport(oldTransport, oldGeneration, oldEpoch, &msg.UDPPacket{}, nil)

	oldTransport.mu.Lock()
	sends := oldTransport.sends
	oldTransport.mu.Unlock()
	if sends != 0 {
		t.Fatalf("stale generation SendPacket calls = %d, want 0", sends)
	}
	selectClosed(t, oldTransport.closedCh, "stale-generation transport")
}

func TestRecoveryOversizedPacketKeepsCurrentP2PState(t *testing.T) {
	t.Parallel()

	visitor := newRecoveryTestVisitor()
	generation := visitor.state.BeginSession()
	epoch, ok := visitor.state.BeginTransport(generation, xudpstate.PhaseP2PReady)
	if !ok {
		t.Fatal("failed to start P2P transport")
	}

	transport := &fakeXUDPActiveTransport{
		sendErrs: []error{
			// This represents a packet-level rejection. It must not invalidate
			// the transport or make the recovery loop take over.
			fmt.Errorf("%w: test packet", xudptransport.ErrDatagramTooLarge),
		},
		sentCh:   make(chan struct{}, 1),
		closedCh: make(chan struct{}),
	}
	done := make(chan struct{})
	go func() {
		visitor.runActiveTransport(transport, generation, epoch, &msg.UDPPacket{}, nil)
		close(done)
	}()

	select {
	case <-time.After(time.Second):
		t.Fatal("runActiveTransport did not continue after oversized packet")
	case visitor.sendCh <- &msg.UDPPacket{}:
	}

	select {
	case <-transport.sentCh:
	case <-time.After(time.Second):
		t.Fatal("small packet was not sent after oversized packet")
	}

	phase, currentGeneration, currentEpoch := visitor.state.Snapshot()
	if phase != xudpstate.PhaseP2PReady || currentGeneration != generation || currentEpoch != epoch {
		t.Fatalf("state after oversized packet = (%s, %d, %d), want (%s, %d, %d)",
			phase, currentGeneration, currentEpoch,
			xudpstate.PhaseP2PReady, generation, epoch)
	}
	if !visitor.state.IsCurrent(generation, epoch) {
		t.Fatal("oversized packet invalidated the current P2P transport")
	}

	close(visitor.closeCh)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("runActiveTransport did not stop after close")
	}
}

func TestRunActiveTransportRetainsPendingOnConnectionError(t *testing.T) {
	t.Parallel()

	visitor := newRecoveryTestVisitor()
	generation := visitor.state.BeginSession()
	epoch, ok := visitor.state.BeginTransport(generation, xudpstate.PhaseP2PReady)
	if !ok {
		t.Fatal("failed to start P2P transport")
	}
	transport := &fakeXUDPActiveTransport{
		sendErrs: []error{fmt.Errorf("connection failed")},
		sentCh:   make(chan struct{}, 1),
		closedCh: make(chan struct{}),
	}

	firstPkt := &msg.UDPPacket{}
	if result := visitor.runActiveTransport(transport, generation, epoch, firstPkt, nil); result.pendingPacket != firstPkt {
		t.Fatal("connection-level first-packet failure did not retain the pending packet")
	}
}

func TestRunActiveTransportKeepsSuccessfulFirstPacketHandledAfterEpochChange(t *testing.T) {
	visitor := newRecoveryTestVisitor()
	generation := visitor.state.BeginSession()
	epoch, ok := visitor.state.BeginTransport(generation, xudpstate.PhaseP2PReady)
	if !ok {
		t.Fatal("failed to start P2P transport")
	}
	releaseSend := make(chan struct{})
	transport := &fakeXUDPActiveTransport{
		sentCh:      make(chan struct{}, 1),
		releaseSend: releaseSend,
		closedCh:    make(chan struct{}),
	}
	result := make(chan activeTransportResult, 1)
	go func() {
		result <- visitor.runActiveTransport(transport, generation, epoch, &msg.UDPPacket{}, nil)
	}()
	select {
	case <-transport.sentCh:
	case <-time.After(time.Second):
		t.Fatal("first packet was not sent")
	}
	if _, ok := visitor.state.BeginTransport(generation, xudpstate.PhaseRelayReady); !ok {
		t.Fatal("failed to advance transport epoch")
	}
	close(releaseSend)
	select {
	case activeResult := <-result:
		if activeResult.pendingPacket != nil {
			t.Fatal("successful first packet was retained after epoch change")
		}
	case <-time.After(time.Second):
		t.Fatal("runActiveTransport did not stop after epoch change")
	}
}

func TestRecoveryFailedProbeKeepsRelayAndSuccessfulProbeSwitchesToP2P(t *testing.T) {
	t.Parallel()

	visitor := newRecoveryTestVisitor()
	generation := visitor.state.BeginSession()
	relayConn, relayPeer := net.Pipe()
	defer relayPeer.Close()
	visitor.relayDialer = func(g uint64) (*msg.Conn, uint64, bool) {
		epoch, ok := visitor.state.BeginTransport(g, xudpstate.PhaseRelayReady)
		return msg.NewConn(relayConn, msg.NewV1ReadWriter(relayConn)), epoch, ok
	}

	var calls int
	var probePhases []xudpstate.Phase
	var recoveryDelays []time.Duration
	visitor.p2PDialer = func(g uint64) (xudptransport.DatagramTransport, bool) {
		calls++
		phase, _, _ := visitor.state.Snapshot()
		probePhases = append(probePhases, phase)
		if calls == 1 {
			return nil, false
		}
		return &fakeDatagramTransport{}, true
	}
	visitor.recoveryJitter = func(delay time.Duration) time.Duration { return delay }
	visitor.recoveryWait = func(delay time.Duration) <-chan time.Time {
		recoveryDelays = append(recoveryDelays, delay)
		ch := make(chan time.Time, 1)
		ch <- time.Unix(0, int64(delay))
		return ch
	}

	if recovered, pending := visitor.runRelayWithP2PRecovery(generation, nil); !recovered || pending != nil {
		t.Fatal("recovery did not switch to P2P after successful probe")
	}
	if calls != 2 {
		t.Fatalf("P2P probe calls = %d, want 2", calls)
	}
	for i, phase := range probePhases {
		if phase != xudpstate.PhaseRecovering {
			t.Fatalf("phase during probe %d = %s, want %s", i+1, phase, xudpstate.PhaseRecovering)
		}
	}
	if len(recoveryDelays) != 2 || recoveryDelays[0] != time.Second || recoveryDelays[1] != 2*time.Second {
		t.Fatalf("recovery delays = %v, want [1s 2s]", recoveryDelays)
	}
	phase, _, _ := visitor.state.Snapshot()
	if phase != xudpstate.PhaseP2PReady {
		t.Fatalf("final phase = %s, want %s", phase, xudpstate.PhaseP2PReady)
	}
}

func TestRecoveryActivatesCandidateOnlyAfterRelaySenderStops(t *testing.T) {
	visitor := newRecoveryTestVisitor()
	visitor.sendCh = make(chan *msg.UDPPacket, 4)
	generation := visitor.state.BeginSession()

	relayConn, relayPeer := net.Pipe()
	gatedRelay := newGatedCloseConn(relayConn)
	t.Cleanup(gatedRelay.release)
	t.Cleanup(func() { _ = relayPeer.Close() })
	var relayEpoch uint64
	visitor.relayDialer = func(g uint64) (*msg.Conn, uint64, bool) {
		var ok bool
		relayEpoch, ok = visitor.state.BeginTransport(g, xudpstate.PhaseRelayReady)
		return msg.NewConn(gatedRelay, msg.NewV1ReadWriter(gatedRelay)), relayEpoch, ok
	}

	candidateReady := make(chan struct{})
	releaseCandidate := make(chan struct{})
	candidate := newRecordingDatagramTransport()
	visitor.p2PDialer = func(g uint64) (xudptransport.DatagramTransport, bool) {
		if g != generation {
			return nil, false
		}
		close(candidateReady)
		<-releaseCandidate
		return candidate, true
	}
	visitor.recoveryJitterDisabled = true
	visitor.recoveryWait = func(time.Duration) <-chan time.Time {
		ready := make(chan time.Time, 1)
		ready <- time.Now()
		return ready
	}

	type recoveryResult struct {
		recovered bool
		pending   *msg.UDPPacket
	}
	resultCh := make(chan recoveryResult, 1)
	go func() {
		recovered, pending := visitor.runRelayWithP2PRecovery(generation, nil)
		resultCh <- recoveryResult{recovered: recovered, pending: pending}
	}()

	select {
	case <-candidateReady:
	case <-time.After(time.Second):
		t.Fatal("P2P candidate probe did not start")
	}
	phase, currentGeneration, currentEpoch := visitor.state.Snapshot()
	if phase != xudpstate.PhaseRecovering || currentGeneration != generation || currentEpoch != relayEpoch {
		t.Fatalf("state during candidate dial = (%s, %d, %d), want (%s, %d, %d)",
			phase, currentGeneration, currentEpoch,
			xudpstate.PhaseRecovering, generation, relayEpoch)
	}

	relayPacket := recoveryPacket("relay-before-cutover")
	visitor.sendCh <- relayPacket
	relayRead := make(chan *msg.UDPPacket, 1)
	relayReadErr := make(chan error, 1)
	go func() {
		peer := msg.NewConn(relayPeer, msg.NewV1ReadWriter(relayPeer))
		raw, err := peer.ReadMsg()
		if err != nil {
			relayReadErr <- err
			return
		}
		pkt, ok := raw.(*msg.UDPPacket)
		if !ok {
			relayReadErr <- fmt.Errorf("relay message type %T, want *msg.UDPPacket", raw)
			return
		}
		relayRead <- pkt
	}()
	select {
	case err := <-relayReadErr:
		t.Fatalf("relay packet read failed: %v", err)
	case pkt := <-relayRead:
		if string(pkt.Content) != string(relayPacket.Content) {
			t.Fatalf("relay packet content = %q, want %q", pkt.Content, relayPacket.Content)
		}
	case <-time.After(time.Second):
		t.Fatal("relay stopped consuming while P2P was only a candidate")
	}

	close(releaseCandidate)
	select {
	case <-gatedRelay.closeStarted:
	case <-time.After(time.Second):
		t.Fatal("relay shutdown did not start after candidate succeeded")
	}
	phase, currentGeneration, currentEpoch = visitor.state.Snapshot()
	if currentGeneration != generation || currentEpoch != relayEpoch {
		t.Fatalf("P2P epoch advanced before relay sender joined: state = (%s, %d, %d), relay epoch = %d",
			phase, currentGeneration, currentEpoch, relayEpoch)
	}

	gatedRelay.release()
	deadline := time.After(time.Second)
	for {
		phase, currentGeneration, currentEpoch = visitor.state.Snapshot()
		if phase == xudpstate.PhaseP2PReady && currentGeneration == generation && currentEpoch > relayEpoch {
			break
		}
		select {
		case <-deadline:
			t.Fatalf("P2P candidate was not activated after relay stopped: state = (%s, %d, %d)",
				phase, currentGeneration, currentEpoch)
		default:
			time.Sleep(time.Millisecond)
		}
	}

	p2pPacket := recoveryPacket("p2p-after-cutover")
	visitor.sendCh <- p2pPacket
	select {
	case body := <-candidate.sent:
		pkt, err := msg.DecodeUDPPacketBinary(body)
		if err != nil {
			t.Fatalf("decode P2P packet: %v", err)
		}
		if string(pkt.Content) != string(p2pPacket.Content) {
			t.Fatalf("P2P packet content = %q, want %q", pkt.Content, p2pPacket.Content)
		}
	case <-time.After(time.Second):
		t.Fatal("new P2P sender did not consume packet after activation")
	}

	close(visitor.closeCh)
	select {
	case result := <-resultCh:
		if !result.recovered || result.pending != nil {
			t.Fatalf("recovery result = (%t, %p), want (true, nil)", result.recovered, result.pending)
		}
	case <-time.After(time.Second):
		t.Fatal("recovery did not stop after visitor close")
	}
}

func TestRecoveryHandsOffFailedRelaySendBeforeQueuedP2PData(t *testing.T) {
	visitor := newRecoveryTestVisitor()
	visitor.sendCh = make(chan *msg.UDPPacket, 4)
	generation := visitor.state.BeginSession()

	relayConn, relayPeer := net.Pipe()
	controlledRelay := newControlledRelayConn(relayConn, false)
	t.Cleanup(func() { _ = relayPeer.Close() })
	visitor.relayDialer = func(g uint64) (*msg.Conn, uint64, bool) {
		epoch, ok := visitor.state.BeginTransport(g, xudpstate.PhaseRelayReady)
		return msg.NewConn(controlledRelay, msg.NewV1ReadWriter(controlledRelay)), epoch, ok
	}

	probeReady := make(chan time.Time, 1)
	visitor.recoveryJitterDisabled = true
	visitor.recoveryWait = func(time.Duration) <-chan time.Time { return probeReady }
	candidate := newRecordingDatagramTransport()
	visitor.p2PDialer = func(uint64) (xudptransport.DatagramTransport, bool) {
		return candidate, true
	}

	type recoveryResult struct {
		recovered bool
		pending   *msg.UDPPacket
	}
	resultCh := make(chan recoveryResult, 1)
	go func() {
		recovered, pending := visitor.runRelayWithP2PRecovery(generation, nil)
		resultCh <- recoveryResult{recovered: recovered, pending: pending}
	}()

	handoff := recoveryPacket("relay-dequeued-but-unsent")
	queued := recoveryPacket("queued-after-handoff")
	visitor.sendCh <- handoff
	select {
	case <-controlledRelay.writeStarted:
	case <-time.After(time.Second):
		t.Fatal("relay did not dequeue the handoff packet")
	}
	visitor.sendCh <- queued
	probeReady <- time.Now()

	for i, want := range []*msg.UDPPacket{handoff, queued} {
		select {
		case body := <-candidate.sent:
			pkt, err := msg.DecodeUDPPacketBinary(body)
			if err != nil {
				t.Fatalf("decode P2P packet %d: %v", i, err)
			}
			if string(pkt.Content) != string(want.Content) {
				t.Fatalf("P2P packet %d content = %q, want %q", i, pkt.Content, want.Content)
			}
		case <-time.After(time.Second):
			t.Fatalf("P2P packet %d was not sent", i)
		}
	}

	close(visitor.closeCh)
	select {
	case result := <-resultCh:
		if !result.recovered || result.pending != nil {
			t.Fatalf("recovery result = (%t, %p), want (true, nil)", result.recovered, result.pending)
		}
	case <-time.After(time.Second):
		t.Fatal("recovery did not stop after visitor close")
	}
}

func TestRecoveryDoesNotResendRelayPacketThatSucceededDuringCancel(t *testing.T) {
	visitor := newRecoveryTestVisitor()
	visitor.sendCh = make(chan *msg.UDPPacket, 4)
	generation := visitor.state.BeginSession()

	relayConn, relayPeer := net.Pipe()
	controlledRelay := newControlledRelayConn(relayConn, true)
	t.Cleanup(controlledRelay.release)
	t.Cleanup(func() { _ = relayPeer.Close() })
	visitor.relayDialer = func(g uint64) (*msg.Conn, uint64, bool) {
		epoch, ok := visitor.state.BeginTransport(g, xudpstate.PhaseRelayReady)
		return msg.NewConn(controlledRelay, msg.NewV1ReadWriter(controlledRelay)), epoch, ok
	}

	probeReady := make(chan time.Time, 1)
	visitor.recoveryJitterDisabled = true
	visitor.recoveryWait = func(time.Duration) <-chan time.Time { return probeReady }
	candidate := newRecordingDatagramTransport()
	visitor.p2PDialer = func(uint64) (xudptransport.DatagramTransport, bool) {
		return candidate, true
	}

	type recoveryResult struct {
		recovered bool
		pending   *msg.UDPPacket
	}
	resultCh := make(chan recoveryResult, 1)
	go func() {
		recovered, pending := visitor.runRelayWithP2PRecovery(generation, nil)
		resultCh <- recoveryResult{recovered: recovered, pending: pending}
	}()

	sentByRelay := recoveryPacket("relay-send-succeeds-during-cancel")
	queued := recoveryPacket("p2p-only")
	visitor.sendCh <- sentByRelay
	select {
	case <-controlledRelay.writeStarted:
	case <-time.After(time.Second):
		t.Fatal("relay did not dequeue the packet")
	}
	visitor.sendCh <- queued
	probeReady <- time.Now()
	select {
	case <-controlledRelay.closeStarted:
	case <-time.After(time.Second):
		t.Fatal("relay cancellation did not close the transport")
	}
	controlledRelay.release()

	select {
	case body := <-candidate.sent:
		pkt, err := msg.DecodeUDPPacketBinary(body)
		if err != nil {
			t.Fatalf("decode P2P packet: %v", err)
		}
		if string(pkt.Content) != string(queued.Content) {
			t.Fatalf("first P2P packet = %q, want only queued packet %q", pkt.Content, queued.Content)
		}
	case <-time.After(time.Second):
		t.Fatal("queued packet was not sent by P2P")
	}
	select {
	case body := <-candidate.sent:
		pkt, err := msg.DecodeUDPPacketBinary(body)
		if err != nil {
			t.Fatalf("decode unexpected P2P packet: %v", err)
		}
		t.Fatalf("successful Relay packet was duplicated on P2P: %q", pkt.Content)
	case <-time.After(50 * time.Millisecond):
	}

	close(visitor.closeCh)
	select {
	case result := <-resultCh:
		if !result.recovered || result.pending != nil {
			t.Fatalf("recovery result = (%t, %p), want (true, nil)", result.recovered, result.pending)
		}
	case <-time.After(time.Second):
		t.Fatal("recovery did not stop after visitor close")
	}
}

func TestRunRelayCloseWaitsForRelayJoin(t *testing.T) {
	visitor := newRecoveryTestVisitor()
	generation := visitor.state.BeginSession()

	relayConn, relayPeer := net.Pipe()
	gatedRelay := newGatedCloseConn(relayConn)
	t.Cleanup(gatedRelay.release)
	t.Cleanup(func() { _ = relayPeer.Close() })
	visitor.relayDialer = func(g uint64) (*msg.Conn, uint64, bool) {
		epoch, ok := visitor.state.BeginTransport(g, xudpstate.PhaseRelayReady)
		return msg.NewConn(gatedRelay, msg.NewV1ReadWriter(gatedRelay)), epoch, ok
	}
	visitor.recoveryJitterDisabled = true
	visitor.recoveryWait = func(time.Duration) <-chan time.Time { return make(chan time.Time) }

	type recoveryResult struct {
		recovered bool
		pending   *msg.UDPPacket
	}
	resultCh := make(chan recoveryResult, 1)
	go func() {
		recovered, pending := visitor.runRelayWithP2PRecovery(generation, nil)
		resultCh <- recoveryResult{recovered: recovered, pending: pending}
	}()

	close(visitor.closeCh)
	select {
	case <-gatedRelay.closeStarted:
	case <-time.After(time.Second):
		t.Fatal("relay close did not start")
	}
	select {
	case <-resultCh:
		t.Fatal("runRelayWithP2PRecovery returned before relay joined")
	case <-time.After(50 * time.Millisecond):
	}

	gatedRelay.release()
	select {
	case result := <-resultCh:
		if result.recovered || result.pending != nil {
			t.Fatalf("close result = (%t, %p), want (false, nil)", result.recovered, result.pending)
		}
	case <-time.After(time.Second):
		t.Fatal("runRelayWithP2PRecovery did not return after relay joined")
	}
}

func TestRecoveryBackoffSequenceCanDisableJitter(t *testing.T) {
	visitor := newRecoveryTestVisitor()
	visitor.recoveryJitterDisabled = true
	want := []time.Duration{time.Second, 2 * time.Second, 5 * time.Second, 10 * time.Second, 30 * time.Second, 30 * time.Second}
	for attempt, wantDelay := range want {
		if got := visitor.nextRecoveryDelay(attempt); got != wantDelay {
			t.Fatalf("attempt %d delay = %s, want %s", attempt, got, wantDelay)
		}
	}
}

func TestRecoveryInjectedJitterIsBounded(t *testing.T) {
	visitor := newRecoveryTestVisitor()
	visitor.recoveryJitter = func(time.Duration) time.Duration { return 0 }
	if got, want := visitor.nextRecoveryDelay(2), 4*time.Second; got != want {
		t.Fatalf("lower-clamped delay = %s, want %s", got, want)
	}

	visitor.recoveryJitter = func(time.Duration) time.Duration { return time.Hour }
	if got, want := visitor.nextRecoveryDelay(2), 6*time.Second; got != want {
		t.Fatalf("upper-clamped delay = %s, want %s", got, want)
	}
}

type fakeDatagramTransport struct{}

func (*fakeDatagramTransport) SendDatagram([]byte) error                       { return nil }
func (*fakeDatagramTransport) ReceiveDatagram(context.Context) ([]byte, error) { return nil, io.EOF }
func (*fakeDatagramTransport) MaxDatagramPayloadSize() int                     { return 1200 }
func (*fakeDatagramTransport) ConnectionState() quic.ConnectionState           { return quic.ConnectionState{} }
func (*fakeDatagramTransport) VerifyPeerFingerprint(string) error              { return nil }
func (*fakeDatagramTransport) Close() error                                    { return nil }
func (*fakeDatagramTransport) LocalAddr() net.Addr                             { return fakeAddr("local") }
func (*fakeDatagramTransport) RemoteAddr() net.Addr                            { return fakeAddr("remote") }

type gatedCloseConn struct {
	net.Conn
	closeStarted chan struct{}
	releaseClose chan struct{}
	startOnce    sync.Once
	releaseOnce  sync.Once
}

type controlledRelayConn struct {
	net.Conn
	succeedAfterClose bool
	writeStarted      chan struct{}
	closeStarted      chan struct{}
	releaseWrite      chan struct{}
	closed            chan struct{}
	writeOnce         sync.Once
	closeOnce         sync.Once
	releaseOnce       sync.Once
}

func newControlledRelayConn(conn net.Conn, succeedAfterClose bool) *controlledRelayConn {
	return &controlledRelayConn{
		Conn:              conn,
		succeedAfterClose: succeedAfterClose,
		writeStarted:      make(chan struct{}),
		closeStarted:      make(chan struct{}),
		releaseWrite:      make(chan struct{}),
		closed:            make(chan struct{}),
	}
}

func (c *controlledRelayConn) Write(p []byte) (int, error) {
	c.writeOnce.Do(func() { close(c.writeStarted) })
	if c.succeedAfterClose {
		<-c.releaseWrite
		return len(p), nil
	}
	<-c.closed
	return 0, net.ErrClosed
}

func (c *controlledRelayConn) Close() error {
	c.closeOnce.Do(func() {
		close(c.closeStarted)
		close(c.closed)
		_ = c.Conn.Close()
	})
	return nil
}

func (c *controlledRelayConn) release() {
	c.releaseOnce.Do(func() { close(c.releaseWrite) })
}

func newGatedCloseConn(conn net.Conn) *gatedCloseConn {
	return &gatedCloseConn{
		Conn:         conn,
		closeStarted: make(chan struct{}),
		releaseClose: make(chan struct{}),
	}
}

func (c *gatedCloseConn) Close() error {
	c.startOnce.Do(func() { close(c.closeStarted) })
	<-c.releaseClose
	return c.Conn.Close()
}

func (c *gatedCloseConn) release() {
	c.releaseOnce.Do(func() { close(c.releaseClose) })
}

type recordingDatagramTransport struct {
	sent      chan []byte
	closed    chan struct{}
	closeOnce sync.Once
}

func newRecordingDatagramTransport() *recordingDatagramTransport {
	return &recordingDatagramTransport{
		sent:   make(chan []byte, 4),
		closed: make(chan struct{}),
	}
}

func (t *recordingDatagramTransport) SendDatagram(body []byte) error {
	copyBody := append([]byte(nil), body...)
	select {
	case t.sent <- copyBody:
		return nil
	case <-t.closed:
		return net.ErrClosed
	}
}

func (t *recordingDatagramTransport) ReceiveDatagram(ctx context.Context) ([]byte, error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-t.closed:
		return nil, net.ErrClosed
	}
}

func (*recordingDatagramTransport) MaxDatagramPayloadSize() int { return 1200 }
func (*recordingDatagramTransport) ConnectionState() quic.ConnectionState {
	return quic.ConnectionState{}
}
func (*recordingDatagramTransport) VerifyPeerFingerprint(string) error { return nil }
func (t *recordingDatagramTransport) Close() error {
	t.closeOnce.Do(func() { close(t.closed) })
	return nil
}
func (*recordingDatagramTransport) LocalAddr() net.Addr  { return fakeAddr("local") }
func (*recordingDatagramTransport) RemoteAddr() net.Addr { return fakeAddr("remote") }

func recoveryPacket(content string) *msg.UDPPacket {
	return &msg.UDPPacket{
		Content:    []byte(content),
		RemoteAddr: &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 9000},
	}
}

type fakeAddr string

func (a fakeAddr) Network() string { return "fake" }
func (a fakeAddr) String() string  { return string(a) }

func selectClosed(t *testing.T, ch <-chan struct{}, name string) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(time.Second):
		t.Fatalf("%s was not closed", name)
	}
}
