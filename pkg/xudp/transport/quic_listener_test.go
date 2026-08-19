package transport

import (
	"context"
	"net"
	"testing"
	"time"
)

func TestQUICListenerCloseUnblocksAccept(t *testing.T) {
	t.Parallel()

	serverConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatal(err)
	}
	defer serverConn.Close()

	serverID, err := GenerateIdentity()
	if err != nil {
		t.Fatal(err)
	}
	clientID, err := GenerateIdentity()
	if err != nil {
		t.Fatal(err)
	}
	serverTLS, err := ServerTLSConfig(serverID, clientID.Fingerprint())
	if err != nil {
		t.Fatal(err)
	}

	listener, err := Listen(serverConn, serverTLS, Options{
		KeepalivePeriod: time.Second,
		MaxIdleTimeout:  5 * time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}

	acceptCh := make(chan error, 1)
	go func() {
		conn, err := listener.Accept(context.Background())
		if err == nil {
			_ = conn.Close()
		}
		acceptCh <- err
	}()

	time.Sleep(50 * time.Millisecond)
	_ = listener.Close()
	assertUDPConnClosed(t, serverConn, serverConn.LocalAddr().(*net.UDPAddr))

	select {
	case err := <-acceptCh:
		if err == nil {
			t.Fatal("Accept returned nil after listener close")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Accept remained blocked after listener close")
	}
}
