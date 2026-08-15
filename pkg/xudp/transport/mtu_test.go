package transport

import (
	"errors"
	"testing"
)

func TestValidateDatagramSize(t *testing.T) {
	t.Parallel()

	if err := ValidateDatagramSize(DefaultMaxDatagramPayloadSize - 1); err != nil {
		t.Fatalf("ValidateDatagramSize(%d) error = %v", DefaultMaxDatagramPayloadSize-1, err)
	}
	if err := ValidateDatagramSize(DefaultMaxDatagramPayloadSize); err != nil {
		t.Fatalf("ValidateDatagramSize(%d) error = %v", DefaultMaxDatagramPayloadSize, err)
	}
	err := ValidateDatagramSize(DefaultMaxDatagramPayloadSize + 1)
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
	if cfg.InitialPacketSize != DefaultMaxDatagramPayloadSize {
		t.Fatalf("InitialPacketSize = %d, want %d", cfg.InitialPacketSize, DefaultMaxDatagramPayloadSize)
	}
	if !cfg.DisablePathMTUDiscovery {
		t.Fatal("DisablePathMTUDiscovery = false, want true for conservative datagram sizing")
	}
}
