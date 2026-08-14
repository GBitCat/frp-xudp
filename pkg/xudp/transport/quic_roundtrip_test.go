package transport

import (
	"context"
	"net"
	"testing"
	"time"
)

func TestQUICDatagramTransportRoundTrip(t *testing.T) {
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

	serverAddr := serverConn.LocalAddr().(*net.UDPAddr)
	client, err := Dial(ctx, clientConn, serverAddr, clientTLS, opts)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	select {
	case server := <-acceptCh:
		defer server.Close()
		if err := client.SendDatagram([]byte("client->server")); err != nil {
			t.Fatal(err)
		}
		data, err := server.ReceiveDatagram(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if string(data) != "client->server" {
			t.Fatalf("server received %q", data)
		}

		if err := server.SendDatagram([]byte("server->client")); err != nil {
			t.Fatal(err)
		}
		data, err = client.ReceiveDatagram(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if string(data) != "server->client" {
			t.Fatalf("client received %q", data)
		}
	case err := <-acceptErrCh:
		t.Fatal(err)
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
}
