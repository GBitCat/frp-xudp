// XUDP extension: conservative datagram size limit.

package transport

import "fmt"

// DefaultMaxDatagramPayloadSize is a conservative RFC 9221 datagram payload
// limit for XUDP P2P. It leaves room for IPv4/IPv6, UDP, QUIC, connection
// ID, packet number, and AEAD tag headers without relying on IP
// fragmentation.
const DefaultMaxDatagramPayloadSize = 1200

func ValidateDatagramSize(size int) error {
	if size > DefaultMaxDatagramPayloadSize {
		return fmt.Errorf("xudp datagram size %d exceeds limit %d", size, DefaultMaxDatagramPayloadSize)
	}
	return nil
}
