package transport

import (
	"context"
	"fmt"
	"net"
	"time"

	quic "github.com/quic-go/quic-go"
)

// RawUDPTransport is a debug/benchmark baseline transport. Production XUDP
// P2P uses QUIC DATAGRAM.
type RawUDPTransport struct {
	conn                   *net.UDPConn
	raddr                  *net.UDPAddr
	maxDatagramPayloadSize int
}

func NewRawUDPTransport(conn *net.UDPConn, raddr *net.UDPAddr, maxDatagramPayloadSize int) DatagramTransport {
	if maxDatagramPayloadSize <= 0 {
		maxDatagramPayloadSize = DefaultMaxDatagramPayloadSize
	}
	return &RawUDPTransport{
		conn:                   conn,
		raddr:                  raddr,
		maxDatagramPayloadSize: maxDatagramPayloadSize,
	}
}

func (t *RawUDPTransport) SendDatagram(p []byte) error {
	if len(p) > t.maxDatagramPayloadSize {
		return fmt.Errorf("raw udp datagram size %d exceeds limit %d", len(p), t.maxDatagramPayloadSize)
	}
	_, err := t.conn.WriteToUDP(p, t.raddr)
	return err
}

func (t *RawUDPTransport) ReceiveDatagram(ctx context.Context) ([]byte, error) {
	buf := make([]byte, 65535)
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}
		_ = t.conn.SetReadDeadline(time.Now().Add(time.Second))
		n, _, err := t.conn.ReadFromUDP(buf)
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				continue
			}
			return nil, err
		}
		return append([]byte(nil), buf[:n]...), nil
	}
}

func (t *RawUDPTransport) MaxDatagramPayloadSize() int {
	return t.maxDatagramPayloadSize
}

func (t *RawUDPTransport) ConnectionState() quic.ConnectionState {
	return quic.ConnectionState{}
}

func (t *RawUDPTransport) Close() error {
	return t.conn.Close()
}

func (t *RawUDPTransport) LocalAddr() net.Addr {
	return t.conn.LocalAddr()
}

func (t *RawUDPTransport) RemoteAddr() net.Addr {
	return t.raddr
}
