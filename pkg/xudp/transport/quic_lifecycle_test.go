package transport

import (
	"context"
	"crypto/tls"
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestQUICAcceptedTransportCloseKeepsListenerSocketOpen(t *testing.T) {
	opts := Options{KeepalivePeriod: time.Second, MaxIdleTimeout: 5 * time.Second}
	serverConn, clientConn, listener, client, server, clientTLS := newQUICLifecyclePair(t, opts)
	defer client.Close()
	defer server.Close()
	defer listener.Close()
	defer serverConn.Close()
	defer clientConn.Close()

	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	if err := client.Close(); err != nil {
		t.Fatal(err)
	}

	secondClientConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatal(err)
	}
	defer secondClientConn.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	acceptedCh := make(chan DatagramTransport, 1)
	acceptErrCh := make(chan error, 1)
	go func() {
		conn, err := listener.Accept(ctx)
		if err != nil {
			acceptErrCh <- err
			return
		}
		acceptedCh <- conn
	}()

	secondClient, err := Dial(ctx, secondClientConn, serverConn.LocalAddr().(*net.UDPAddr), clientTLS, opts)
	if err != nil {
		t.Fatal(err)
	}
	defer secondClient.Close()

	select {
	case secondServer := <-acceptedCh:
		defer secondServer.Close()
		const message = "listener-remains-usable"
		if err := secondClient.SendDatagram([]byte(message)); err != nil {
			t.Fatal(err)
		}
		data, err := secondServer.ReceiveDatagram(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if string(data) != message {
			t.Fatalf("server received %q, want %q", data, message)
		}
	case err := <-acceptErrCh:
		t.Fatal(err)
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
}

func TestQUICTransportCloseRejectsSendAndReceive(t *testing.T) {
	opts := Options{KeepalivePeriod: time.Second, MaxIdleTimeout: 5 * time.Second}
	serverConn, clientConn, listener, client, server, _ := newQUICLifecyclePair(t, opts)
	defer client.Close()
	defer listener.Close()
	defer serverConn.Close()
	defer clientConn.Close()

	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	if err := server.Close(); err != nil {
		t.Fatalf("Close is not idempotent: %v", err)
	}

	if err := server.SendDatagram([]byte("after-close")); !errors.Is(err, net.ErrClosed) {
		t.Fatalf("SendDatagram after Close error = %v, want net.ErrClosed", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := server.ReceiveDatagram(ctx); !errors.Is(err, net.ErrClosed) {
		t.Fatalf("ReceiveDatagram after Close error = %v, want net.ErrClosed", err)
	}
}

func TestQUICTransportConcurrentCloseAndSendIsLinearized(t *testing.T) {
	opts := Options{KeepalivePeriod: time.Second, MaxIdleTimeout: 5 * time.Second}
	serverConn, clientConn, listener, client, server, _ := newQUICLifecyclePair(t, opts)
	defer server.Close()
	defer listener.Close()
	defer serverConn.Close()
	defer clientConn.Close()

	start := make(chan struct{})
	sendErrCh := make(chan error, 1)
	closeErrCh := make(chan error, 1)
	go func() {
		<-start
		sendErrCh <- client.SendDatagram([]byte("concurrent-close-send"))
	}()
	go func() {
		<-start
		closeErrCh <- client.Close()
	}()
	close(start)

	sendErr := <-sendErrCh
	if sendErr != nil && !errors.Is(sendErr, net.ErrClosed) {
		t.Fatalf("concurrent SendDatagram error = %v, want nil or net.ErrClosed", sendErr)
	}
	if err := <-closeErrCh; err != nil {
		t.Fatalf("concurrent Close error = %v", err)
	}
	if err := client.Close(); err != nil {
		t.Fatalf("second Close error = %v", err)
	}
	if err := client.SendDatagram([]byte("after-concurrent-close")); !errors.Is(err, net.ErrClosed) {
		t.Fatalf("SendDatagram after concurrent Close error = %v, want net.ErrClosed", err)
	}
}

func TestQUICTransportCloseUnblocksFullDatagramSendQueue(t *testing.T) {
	opts := Options{KeepalivePeriod: time.Second, MaxIdleTimeout: 30 * time.Second}
	serverConn, clientConn, listener, client, server, _ := newQUICLifecyclePair(t, opts)
	defer listener.Close()
	defer server.Close()
	serverAddr := serverConn.LocalAddr().(*net.UDPAddr)

	// Abruptly remove the peer socket without sending a QUIC close frame. The
	// client remains live long enough for congestion control and quic-go's
	// bounded DATAGRAM queue to stop making progress.
	if err := serverConn.Close(); err != nil {
		t.Fatal(err)
	}

	const senderCount = 256
	payload := make([]byte, ConservativeXUDPDatagramPayloadLimit)
	start := make(chan struct{})
	var releaseOnce sync.Once
	releaseSenders := func() {
		releaseOnce.Do(func() { close(start) })
	}
	var ready atomic.Int32
	var attempted atomic.Int32
	var completed atomic.Int32
	results := make(chan error, senderCount)
	var senders sync.WaitGroup
	senders.Add(senderCount)
	for i := 0; i < senderCount; i++ {
		go func() {
			defer senders.Done()
			ready.Add(1)
			<-start
			// Count after crossing the gate and immediately before entering
			// SendDatagram. Unlike the old pre-gate count, this proves every
			// sender was released and reached its send attempt.
			attempted.Add(1)
			err := client.SendDatagram(payload)
			results <- err
			completed.Add(1)
		}()
	}
	sendersDone := make(chan struct{})
	go func() {
		senders.Wait()
		close(sendersDone)
	}()

	// Always release every sender and close both layers, including when an
	// assertion below fails before the explicit Close under test. Closing the
	// raw socket first gives quic-go an independent way to unwind if Close
	// regresses, and the bounded waits keep cleanup from hanging the test.
	defer func() {
		releaseSenders()
		_ = clientConn.Close()
		cleanupCloseDone := make(chan struct{})
		go func() {
			_ = client.Close()
			close(cleanupCloseDone)
		}()
		select {
		case <-cleanupCloseDone:
		case <-time.After(2 * time.Second):
			t.Errorf("cleanup: client Close did not return")
		}
		select {
		case <-sendersDone:
		case <-time.After(2 * time.Second):
			t.Errorf("cleanup: DATAGRAM senders did not exit")
		}
	}()

	waitForCount := func(counter *atomic.Int32, want int32, timeout time.Duration, description string) {
		t.Helper()
		deadline := time.Now().Add(timeout)
		for counter.Load() != want {
			if time.Now().After(deadline) {
				t.Fatalf("timed out waiting for %s: got %d, want %d", description, counter.Load(), want)
			}
			time.Sleep(time.Millisecond)
		}
	}

	waitForCount(&ready, senderCount, 2*time.Second, "senders to reach the start gate")
	releaseSenders()
	waitForCount(&attempted, senderCount, 2*time.Second, "senders to attempt SendDatagram")

	// Don't infer a full queue from one scheduler snapshot. Require the number
	// of completed sends to remain unchanged and below senderCount for a
	// sustained interval after every sender has attempted SendDatagram.
	const stableWindow = 100 * time.Millisecond
	stabilityDeadline := time.Now().Add(2 * time.Second)
	lastCompleted := completed.Load()
	stableSince := time.Now()
	for {
		current := completed.Load()
		if current == senderCount {
			t.Fatal("all DATAGRAM sends completed; test did not fill the send queue")
		}
		if current != lastCompleted {
			lastCompleted = current
			stableSince = time.Now()
		}
		if time.Since(stableSince) >= stableWindow {
			break
		}
		if time.Now().After(stabilityDeadline) {
			t.Fatalf("DATAGRAM completion count did not stabilize below %d", senderCount)
		}
		time.Sleep(5 * time.Millisecond)
	}

	closeDone := make(chan error, 1)
	go func() { closeDone <- client.Close() }()
	select {
	case err := <-closeDone:
		if err != nil {
			t.Fatalf("Close error = %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Close blocked behind a full DATAGRAM send queue")
	}

	select {
	case <-sendersDone:
	case <-time.After(2 * time.Second):
		t.Fatal("blocked DATAGRAM senders were not released by Close")
	}
	close(results)

	closedErrors := 0
	for err := range results {
		if errors.Is(err, net.ErrClosed) {
			closedErrors++
			continue
		}
		if err != nil {
			t.Fatalf("SendDatagram error = %v, want nil or net.ErrClosed", err)
		}
	}
	if closedErrors == 0 {
		t.Fatal("Close did not interrupt any blocked DATAGRAM sender")
	}
	assertUDPConnClosed(t, clientConn, serverAddr)
}

func TestQUICTransportConcurrentDoubleClose(t *testing.T) {
	opts := Options{KeepalivePeriod: time.Second, MaxIdleTimeout: 5 * time.Second}
	serverConn, clientConn, listener, client, server, _ := newQUICLifecyclePair(t, opts)
	defer server.Close()
	defer listener.Close()
	defer serverConn.Close()
	defer clientConn.Close()

	start := make(chan struct{})
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		go func() {
			<-start
			results <- client.Close()
		}()
	}
	close(start)
	for i := 0; i < 2; i++ {
		if err := <-results; err != nil {
			t.Fatalf("concurrent Close error = %v", err)
		}
	}
	assertUDPConnClosed(t, clientConn, serverConn.LocalAddr().(*net.UDPAddr))
}

func TestQUICTransportCloseUnblocksReceive(t *testing.T) {
	opts := Options{KeepalivePeriod: time.Second, MaxIdleTimeout: 5 * time.Second}
	serverConn, clientConn, listener, client, server, _ := newQUICLifecyclePair(t, opts)
	defer server.Close()
	defer listener.Close()
	defer serverConn.Close()
	defer clientConn.Close()

	receiveDone := make(chan error, 1)
	go func() {
		_, err := client.ReceiveDatagram(context.Background())
		receiveDone <- err
	}()
	time.Sleep(20 * time.Millisecond)

	if err := client.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-receiveDone:
		if !errors.Is(err, net.ErrClosed) {
			t.Fatalf("ReceiveDatagram error = %v, want net.ErrClosed", err)
		}
	case <-time.After(time.Second):
		t.Fatal("ReceiveDatagram was not released by Close")
	}
}

func TestQUICTransportCloseClosesDialSocketAfterRoundTrip(t *testing.T) {
	opts := Options{KeepalivePeriod: time.Second, MaxIdleTimeout: 5 * time.Second}
	serverConn, clientConn, listener, client, server, _ := newQUICLifecyclePair(t, opts)
	serverAddr := serverConn.LocalAddr().(*net.UDPAddr)

	if err := client.SendDatagram([]byte("roundtrip")); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	data, err := server.ReceiveDatagram(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "roundtrip" {
		t.Fatalf("server received %q", data)
	}

	if err := client.Close(); err != nil {
		t.Fatal(err)
	}
	assertUDPConnClosed(t, clientConn, serverAddr)

	// Closing an accepted transport must not tear down the listener's socket;
	// the listener remains the owner of the shared server PacketConn.
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	assertUDPConnClosed(t, serverConn, serverAddr)

	// Both wrappers are deliberately idempotent.
	if err := client.Close(); err != nil {
		t.Fatal(err)
	}
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestQUICDialFailureClosesSocket(t *testing.T) {
	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatal(err)
	}

	_, err = Dial(context.Background(), conn, &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 9}, nil, Options{})
	if err == nil {
		t.Fatal("Dial unexpectedly succeeded with nil TLS config")
	}
	assertUDPConnClosed(t, conn, &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 9})
}

func TestQUICListenFailureClosesSocket(t *testing.T) {
	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatal(err)
	}

	_, err = Listen(conn, nil, Options{})
	if err == nil {
		t.Fatal("Listen unexpectedly succeeded with nil TLS config")
	}
	assertUDPConnClosed(t, conn, &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 9})
}

