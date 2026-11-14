package net

import (
	"context"
	"net"
)

// DialWithContext adapts a dialer that has no cancellation API. Cancellation
// releases the caller immediately; the producer owns and closes any late
// connection. Prefer a native context-aware dialer when one is available.
func DialWithContext(ctx context.Context, dial func() (net.Conn, error)) (net.Conn, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if ctx.Done() == nil {
		return dial()
	}
	type result struct {
		conn net.Conn
		err  error
	}
	results := make(chan result)
	go func() {
		conn, err := dial()
		select {
		case results <- result{conn: conn, err: err}:
		case <-ctx.Done():
			if conn != nil {
				_ = conn.Close()
			}
		}
	}()
	select {
	case result := <-results:
		if err := ctx.Err(); err != nil {
			if result.conn != nil {
				_ = result.conn.Close()
			}
			return nil, err
		}
		return result.conn, result.err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}
