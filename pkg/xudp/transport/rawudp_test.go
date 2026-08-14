package transport

import (
	"context"
	"net"
	"testing"
	"time"
)

func TestRawUDPTransportRoundTrip(t *testing.T) {
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

	client := NewRawUDPTransport(clientConn, serverConn.LocalAddr().(*net.UDPAddr), 1200)
	server := NewRawUDPTransport(serverConn, clientConn.LocalAddr().(*net.UDPAddr), 1200)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	if err := client.SendDatagram([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	data, err := server.ReceiveDatagram(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "hello" {
		t.Fatalf("received %q, want hello", data)
	}
}
