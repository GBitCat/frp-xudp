// XUDP extension: conservative datagram size limit.

package transport

import (
	"errors"
	"fmt"
)

const (
	// DefaultQUICInitialPacketSize is the initial QUIC packet size used during
	// connection setup. It is a QUIC packet size, not an application payload
	// limit.
	DefaultQUICInitialPacketSize = 1200

	// ConservativeXUDPDatagramPayloadLimit is the maximum encoded XUDP
	// application datagram size accepted by the XUDP data plane. The encoded
	// packet, including XUDP framing, must fit within this limit.
	ConservativeXUDPDatagramPayloadLimit = 1200

	// experimentalPathMTUDiscoveryDefault keeps PMTUD disabled in production.
	// The unexported Options switch may enable it only for controlled
	// experiments; it is not a user-facing XUDP configuration.
	experimentalPathMTUDiscoveryDefault = false
)

// ErrDatagramTooLarge identifies a packet-level size rejection. Callers can
// drop the current packet without treating it as a transport failure.
var ErrDatagramTooLarge = errors.New("xudp datagram too large")

func ValidateDatagramSize(size int) error {
	return ValidateDatagramSizeAgainstLimit(size, ConservativeXUDPDatagramPayloadLimit)
}

// ValidateDatagramSizeAgainstLimit validates an already encoded XUDP
// datagram against the payload limit of its transport.
func ValidateDatagramSizeAgainstLimit(size, limit int) error {
	if size > limit {
		return fmt.Errorf("%w: size %d exceeds limit %d", ErrDatagramTooLarge, size, limit)
	}
	return nil
}
