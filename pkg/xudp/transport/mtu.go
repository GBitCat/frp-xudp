// XUDP extension: conservative datagram size limit.

package transport

import (
	"errors"
	"fmt"
)

// DefaultMaxDatagramPayloadSize is a conservative RFC 9221 datagram payload
// limit for XUDP P2P. It leaves room for IPv4/IPv6, UDP, QUIC, connection
// ID, packet number, and AEAD tag headers without relying on IP
// fragmentation.
const DefaultMaxDatagramPayloadSize = 1200

// ErrDatagramTooLarge identifies a packet-level size rejection. Callers can
// drop the current packet without treating it as a transport failure.
var ErrDatagramTooLarge = errors.New("xudp datagram too large")

func ValidateDatagramSize(size int) error {
	if size > DefaultMaxDatagramPayloadSize {
		return fmt.Errorf("%w: size %d exceeds limit %d", ErrDatagramTooLarge, size, DefaultMaxDatagramPayloadSize)
	}
	return nil
}