func newQUICLifecyclePair(t *testing.T, opts Options) (*net.UDPConn, *net.UDPConn, *Listener, DatagramTransport, DatagramTransport, *tls.Config) {
	t.Helper()

	serverConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatal(err)
	}
	clientConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		serverConn.Close()
		t.Fatal(err)
	}

	serverID, err := GenerateIdentity()
	if err != nil {
		serverConn.Close()
		clientConn.Close()
		t.Fatal(err)
	}
	clientID, err := GenerateIdentity()
	if err != nil {
		serverConn.Close()
		clientConn.Close()
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
		serverConn.Close()
		clientConn.Close()
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	acceptedCh := make(chan DatagramTransport, 1)
	acceptErrCh := make(chan error, 1)
	go func() {
		conn, err := listener.Accept(ctx)
		if err != nil {
			acceptErrCh <- err
			return
		}
		acceptedCh <- conn
	}()

	client, err := Dial(ctx, clientConn, serverConn.LocalAddr().(*net.UDPAddr), clientTLS, opts)
	if err != nil {
		listener.Close()
		clientConn.Close()
		t.Fatal(err)
	}

	select {
	case server := <-acceptedCh:
		return serverConn, clientConn, listener, client, server, clientTLS
	case err := <-acceptErrCh:
		listener.Close()
		client.Close()
		t.Fatal(err)
	case <-ctx.Done():
		listener.Close()
		client.Close()
		t.Fatal(ctx.Err())
	}
	return nil, nil, nil, nil, nil, nil
}

func assertUDPConnClosed(t *testing.T, conn *net.UDPConn, target *net.UDPAddr) {
	t.Helper()
	if _, err := conn.WriteToUDP([]byte("closed"), target); err == nil {
		t.Fatal("UDP socket remained writable after owner Close")
	}
}
