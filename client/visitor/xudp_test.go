package visitor

import (
	"context"
	"fmt"
	"io"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/fatedier/frp/pkg/msg"
	xudpstate "github.com/fatedier/frp/pkg/xudp/state"
	xudptransport "github.com/fatedier/frp/pkg/xudp/transport"
)

type fakeXUDPActiveTransport struct {
	mu          sync.Mutex
	sendErrs    []error
	sends       int
	sentCh      chan struct{}
	releaseSend <-chan struct{}
	closedCh    chan struct{}
	closeOne    sync.Once
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
	if t.releaseSend != nil {
		<-t.releaseSend
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

func TestXUDPRelayCompressionResourcesRemainOwnedUntilCloseCompletes(t *testing.T) {
	t.Parallel()

	underlying := &blockingXUDPRelayCloser{
		closeStarted: make(chan struct{}),
		releaseClose: make(chan struct{}),
	}
	var recycleCalls atomic.Int32
	recycled := make(chan struct{})
	rwc := &xudpRelayReadWriteCloser{
		ReadWriteCloser: underlying,
		recycleFn: func() {
			if recycleCalls.Add(1) == 1 {
				close(recycled)
			}
		},
	}

	closeDone := make(chan error, 1)
	go func() { closeDone <- rwc.Close() }()

	select {
	case <-underlying.closeStarted:
	case <-time.After(time.Second):
		t.Fatal("relay connection close did not start")
	}
	select {
	case <-recycled:
		t.Fatal("compression resources were recycled before connection close completed")
	default:
	}

	close(underlying.releaseClose)
	select {
	case err := <-closeDone:
		if err != nil {
			t.Fatalf("relay close returned error: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("relay connection close did not complete")
	}
	select {
	case <-recycled:
	case <-time.After(time.Second):
		t.Fatal("compression resources were not recycled after connection close")
	}

	if err := rwc.Close(); err != nil {
		t.Fatalf("second relay close returned error: %v", err)
	}
	if got := recycleCalls.Load(); got != 1 {
		t.Fatalf("recycle calls = %d, want 1", got)
	}
}

type blockingXUDPRelayCloser struct {
	closeStarted chan struct{}
	releaseClose chan struct{}
	closeOnce    sync.Once
}

func (c *blockingXUDPRelayCloser) Read([]byte) (int, error)    { return 0, io.EOF }
func (c *blockingXUDPRelayCloser) Write(p []byte) (int, error) { return len(p), nil }

func (c *blockingXUDPRelayCloser) Close() error {
	c.closeOnce.Do(func() {
		close(c.closeStarted)
		<-c.releaseClose
	})
	return nil
}

var _ xudpActiveTransport = (*fakeXUDPActiveTransport)(nil)
