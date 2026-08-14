package transport

import (
	"context"
	"net"
	"testing"
	"time"
)

func TestQUICPeerAuthenticationRejectsWrongClient(t *testing.T) {
	t.Parallel()

	serverConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatal(err)
	}
	defer serverConn.Close()

	clientConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatal(err)
	}
	defer clientConn.Close()

	serverID, err := GenerateIdentity()
	if err != nil {
		t.Fatal(err)
	}
	clientID, err := GenerateIdentity()
	if err != nil {
		t.Fatal(err)
	}
	wrongID, err := GenerateIdentity()
	if err != nil {
		t.Fatal(err)
	}

	serverTLS, err := ServerTLSConfig(serverID, clientID.Fingerprint())
	if err != nil {
		t.Fatal(err)
	}
	clientTLS, err := ClientTLSConfig(clientID, serverID.Fingerprint())
	if err != nil {
		t.Fatal(err)
	}

	opts := Options{
		KeepalivePeriod: time.Second,
		MaxIdleTimeout:  5 * time.Second,
	}
	listener, err := Listen(serverConn, serverTLS, opts)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	acceptCh := make(chan DatagramTransport, 1)
	acceptErrCh := make(chan error, 1)
	go func() {
		conn, err := listener.Accept(ctx)
		if err != nil {
			acceptErrCh <- err
			return
		}
		acceptCh <- conn
	}()

	client, err := Dial(ctx, clientConn, serverConn.LocalAddr().(*net.UDPAddr), clientTLS, opts)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	select {
	case server := <-acceptCh:
		defer server.Close()
		if err := server.VerifyPeerFingerprint(clientID.Fingerprint()); err != nil {
			t.Fatalf("server rejected matching client fingerprint: %v", err)
		}
		if err := server.VerifyPeerFingerprint(wrongID.Fingerprint()); err == nil {
			t.Fatal("server accepted mismatched client fingerprint")
		}
	case err := <-acceptErrCh:
		t.Fatal(err)
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
}
