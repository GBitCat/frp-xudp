package transport

import (
	"bytes"
	"context"
	"errors"
	"net"
	"testing"
	"time"
)

func TestQUICOversizedDatagramKeepsConnection(t *testing.T) {
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
	serverTLS, err := ServerTLSConfig(serverID, clientID.Fingerprint())
	if err != nil {
		t.Fatal(err)
	}
	clientTLS, err := ClientTLSConfig(clientID, serverID.Fingerprint())
	if err != nil {
		t.Fatal(err)
	}
	opts := Options{KeepalivePeriod: time.Second, MaxIdleTimeout: 5 * time.Second}
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

	var server DatagramTransport
	select {
	case server = <-acceptCh:
		defer server.Close()
	case err := <-acceptErrCh:
		t.Fatal(err)
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}

	limit := client.MaxDatagramPayloadSize()
	err = client.SendDatagram(make([]byte, limit+1))
	if !errors.Is(err, ErrDatagramTooLarge) {
		t.Fatalf("oversized SendDatagram() error = %v, want ErrDatagramTooLarge", err)
	}

	small := []byte("after-oversize")
	if err := client.SendDatagram(small); err != nil {
		t.Fatalf("small SendDatagram() after oversized packet: %v", err)
	}
	received, err := server.ReceiveDatagram(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(received, small) {
		t.Fatalf("received %q, want %q", received, small)
	}
}
