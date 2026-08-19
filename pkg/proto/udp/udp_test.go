package udp

import (
	"context"
	"errors"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/fatedier/frp/pkg/msg"
)

func TestManagedForwarderCancelClosesAndJoinsLocalReaders(t *testing.T) {
	echoConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	require.NoError(t, err)
	t.Cleanup(func() { _ = echoConn.Close() })

	echoDone := make(chan struct{})
	go func() {
		defer close(echoDone)
		buf := make([]byte, 2048)
		n, addr, readErr := echoConn.ReadFromUDP(buf)
		if readErr == nil {
			_, _ = echoConn.WriteToUDP(buf[:n], addr)
		}
	}()

	ctx, cancel := context.WithCancel(context.Background())
	readCh := make(chan *msg.UDPPacket, 1)
	sendCh := make(chan msg.Message, 1)
	forwarderDone := make(chan struct{})
	go func() {
		defer close(forwarderDone)
		ManagedForwarder(ctx, echoConn.LocalAddr().(*net.UDPAddr), readCh, sendCh, 1500, "")
	}()

	remoteAddr := &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 31001}
	readCh <- &msg.UDPPacket{Content: []byte("managed"), RemoteAddr: remoteAddr}
	select {
	case raw := <-sendCh:
		packet, ok := raw.(*msg.UDPPacket)
		require.True(t, ok)
		require.Equal(t, []byte("managed"), packet.Content)
		require.Equal(t, remoteAddr.String(), packet.RemoteAddr.String())
	case <-time.After(3 * time.Second):
		t.Fatal("managed forwarder did not return the UDP response")
	}

	cancel()
	select {
	case <-forwarderDone:
	case <-time.After(3 * time.Second):
		t.Fatal("managed forwarder did not close and join its local UDP reader")
	}
	select {
	case <-echoDone:
	case <-time.After(3 * time.Second):
		t.Fatal("echo worker did not exit")
	}
}

type blockingManagedUDPConn struct {
	writeStarted chan struct{}
	closed       chan struct{}
	startOnce    sync.Once
	closeOnce    sync.Once
	mu           sync.Mutex
	closeCount   int
}

func (c *blockingManagedUDPConn) Close() error {
	c.closeOnce.Do(func() {
		c.mu.Lock()
		c.closeCount++
		c.mu.Unlock()
		close(c.closed)
	})
	return nil
}

func (c *blockingManagedUDPConn) ReadFromUDP([]byte) (int, *net.UDPAddr, error) {
	<-c.closed
	return 0, nil, net.ErrClosed
}

func (*blockingManagedUDPConn) SetReadDeadline(time.Time) error { return nil }

func (c *blockingManagedUDPConn) Write([]byte) (int, error) {
	c.startOnce.Do(func() { close(c.writeStarted) })
	<-c.closed
	return 0, net.ErrClosed
}

func (c *blockingManagedUDPConn) closes() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.closeCount
}

func TestManagedForwarderCancelClosesBlockedWriteAndJoinsReader(t *testing.T) {
	conn := &blockingManagedUDPConn{
		writeStarted: make(chan struct{}),
		closed:       make(chan struct{}),
	}
	ctx, cancel := context.WithCancel(context.Background())
	readCh := make(chan *msg.UDPPacket, 1)
	sendCh := make(chan msg.Message, 1)
	readCh <- &msg.UDPPacket{
		Content:    []byte("blocked"),
		RemoteAddr: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 7002},
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		managedForwarder(ctx, &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 7003}, readCh, sendCh, 1500, "",
			func(*net.UDPAddr) (managedUDPConn, error) { return conn, nil })
	}()

	select {
	case <-conn.writeStarted:
	case <-time.After(time.Second):
		t.Fatal("managed forwarder did not enter the blocking Write")
	}
	cancel()

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("managed forwarder did not return after cancellation closed the blocked Write")
	}
	if got := conn.closes(); got != 1 {
		t.Fatalf("managed UDP connection Close count = %d, want 1", got)
	}
}

func TestManagedForwarderClosedReadChannelReturns(t *testing.T) {
	readCh := make(chan *msg.UDPPacket)
	close(readCh)
	done := make(chan struct{})
	go func() {
		defer close(done)
		ManagedForwarder(context.Background(), &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 1}, readCh, make(chan msg.Message), 1500, "")
	}()

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("managed forwarder did not return after readCh closed")
	}
}

