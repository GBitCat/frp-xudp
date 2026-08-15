package visitor

import (
	"context"
	"fmt"
	"io"
	"net"
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
	var phaseDuringSecondProbe xudpstate.Phase
	visitor.p2PDialer = func(g uint64) (xudptransport.DatagramTransport, uint64, bool) {
		calls++
		if calls == 1 {
			visitor.state.SetPhaseForGeneration(g, xudpstate.PhasePunching)
			return nil, 0, false
		}
		phaseDuringSecondProbe, _, _ = visitor.state.Snapshot()
		p2p := &fakeDatagramTransport{}
		epoch, ok := visitor.state.BeginTransport(g, xudpstate.PhaseP2PReady)
		return p2p, epoch, ok
	}
	visitor.recoveryInterval = time.Millisecond

	if !visitor.runRelayWithP2PRecovery(generation, nil) {
		t.Fatal("recovery did not switch to P2P after successful probe")
	}
	if calls != 2 {
		t.Fatalf("P2P probe calls = %d, want 2", calls)
	}
	if phaseDuringSecondProbe != xudpstate.PhaseRelayReady {
		t.Fatalf("phase before second probe = %s, want %s", phaseDuringSecondProbe, xudpstate.PhaseRelayReady)
	}
	phase, _, _ := visitor.state.Snapshot()
	if phase != xudpstate.PhaseP2PReady {
		t.Fatalf("final phase = %s, want %s", phase, xudpstate.PhaseP2PReady)
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
