package transport

import (
	"crypto/tls"
	"testing"
)

func TestGenerateIdentity(t *testing.T) {
	t.Parallel()

	id, err := GenerateIdentity()
	if err != nil {
		t.Fatalf("GenerateIdentity() error = %v", err)
	}
	if id == nil {
		t.Fatal("GenerateIdentity() returned nil")
	}
	if id.Fingerprint() == "" {
		t.Fatal("identity fingerprint is empty")
	}
	if len(id.cert.Certificate) != 1 {
		t.Fatalf("identity certificate chain length = %d, want 1", len(id.cert.Certificate))
	}
}

func TestXUDPServerTLSConfig(t *testing.T) {
	t.Parallel()

	id, err := GenerateIdentity()
	if err != nil {
		t.Fatalf("GenerateIdentity() error = %v", err)
	}
	cfg, err := ServerTLSConfig(id, "expected-client")
	if err != nil {
		t.Fatalf("ServerTLSConfig() error = %v", err)
	}
	if cfg.MinVersion != tls.VersionTLS13 {
		t.Fatalf("MinVersion = %x, want %x", cfg.MinVersion, tls.VersionTLS13)
	}
	if cfg.ClientAuth != tls.RequireAnyClientCert {
		t.Fatalf("ClientAuth = %v, want RequireAnyClientCert", cfg.ClientAuth)
	}
	if len(cfg.Certificates) != 1 {
		t.Fatalf("server certificate count = %d, want 1", len(cfg.Certificates))
	}
	if _, err := ServerTLSConfig(id, ""); err == nil {
		t.Fatal("ServerTLSConfig() accepted empty expected fingerprint")
	}
}

func TestXUDPClientTLSConfig(t *testing.T) {
	t.Parallel()

	id, err := GenerateIdentity()
	if err != nil {
		t.Fatalf("GenerateIdentity() error = %v", err)
	}
	cfg, err := ClientTLSConfig(id, "expected-server")
	if err != nil {
		t.Fatalf("ClientTLSConfig() error = %v", err)
	}
	if cfg.MinVersion != tls.VersionTLS13 {
		t.Fatalf("MinVersion = %x, want %x", cfg.MinVersion, tls.VersionTLS13)
	}
	if !cfg.InsecureSkipVerify {
		t.Fatal("InsecureSkipVerify = false, want true with fingerprint pin")
	}
	if len(cfg.Certificates) != 1 {
		t.Fatalf("client certificate count = %d, want 1", len(cfg.Certificates))
	}
	if _, err := ClientTLSConfig(id, ""); err == nil {
		t.Fatal("ClientTLSConfig() accepted empty expected fingerprint")
	}
}

func TestVerifyFingerprint(t *testing.T) {
	t.Parallel()

	id, err := GenerateIdentity()
	if err != nil {
		t.Fatalf("GenerateIdentity() error = %v", err)
	}
	raw := id.cert.Certificate
	if err := verifyFingerprint(id.Fingerprint(), raw); err != nil {
		t.Fatalf("verifyFingerprint() matching fingerprint error = %v", err)
	}
	if err := verifyFingerprint("00", raw); err == nil {
		t.Fatal("verifyFingerprint() accepted mismatched fingerprint")
	}
	if err := verifyFingerprint(id.Fingerprint(), nil); err == nil {
		t.Fatal("verifyFingerprint() accepted missing certificate")
	}
}
