package transport

import (
	"testing"
	"time"

	v1 "github.com/fatedier/frp/pkg/config/v1"
)

func TestOptionsFromClientCfg(t *testing.T) {
	t.Parallel()

	cfg := &v1.ClientCommonConfig{}
	cfg.Transport.QUIC.KeepalivePeriod = 20
	cfg.Transport.QUIC.MaxIdleTimeout = 45

	opts := OptionsFromClientCfg(cfg)
	if opts.KeepalivePeriod != 20*time.Second {
		t.Fatalf("KeepalivePeriod = %s, want %s", opts.KeepalivePeriod, 20*time.Second)
	}
	if opts.MaxIdleTimeout != 45*time.Second {
		t.Fatalf("MaxIdleTimeout = %s, want %s", opts.MaxIdleTimeout, 45*time.Second)
	}
}

func TestOptionsFromClientCfgNil(t *testing.T) {
	t.Parallel()

	opts := OptionsFromClientCfg(nil)
	if opts.KeepalivePeriod != defaultKeepalivePeriod {
		t.Fatalf("KeepalivePeriod = %s, want %s", opts.KeepalivePeriod, defaultKeepalivePeriod)
	}
	if opts.MaxIdleTimeout != defaultMaxIdleTimeout {
		t.Fatalf("MaxIdleTimeout = %s, want %s", opts.MaxIdleTimeout, defaultMaxIdleTimeout)
	}
}

func TestQuicConfigForDatagramOnlyTransport(t *testing.T) {
	t.Parallel()

	cfg := (Options{KeepalivePeriod: 12 * time.Second, MaxIdleTimeout: 34 * time.Second}).quicConfig()
	if !cfg.EnableDatagrams {
		t.Fatal("EnableDatagrams = false, want true")
	}
	if cfg.MaxIncomingStreams != -1 {
		t.Fatalf("MaxIncomingStreams = %d, want -1", cfg.MaxIncomingStreams)
	}
	if cfg.MaxIncomingUniStreams != -1 {
		t.Fatalf("MaxIncomingUniStreams = %d, want -1", cfg.MaxIncomingUniStreams)
	}
	if cfg.KeepAlivePeriod != 12*time.Second {
		t.Fatalf("KeepAlivePeriod = %s, want %s", cfg.KeepAlivePeriod, 12*time.Second)
	}
	if cfg.MaxIdleTimeout != 34*time.Second {
		t.Fatalf("MaxIdleTimeout = %s, want %s", cfg.MaxIdleTimeout, 34*time.Second)
	}
}
