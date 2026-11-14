package visitor

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/fatedier/frp/pkg/msg"
	xudptransport "github.com/fatedier/frp/pkg/xudp/transport"
)

type pendingRelayHelper struct {
	Helper
	conn     *msg.Conn
	entered  chan struct{}
	release  chan struct{}
	returned chan struct{}
}

func (h *pendingRelayHelper) RunID() string { return "pending-relay" }

func (h *pendingRelayHelper) ConnectServer() (*msg.Conn, error) {
	if h.entered != nil {
		close(h.entered)
	}
	if h.release != nil {
		<-h.release
	}
	if h.returned != nil {
		close(h.returned)
	}
	return h.conn, nil
}

func TestXUDPVisitorCloseCancelsRelaySetup(t *testing.T) {
	for _, phase := range []string{"connect", "context-connect", "write-request", "read-response"} {
		t.Run(phase, func(t *testing.T) {
			v := newLifecycleXUDPVisitor()
			v.p2PDialer = func(uint64) (xudptransport.DatagramTransport, bool) { return nil, false }
			local, remote := net.Pipe()
			t.Cleanup(func() { _ = remote.Close() })
			h := &pendingRelayHelper{conn: msg.NewConn(local, msg.NewV1ReadWriter(local))}
			v.helper = h
			entered := make(chan struct{})
			switch phase {
			case "connect", "context-connect":
				h.entered = entered
				h.release = make(chan struct{})
				h.returned = make(chan struct{})
				defer close(h.release)
				if phase == "context-connect" {
					v.helper = &visitorHelperImpl{connectServerContextFn: func(context.Context) (*msg.Conn, error) {
						return h.ConnectServer()
					}}
				}
			case "write-request":
				h.entered = entered
			default:
				go func() {
					var request msg.NewVisitorConn
					_ = msg.NewConn(remote, msg.NewV1ReadWriter(remote)).ReadMsgInto(&request)
					close(entered)
				}()
			}
			if err := v.Run(); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(v.Close)
			v.sendCh <- &msg.UDPPacket{Content: []byte("request"), RemoteAddr: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 12345}}
			waitXUDPChannel(t, entered, "relay setup")
			done := make(chan struct{})
			go func() { v.Close(); close(done) }()
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("Close remained blocked on relay setup")
			}
			if phase == "connect" || phase == "context-connect" {
				// Let the legacy dial return after Close. No handshake should be
				// started and its late connection must still be closed.
				h.release <- struct{}{}
				waitXUDPChannel(t, h.returned, "late dial return")
			}
			_ = remote.SetReadDeadline(time.Now().Add(time.Second))
			if _, err := remote.Read(make([]byte, 4096)); err == nil {
				t.Fatal("setup connection remained open after Close")
			} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
				t.Fatal("Close did not close setup connection")
			}
		})
	}
}

func TestXUDPVisitorPassesCancellationToContextHelper(t *testing.T) {
	entered, canceled := make(chan struct{}), make(chan struct{})
	v := newLifecycleXUDPVisitor()
	v.p2PDialer = func(uint64) (xudptransport.DatagramTransport, bool) { return nil, false }
	v.helper = &visitorHelperImpl{connectServerContextFn: func(ctx context.Context) (*msg.Conn, error) {
		close(entered)
		<-ctx.Done()
		close(canceled)
		return nil, ctx.Err()
	}}
	if err := v.Run(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(v.Close)
	v.sendCh <- &msg.UDPPacket{Content: []byte("request")}
	waitXUDPChannel(t, entered, "context-aware relay dial")
	v.Close()
	waitXUDPChannel(t, canceled, "relay dial cancellation")
}
