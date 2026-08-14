// XUDP extension: ephemeral peer identity for QUIC DATAGRAM authentication.

package transport

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"math/big"
	"time"
)

// Identity is an ephemeral self-signed certificate used by one XUDP peer.
// The SHA-256 fingerprint is exchanged over the already authenticated FRP
// NAT-hole control channel before QUIC starts.
type Identity struct {
	cert        tls.Certificate
	fingerprint string
}

func GenerateIdentity() (*Identity, error) {
	cert, der, err := generateSelfSignedCert()
	if err != nil {
		return nil, err
	}
	return &Identity{
		cert:        cert,
		fingerprint: certFingerprint(der),
	}, nil
}

func (id *Identity) Fingerprint() string {
	return id.fingerprint
}

func ServerTLSConfig(id *Identity, expectedClientFingerprint string) (*tls.Config, error) {
	if id == nil {
		return nil, fmt.Errorf("nil quic identity")
	}
	if expectedClientFingerprint == "" {
		return nil, fmt.Errorf("missing expected client fingerprint")
	}
	return &tls.Config{
		Certificates: []tls.Certificate{id.cert},
		MinVersion:   tls.VersionTLS13,
		NextProtos:   []string{"xudp"},
		ClientAuth:   tls.RequireAnyClientCert,
		VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			return verifyFingerprint(expectedClientFingerprint, rawCerts)
		},
	}, nil
}

func ClientTLSConfig(id *Identity, expectedServerFingerprint string) (*tls.Config, error) {
	if id == nil {
		return nil, fmt.Errorf("nil quic identity")
	}
	if expectedServerFingerprint == "" {
		return nil, fmt.Errorf("missing expected server fingerprint")
	}
	return &tls.Config{
		Certificates: []tls.Certificate{id.cert},
		MinVersion:   tls.VersionTLS13,
		ServerName:   "xudp",
		NextProtos:   []string{"xudp"},
		// Standard PKI verification is intentionally replaced by the
		// fingerprint pin below. The pin comes from the authenticated FRP
		// NAT-hole exchange, so this is not an unauthenticated TLS dial.
		InsecureSkipVerify: true,
		VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			return verifyFingerprint(expectedServerFingerprint, rawCerts)
		},
	}, nil
}

func generateSelfSignedCert() (tls.Certificate, []byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, nil, fmt.Errorf("generate key: %w", err)
	}

	serialLimit := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(rand.Reader, serialLimit)
	if err != nil {
		return tls.Certificate{}, nil, fmt.Errorf("generate serial: %w", err)
	}
	if serial.Sign() == 0 {
		serial = big.NewInt(1)
	}

	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serial,
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{
			x509.ExtKeyUsageServerAuth,
			x509.ExtKeyUsageClientAuth,
		},
		BasicConstraintsValid: true,
	}

	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, nil, fmt.Errorf("create certificate: %w", err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return tls.Certificate{}, nil, fmt.Errorf("marshal private key: %w", err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
	tlsCert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return tls.Certificate{}, nil, fmt.Errorf("load key pair: %w", err)
	}
	return tlsCert, der, nil
}

func certFingerprint(der []byte) string {
	sum := sha256.Sum256(der)
	return hex.EncodeToString(sum[:])
}

func verifyFingerprint(expected string, rawCerts [][]byte) error {
	if len(rawCerts) == 0 {
		return fmt.Errorf("missing peer certificate")
	}
	got := certFingerprint(rawCerts[0])
	if subtle.ConstantTimeCompare([]byte(got), []byte(expected)) != 1 {
		return fmt.Errorf("peer certificate fingerprint mismatch")
	}
	return nil
}
