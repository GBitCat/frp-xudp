package transport

import (
	"context"
	"net"
	"testing"
	"time"
)

func TestExperimentalPMTUDLoopbackDatagramComparison(t *testing.T) {
	t.Parallel()

	// This is a loopback control test for switch wiring and transport
	// interoperability. quic-go does not expose a reliable measured path MTU
	// through this transport API, so this test intentionally makes no MTU
	// measurement claim.
	for _, tc := range []struct {
		name                   string
		enablePathMTUDiscovery bool
		wantDisablePMTUD       bool
	}{
		{
			name:                   "off",
			enablePathMTUDiscovery: false,
			wantDisablePMTUD:       true,
		},
		{
			name:                   "on-experiment",
			enablePathMTUDiscovery: true,
			wantDisablePMTUD:       false,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			opts := Options{
				KeepalivePeriod:        time.Second,
				MaxIdleTimeout:         5 * time.Second,
				enablePathMTUDiscovery: tc.enablePathMTUDiscovery,
			}
			cfg := opts.quicConfig()
			if cfg.DisablePathMTUDiscovery != tc.wantDisablePMTUD {
				t.Fatalf("DisablePathMTUDiscovery = %t, want %t", cfg.DisablePathMTUDiscovery, tc.wantDisablePMTUD)
			}

			runLoopbackDatagramRoundTrip(t, opts)
		})
	}
}

func runLoopbackDatagramRoundTrip(t *testing.T, opts Options) {
	t.Helper()

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

		const clientMessage = "pmtud-loopback-client-to-server"
		if err := client.SendDatagram([]byte(clientMessage)); err != nil {
			t.Fatal(err)
		}
		data, err := server.ReceiveDatagram(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if string(data) != clientMessage {
			t.Fatalf("server received %q, want %q", data, clientMessage)
		}

		const serverMessage = "pmtud-loopback-server-to-client"
		if err := server.SendDatagram([]byte(serverMessage)); err != nil {
			t.Fatal(err)
		}
		data, err = client.ReceiveDatagram(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if string(data) != serverMessage {
			t.Fatalf("client received %q, want %q", data, serverMessage)
		}
	case err := <-acceptErrCh:
		t.Fatal(err)
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
}
