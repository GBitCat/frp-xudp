package transport

import (
	"bytes"
	"errors"
	"net"
	"testing"

	"github.com/fatedier/frp/pkg/msg"
)

func TestValidateDatagramSize(t *testing.T) {
	t.Parallel()

	if err := ValidateDatagramSize(ConservativeXUDPDatagramPayloadLimit - 1); err != nil {
		t.Fatalf("ValidateDatagramSize(%d) error = %v", ConservativeXUDPDatagramPayloadLimit-1, err)
	}
	if err := ValidateDatagramSize(ConservativeXUDPDatagramPayloadLimit); err != nil {
		t.Fatalf("ValidateDatagramSize(%d) error = %v", ConservativeXUDPDatagramPayloadLimit, err)
	}
	err := ValidateDatagramSize(ConservativeXUDPDatagramPayloadLimit + 1)
	if err == nil {
		t.Fatal("ValidateDatagramSize() accepted oversized datagram")
	}
	if !errors.Is(err, ErrDatagramTooLarge) {
		t.Fatalf("ValidateDatagramSize() error = %v, want ErrDatagramTooLarge", err)
	}
}

func TestQUICConfigUsesConservativeInitialPacketSize(t *testing.T) {
	t.Parallel()

	cfg := (Options{KeepalivePeriod: 10e9, MaxIdleTimeout: 30e9}).quicConfig()
	if cfg.InitialPacketSize != DefaultQUICInitialPacketSize {
		t.Fatalf("InitialPacketSize = %d, want %d", cfg.InitialPacketSize, DefaultQUICInitialPacketSize)
	}
	if !cfg.DisablePathMTUDiscovery {
		t.Fatal("DisablePathMTUDiscovery = false, want true for conservative datagram sizing")
	}
}

func TestEncodedUDPPacketSizeBoundaries(t *testing.T) {
	t.Parallel()

	for _, tc := range []struct {
		name string
		addr *net.UDPAddr
	}{
		{name: "ipv4", addr: &net.UDPAddr{IP: net.ParseIP("203.0.113.9"), Port: 54321}},
		{name: "ipv6", addr: &net.UDPAddr{IP: net.ParseIP("2001:db8::9"), Port: 54321}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for _, wantSize := range []int{
				ConservativeXUDPDatagramPayloadLimit - 1,
				ConservativeXUDPDatagramPayloadLimit,
				ConservativeXUDPDatagramPayloadLimit + 1,
			} {
				base := &msg.UDPPacket{RemoteAddr: tc.addr}
				encodedBase, err := msg.EncodeUDPPacketBinary(base)
				if err != nil {
					t.Fatal(err)
				}
				baseSize := len(encodedBase)
				packet := &msg.UDPPacket{
					Content:    bytes.Repeat([]byte{0xa5}, wantSize-baseSize),
					RemoteAddr: tc.addr,
				}
				encoded, err := msg.EncodeUDPPacketBinary(packet)
				if err != nil {
					t.Fatalf("encode target %d: %v", wantSize, err)
				}
				if len(encoded) != wantSize {
					t.Fatalf("encoded size = %d, want %d", len(encoded), wantSize)
				}
				err = ValidateDatagramSizeAgainstLimit(len(encoded), ConservativeXUDPDatagramPayloadLimit)
				if wantSize <= ConservativeXUDPDatagramPayloadLimit && err != nil {
					t.Fatalf("encoded size %d rejected: %v", wantSize, err)
				}
				if wantSize > ConservativeXUDPDatagramPayloadLimit && !errors.Is(err, ErrDatagramTooLarge) {
					t.Fatalf("encoded size %d error = %v, want ErrDatagramTooLarge", wantSize, err)
				}
			}
		})
	}
}
