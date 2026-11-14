package client

import (
	"context"
	"io"
	"net"
	"testing"
	"time"

	quic "github.com/quic-go/quic-go"
	"github.com/stretchr/testify/require"

	"github.com/fatedier/frp/pkg/msg"
	xudptransport "github.com/fatedier/frp/pkg/xudp/transport"
)

func TestMessageConnectorQUICStreamWaitCancellation(t *testing.T) {
	for _, cancelSource := range []string{"caller", "parent"} {
		t.Run(cancelSource, func(t *testing.T) {
			serverIdentity, err := xudptransport.GenerateIdentity()
			require.NoError(t, err)
			clientIdentity, err := xudptransport.GenerateIdentity()
			require.NoError(t, err)
			serverTLS, err := xudptransport.ServerTLSConfig(serverIdentity, clientIdentity.Fingerprint())
			require.NoError(t, err)
			clientTLS, err := xudptransport.ClientTLSConfig(clientIdentity, serverIdentity.Fingerprint())
			require.NoError(t, err)
			listener, err := quic.ListenAddr("127.0.0.1:0", serverTLS, &quic.Config{MaxIncomingStreams: 1})
			require.NoError(t, err)
			t.Cleanup(func() { _ = listener.Close() })
			setupCtx, cancelSetup := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancelSetup()
			conn, err := quic.DialAddr(setupCtx, listener.Addr().String(), clientTLS, &quic.Config{})
			require.NoError(t, err)
			t.Cleanup(func() { _ = conn.CloseWithError(0, "") })
			server, err := listener.Accept(setupCtx)
			require.NoError(t, err)
			t.Cleanup(func() { _ = server.CloseWithError(0, "") })
			parent, cancelParent := context.WithCancel(context.Background())
			defer cancelParent()
			connector := newMessageConnector(&defaultConnectorImpl{ctx: parent, quicConn: conn}, "")
			first, err := connector.Connect()
			require.NoError(t, err)
			t.Cleanup(func() { _ = first.Close() })
			_, err = first.Write([]byte{1})
			require.NoError(t, err)
			incoming, err := server.AcceptStream(setupCtx)
			require.NoError(t, err)
			buffer := make([]byte, 1)
			_, err = io.ReadFull(incoming, buffer)
			require.NoError(t, err)
			caller, cancelCaller := context.WithCancel(context.Background())
			defer cancelCaller()
			done := make(chan error, 1)
			go func() {
				var pending *msg.Conn
				var err error
				if cancelSource == "parent" {
					pending, err = connector.Connect()
				} else {
					pending, err = connector.ConnectContext(caller)
				}
				if pending != nil {
					_ = pending.Close()
				}
				done <- err
			}()
			select {
			case err := <-done:
				t.Fatalf("stream quota did not block second dial: %v", err)
			case <-time.After(50 * time.Millisecond):
			}
			if cancelSource == "parent" {
				cancelParent()
			} else {
				cancelCaller()
			}
			select {
			case err := <-done:
				require.ErrorIs(t, err, context.Canceled)
			case <-time.After(time.Second):
				t.Fatal("QUIC stream wait ignored cancellation")
			}
			// Canceling one setup must leave the shared connection and already
			// established streams usable for other visitors.
			_, err = first.Write([]byte{2})
			require.NoError(t, err)
			require.NoError(t, incoming.SetReadDeadline(time.Now().Add(time.Second)))
			_, err = io.ReadFull(incoming, buffer)
			require.NoError(t, err)
			require.Equal(t, byte(2), buffer[0])
		})
	}
}

type contextTestConnector struct{ conn net.Conn }

func (*contextTestConnector) Open() error                  { return nil }
func (c *contextTestConnector) Connect() (net.Conn, error) { return c.conn, nil }
func (*contextTestConnector) Close() error                 { return nil }

func TestMessageConnectorCancelsWireMagicWrite(t *testing.T) {
	local, remote := net.Pipe()
	t.Cleanup(func() { _ = remote.Close() })
	connector := newMessageConnector(&contextTestConnector{conn: local}, "v2")
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := connector.ConnectContext(ctx); done <- err }()
	select {
	case err := <-done:
		require.Error(t, err)
	case <-time.After(time.Second):
		t.Fatal("wire magic write ignored cancellation")
	}
	_ = remote.SetReadDeadline(time.Now().Add(time.Second))
	_, err := remote.Read(make([]byte, 1))
	require.ErrorIs(t, err, io.EOF)
}