func TestManagedForwarderOldReaderCannotRemoveReplacement(t *testing.T) {
	oldConn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)
	newConn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)
	t.Cleanup(func() { _ = oldConn.Close() })
	t.Cleanup(func() { _ = newConn.Close() })

	key := "127.0.0.1:31001"
	oldEntry := &managedConn{conn: oldConn}
	newEntry := &managedConn{conn: newConn}
	mu := sync.Mutex{}
	connections := map[string]*managedConn{key: newEntry}

	// This models the old per-user reader finishing after the dispatcher has
	// already installed a replacement for the same remote address.
	removeManagedConn(&mu, connections, key, oldEntry)
	if connections[key] != newEntry {
		t.Fatal("stale reader removed the replacement UDP connection")
	}
	_, err = oldConn.WriteToUDP([]byte("closed"), oldConn.LocalAddr().(*net.UDPAddr))
	require.Error(t, err, "stale reader cleanup must close its old connection")
	_, err = newConn.WriteToUDP([]byte("open"), newConn.LocalAddr().(*net.UDPAddr))
	require.NoError(t, err, "stale reader cleanup must not close the replacement")
}

func TestUdpPacket(t *testing.T) {
	require := require.New(t)

	buf := []byte("hello world")
	udpMsg := NewUDPPacket(buf, nil, nil)

	newBuf, err := GetContent(udpMsg)
	require.NoError(err)
	require.EqualValues(buf, newBuf)
}

func TestForwardUserConnReturnsWhenSendChannelIsClosed(t *testing.T) {
	listener, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)
	t.Cleanup(func() { _ = listener.Close() })

	readCh := make(chan *msg.UDPPacket)
	sendCh := make(chan *msg.UDPPacket)
	close(sendCh)
	t.Cleanup(func() { close(readCh) })

	done := make(chan struct{})
	go func() {
		ForwardUserConn(listener, readCh, sendCh, 1500)
		close(done)
	}()

	sender, err := net.DialUDP("udp4", nil, listener.LocalAddr().(*net.UDPAddr))
	require.NoError(t, err)
	t.Cleanup(func() { _ = sender.Close() })

	_, err = sender.Write([]byte("trigger"))
	require.NoError(t, err)

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("ForwardUserConn did not return after sending to a closed channel")
	}

	_, err = listener.WriteToUDP([]byte("closed"), sender.LocalAddr().(*net.UDPAddr))
	require.Error(t, err, "ForwardUserConn must close its socket before returning")
}

func TestForwardUserConnBidirectionalAndClosedReadChannel(t *testing.T) {
	listener, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)
	t.Cleanup(func() { _ = listener.Close() })

	readCh := make(chan *msg.UDPPacket)
	sendCh := make(chan *msg.UDPPacket, 1)
	done := make(chan struct{})
	go func() {
		ForwardUserConn(listener, readCh, sendCh, 1500)
		close(done)
	}()

	sender, err := net.DialUDP("udp4", nil, listener.LocalAddr().(*net.UDPAddr))
	require.NoError(t, err)
	t.Cleanup(func() { _ = sender.Close() })

	request := []byte("request")
	_, err = sender.Write(request)
	require.NoError(t, err)

	var pkt *msg.UDPPacket
	select {
	case pkt = <-sendCh:
		require.Equal(t, request, pkt.Content)
	case <-time.After(time.Second):
		t.Fatal("UDP request was not forwarded to sendCh")
	}

	response := []byte("response")
	readCh <- &msg.UDPPacket{Content: response, RemoteAddr: pkt.RemoteAddr}
	require.NoError(t, sender.SetReadDeadline(time.Now().Add(time.Second)))
	buf := make([]byte, 64)
	n, err := sender.Read(buf)
	require.NoError(t, err)
	require.Equal(t, response, buf[:n])

	// Closing readCh stops only the UDP writer. The read side remains usable
	// until the socket is closed.
	close(readCh)
	secondRequest := []byte("after-read-channel-close")
	_, err = sender.Write(secondRequest)
	require.NoError(t, err)
	select {
	case pkt = <-sendCh:
		require.Equal(t, secondRequest, pkt.Content)
	case <-time.After(time.Second):
		t.Fatal("UDP read side stopped when readCh was closed")
	}

	require.NoError(t, listener.Close())
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("ForwardUserConn did not return after its caller closed the socket")
	}
	_, err = listener.WriteToUDP([]byte("closed"), sender.LocalAddr().(*net.UDPAddr))
	require.Error(t, err, "socket must remain closed after the idempotent second Close")
}

