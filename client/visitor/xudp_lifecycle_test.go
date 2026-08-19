package visitor

import (
	"context"
	"net"
	"sync"
	"testing"
	"time"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
	"github.com/fatedier/frp/pkg/nathole"
	xudpstate "github.com/fatedier/frp/pkg/xudp/state"
	xudptransport "github.com/fatedier/frp/pkg/xudp/transport"
	quic "github.com/quic-go/quic-go"
)

type blockingXUDPActiveTransport struct {
	sendStarted chan struct{}
	sendRelease chan struct{}
	closed      chan struct{}
	closeOnce   sync.Once
}

func newBlockingXUDPActiveTransport() *blockingXUDPActiveTransport {
	return &blockingXUDPActiveTransport{
		sendStarted: make(chan struct{}),
		sendRelease: make(chan struct{}),
		closed:      make(chan struct{}),
	}
}

func (t *blockingXUDPActiveTransport) SendPacket(*msg.UDPPacket) error {
	return t.blockSend()
}

func (t *blockingXUDPActiveTransport) blockSend() error {
	select {
	case <-t.sendStarted:
	default:
		close(t.sendStarted)
	}
	select {
	case <-t.sendRelease:
		return nil
	case <-t.closed:
		return context.Canceled
	}
}

func (t *blockingXUDPActiveTransport) SendDatagram([]byte) error { return t.blockSend() }

func (t *blockingXUDPActiveTransport) ReceiveDatagram(ctx context.Context) ([]byte, error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-t.closed:
		return nil, context.Canceled
	}
}

func (t *blockingXUDPActiveTransport) MaxDatagramPayloadSize() int { return 64 * 1024 }

func (t *blockingXUDPActiveTransport) ConnectionState() quic.ConnectionState {
	return quic.ConnectionState{}
}

func (t *blockingXUDPActiveTransport) VerifyPeerFingerprint(string) error { return nil }

func (t *blockingXUDPActiveTransport) LocalAddr() net.Addr  { return &net.UDPAddr{} }
func (t *blockingXUDPActiveTransport) RemoteAddr() net.Addr { return &net.UDPAddr{} }

func (t *blockingXUDPActiveTransport) ReceivePacket(ctx context.Context) (*msg.UDPPacket, error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-t.closed:
		return nil, context.Canceled
	}
}

func (t *blockingXUDPActiveTransport) Close() error {
	t.closeOnce.Do(func() {
		close(t.closed)
		close(t.sendRelease)
	})
	return nil
}

func newLifecycleXUDPVisitor() *XUDPVisitor {
	return &XUDPVisitor{
		BaseVisitor: &BaseVisitor{
			ctx:       context.Background(),
			clientCfg: &v1.ClientCommonConfig{UDPPacketSize: 1500},
		},
		cfg: &v1.XUDPVisitorConfig{
			VisitorBaseConfig: v1.VisitorBaseConfig{BindAddr: "127.0.0.1"},
		},
	}
}

func waitXUDPChannel(t *testing.T, ch <-chan struct{}, name string) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for %s", name)
	}
}

func TestXUDPVisitorCloseJoinsDispatcherAndForwarder(t *testing.T) {
	visitor := newLifecycleXUDPVisitor()
	transport := newBlockingXUDPActiveTransport()
	visitor.p2PDialer = func(uint64) (xudptransport.DatagramTransport, bool) {
		return transport, true
	}

	if err := visitor.Run(); err != nil {
		t.Fatal(err)
	}
	addr := visitor.udpConn.LocalAddr().(*net.UDPAddr)
	userConn, err := net.DialUDP("udp", nil, addr)
	if err != nil {
		t.Fatal(err)
	}
	defer userConn.Close()
	if _, err := userConn.Write([]byte("first")); err != nil {
		t.Fatal(err)
	}
	waitXUDPChannel(t, transport.sendStarted, "active transport send")

	closeDone := make(chan struct{})
	go func() {
		visitor.Close()
		close(closeDone)
	}()
	waitXUDPChannel(t, transport.closed, "active transport close")
	waitXUDPChannel(t, closeDone, "dispatcher and forwarder join")

	select {
	case <-visitor.closeDone:
	default:
		t.Fatal("Close returned before closeDone was published")
	}
	if err := userConn.SetReadDeadline(time.Now().Add(50 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
}

func TestXUDPPrepareRequestLateListenConnIsRecycled(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	returned := make(chan *net.UDPConn, 1)
	prepareDone := make(chan struct{})
	request := newXUDPPrepareRequest(func([]string, nathole.PrepareOptions) (*nathole.PrepareResult, error) {
		close(entered)
		<-release
		conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4zero})
		if err != nil {
			close(prepareDone)
			return nil, err
		}
		returned <- conn
		close(prepareDone)
		return &nathole.PrepareResult{ListenConn: conn}, nil
	}, nil, nathole.PrepareOptions{})

	closeCh := make(chan struct{})
	waitDone := make(chan bool, 1)
	go func() {
		_, ok := request.wait(closeCh)
		waitDone <- ok
	}()
	waitXUDPChannel(t, entered, "contextless Prepare start")
	close(closeCh)
	select {
	case ok := <-waitDone:
		if ok {
			t.Fatal("Prepare wait succeeded after visitor close")
		}
	case <-time.After(time.Second):
		t.Fatal("Close remained blocked on contextless Prepare")
	}
	close(release)
	conn := <-returned
	waitXUDPChannel(t, prepareDone, "late Prepare completion")
	if _, _, err := conn.ReadFromUDP(make([]byte, 1)); err == nil {
		t.Fatal("late Prepare ListenConn remained open")
	}
}

func TestXUDPVisitorCloseRejectsLateTransportRegistration(t *testing.T) {
	visitor := newRecoveryTestVisitor()
	visitor.Close()
	generation := visitor.state.BeginSession()
	epoch, ok := visitor.state.BeginTransport(generation, xudpstate.PhaseP2PReady)
	if !ok {
		t.Fatal("failed to create test transport epoch")
	}
	transport := newBlockingXUDPActiveTransport()
	visitor.runActiveTransport(transport, generation, epoch, &msg.UDPPacket{}, nil)
	select {
	case <-transport.closed:
	default:
		t.Fatal("transport was registered after Close")
	}
}

func TestXUDPVisitorRunIsSingleUseAndCloseIsConcurrentSafe(t *testing.T) {
	visitor := newLifecycleXUDPVisitor()
	if err := visitor.Run(); err != nil {
		t.Fatal(err)
	}
	if err := visitor.Run(); err == nil {
		t.Fatal("second Run unexpectedly succeeded")
	}

	const closers = 8
	var wg sync.WaitGroup
	wg.Add(closers)
	for i := 0; i < closers; i++ {
		go func() {
			defer wg.Done()
			visitor.Close()
		}()
	}
	wg.Wait()
	select {
	case <-visitor.closeDone:
	default:
		t.Fatal("concurrent Close calls did not join")
	}
}
