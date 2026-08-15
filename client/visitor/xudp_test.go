package visitor

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/fatedier/frp/pkg/msg"
	xudpstate "github.com/fatedier/frp/pkg/xudp/state"
	xudptransport "github.com/fatedier/frp/pkg/xudp/transport"
)

type fakeXUDPActiveTransport struct {
	mu       sync.Mutex
	sendErrs []error
	sends    int
	sentCh   chan struct{}
	closedCh chan struct{}
	closeOne sync.Once
}

func (t *fakeXUDPActiveTransport) SendPacket(*msg.UDPPacket) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.sends++
	if len(t.sendErrs) > 0 {
		err := t.sendErrs[0]
		t.sendErrs = t.sendErrs[1:]
		return err
	}
	select {
	case t.sentCh <- struct{}{}:
	default:
	}
	return nil
}

func (t *fakeXUDPActiveTransport) ReceivePacket(ctx context.Context) (*msg.UDPPacket, error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-t.closedCh:
		return nil, context.Canceled
	}
}

func (t *fakeXUDPActiveTransport) Close() error {
	t.closeOne.Do(func() { close(t.closedCh) })
	return nil
}

func TestRunActiveTransportDropsOversizedPacketWithoutClosingTransport(t *testing.T) {
	t.Parallel()

	visitor := &XUDPVisitor{
		BaseVisitor: &BaseVisitor{ctx: context.Background()},
		state:       xudpstate.NewMachine(),
		readCh:      make(chan *msg.UDPPacket, 1),
		sendCh:      make(chan *msg.UDPPacket, 1),
		closeCh:     make(chan struct{}),
	}
	generation := visitor.state.BeginSession()
	epoch, ok := visitor.state.BeginTransport(generation, xudpstate.PhaseP2PReady)
	if !ok {
		t.Fatal("failed to start P2P transport")
	}

	transport := &fakeXUDPActiveTransport{
		sendErrs: []error{fmt.Errorf("%w: test packet", xudptransport.ErrDatagramTooLarge)},
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
		t.Fatal("runActiveTransport did not continue after oversized first packet")
	case visitor.sendCh <- &msg.UDPPacket{}:
	}

	select {
	case <-transport.sentCh:
	case <-time.After(time.Second):
		t.Fatal("runActiveTransport did not send packet after oversized packet")
	}
	close(visitor.closeCh)

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("runActiveTransport did not stop after close")
	}

	transport.mu.Lock()
	sends := transport.sends
	transport.mu.Unlock()
	if sends != 2 {
		t.Fatalf("SendPacket calls = %d, want 2", sends)
	}
	select {
	case <-transport.closedCh:
	default:
		t.Fatal("active transport was not closed")
	}
}

var _ xudpActiveTransport = (*fakeXUDPActiveTransport)(nil)
