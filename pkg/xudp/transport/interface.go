package transport

import (
	"context"
	"net"

	quic "github.com/quic-go/quic-go"
)

// DatagramTransport is the small transport abstraction used by XUDP P2P.
// Production uses QUIC DATAGRAM. A raw UDP implementation can be used for
// baseline benchmarks and debugging.
type DatagramTransport interface {
	SendDatagram([]byte) error
	ReceiveDatagram(context.Context) ([]byte, error)
	MaxDatagramPayloadSize() int
	ConnectionState() quic.ConnectionState
	Close() error
	LocalAddr() net.Addr
	RemoteAddr() net.Addr
}