func TestForwardUserConnCancelsBlockedWriteBeforeReturning(t *testing.T) {
	conn := newBlockingWriteUserConn()
	readCh := make(chan *msg.UDPPacket, 1)
	readCh <- &msg.UDPPacket{
		Content:    []byte("blocked write"),
		RemoteAddr: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 7000},
	}
	sendCh := make(chan *msg.UDPPacket)
	close(sendCh)

	done := make(chan struct{})
	go func() {
		forwardUserConn(conn, readCh, sendCh, 1500)
		close(done)
	}()

	select {
	case <-conn.writeStarted:
	case <-time.After(time.Second):
		t.Fatal("UDP writer did not enter the blocking WriteToUDP")
	}
	close(conn.allowRead)

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("ForwardUserConn did not cancel and join the blocked UDP writer")
	}

	select {
	case <-conn.writeDone:
	default:
		t.Fatal("ForwardUserConn returned before the UDP writer exited")
	}
	require.Equal(t, 1, conn.closeCount())
}

func TestForwardUserConnRechecksStopAfterReceivingWrite(t *testing.T) {
	conn := newStopRecheckUserConn()
	readCh := make(chan *msg.UDPPacket, 1)
	readCh <- &msg.UDPPacket{
		Content:    []byte("must not be written"),
		RemoteAddr: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 7000},
	}
	sendCh := make(chan *msg.UDPPacket)

	writeDequeued := make(chan struct{})
	releaseWriter := make(chan struct{})
	done := make(chan struct{})
	go func() {
		forwardUserConnWithWriteHook(conn, readCh, sendCh, 1500, func() {
			close(writeDequeued)
			<-releaseWriter
		})
		close(done)
	}()

	select {
	case <-writeDequeued:
	case <-time.After(time.Second):
		t.Fatal("UDP writer did not dequeue the packet")
	}
	close(conn.allowReadReturn)
	select {
	case <-conn.closed:
	case <-time.After(time.Second):
		t.Fatal("ForwardUserConn did not close the socket after the read loop stopped")
	}
	close(releaseWriter)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("ForwardUserConn did not join the stopped writer")
	}
	require.Equal(t, 0, conn.writeCount(), "writer must recheck stop before calling WriteToUDP")
}

type blockingWriteUserConn struct {
	writeStarted chan struct{}
	writeDone    chan struct{}
	allowRead    chan struct{}
	unblockWrite chan struct{}
	startOnce    sync.Once
	doneOnce     sync.Once
	unblockOnce  sync.Once
	mu           sync.Mutex
	closes       int
}

func newBlockingWriteUserConn() *blockingWriteUserConn {
	return &blockingWriteUserConn{
		writeStarted: make(chan struct{}),
		writeDone:    make(chan struct{}),
		allowRead:    make(chan struct{}),
		unblockWrite: make(chan struct{}),
	}
}

func (c *blockingWriteUserConn) ReadFromUDP(buf []byte) (int, *net.UDPAddr, error) {
	<-c.allowRead
	copy(buf, "trigger")
	return len("trigger"), &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 7001}, nil
}

func (c *blockingWriteUserConn) WriteToUDP([]byte, *net.UDPAddr) (int, error) {
	c.startOnce.Do(func() { close(c.writeStarted) })
	<-c.unblockWrite
	c.doneOnce.Do(func() { close(c.writeDone) })
	return 0, timeoutError{}
}

func (c *blockingWriteUserConn) Close() error {
	c.mu.Lock()
	c.closes++
	c.mu.Unlock()
	c.unblockOnce.Do(func() { close(c.unblockWrite) })
	return nil
}

func (c *blockingWriteUserConn) closeCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.closes
}

type stopRecheckUserConn struct {
	allowReadReturn chan struct{}
	closed          chan struct{}
	closeOnce       sync.Once
	mu              sync.Mutex
	writes          int
}

func newStopRecheckUserConn() *stopRecheckUserConn {
	return &stopRecheckUserConn{
		allowReadReturn: make(chan struct{}),
		closed:          make(chan struct{}),
	}
}

func (c *stopRecheckUserConn) ReadFromUDP([]byte) (int, *net.UDPAddr, error) {
	<-c.allowReadReturn
	return 0, nil, errors.New("read stopped")
}

func (c *stopRecheckUserConn) WriteToUDP([]byte, *net.UDPAddr) (int, error) {
	c.mu.Lock()
	c.writes++
	c.mu.Unlock()
	return 0, nil
}

func (c *stopRecheckUserConn) Close() error {
	c.closeOnce.Do(func() { close(c.closed) })
	return nil
}

func (c *stopRecheckUserConn) writeCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.writes
}

type timeoutError struct{}

func (timeoutError) Error() string   { return "i/o timeout" }
func (timeoutError) Timeout() bool   { return true }
func (timeoutError) Temporary() bool { return true }
