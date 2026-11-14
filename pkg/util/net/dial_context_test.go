package net

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestDialWithContextClosesLateConnection(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	entered, release := make(chan struct{}), make(chan struct{})
	local, remote := net.Pipe()
	t.Cleanup(func() { _ = remote.Close() })
	done := make(chan error, 1)
	go func() {
		_, err := DialWithContext(ctx, func() (net.Conn, error) {
			close(entered)
			<-release
			return local, nil
		})
		done <- err
	}()
	<-entered
	cancel()
	select {
	case err := <-done:
		require.ErrorIs(t, err, context.Canceled)
	case <-time.After(time.Second):
		t.Fatal("dial cancellation remained blocked")
	}
	close(release)
	_ = remote.SetReadDeadline(time.Now().Add(time.Second))
	_, err := remote.Read(make([]byte, 1))
	require.Error(t, err)
	if timeout, ok := err.(net.Error); ok {
		require.False(t, timeout.Timeout())
	}
}

func TestDialWithContextTransfersSuccessfulConnection(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	local, remote := net.Pipe()
	t.Cleanup(func() { _ = local.Close(); _ = remote.Close() })
	conn, err := DialWithContext(ctx, func() (net.Conn, error) { return local, nil })
	require.NoError(t, err)
	require.Same(t, local, conn)
	cancel()
	// After successful handoff, the caller owns the connection independently
	// of the setup context.
	go func() { _, _ = remote.Write([]byte{1}) }()
	require.NoError(t, conn.SetReadDeadline(time.Now().Add(time.Second)))
	_, err = conn.Read(make([]byte, 1))
	require.NoError(t, err)
}
