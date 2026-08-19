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
	// application datagram size accepted by the XUDP data plane. It is lower
	// than the 1200-byte QUIC packet minimum because the encoded datagram still
	// needs room for UDP, QUIC, connection ID, packet number, and AEAD overhead.
	// PMTUD experiments may measure a larger path-specific ceiling, but the
	// production default remains a fixed conservative limit.
	ConservativeXUDPDatagramPayloadLimit = 1150
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
