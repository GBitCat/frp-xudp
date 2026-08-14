// XUDP extension: QUIC DATAGRAM transport.

package transport

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"time"

	quic "github.com/quic-go/quic-go"

	v1 "github.com/fatedier/frp/pkg/config/v1"
)

const (
	defaultKeepalivePeriod = 10 * time.Second
	defaultMaxIdleTimeout  = 30 * time.Second
)

// Options controls the QUIC connection lifecycle.
//
// XUDP deliberately does not expose these values to users. They are derived
// from the existing frp client transport configuration, keeping the xudp
// configuration surface unchanged.
type Options struct {
	KeepalivePeriod time.Duration
	MaxIdleTimeout  time.Duration
}

func OptionsFromClientCfg(cfg *v1.ClientCommonConfig) Options {
	if cfg == nil {
		return Options{
			KeepalivePeriod: defaultKeepalivePeriod,
			MaxIdleTimeout:  defaultMaxIdleTimeout,
		}
	}
	return Options{
		KeepalivePeriod: time.Duration(cfg.Transport.QUIC.KeepalivePeriod) * time.Second,
		MaxIdleTimeout:  time.Duration(cfg.Transport.QUIC.MaxIdleTimeout) * time.Second,
	}
}

func (o Options) quicConfig() *quic.Config {
	keepalive := o.KeepalivePeriod
	if keepalive <= 0 {
		keepalive = defaultKeepalivePeriod
	}
	idleTimeout := o.MaxIdleTimeout
	if idleTimeout <= 0 {
		idleTimeout = defaultMaxIdleTimeout
	}

	return &quic.Config{
		KeepAlivePeriod:         keepalive,
		MaxIdleTimeout:          idleTimeout,
		EnableDatagrams:         true,
		MaxIncomingStreams:      -1,
		MaxIncomingUniStreams:   -1,
		HandshakeIdleTimeout:    10 * time.Second,
		InitialPacketSize:       DefaultMaxDatagramPayloadSize,
		DisablePathMTUDiscovery: true,
	}
}

type quicDatagramTransport struct {
	conn *quic.Conn
}

func (t *quicDatagramTransport) SendDatagram(p []byte) error {
	return t.conn.SendDatagram(p)
}

func (t *quicDatagramTransport) ReceiveDatagram(ctx context.Context) ([]byte, error) {
	return t.conn.ReceiveDatagram(ctx)
}

func (t *quicDatagramTransport) MaxDatagramPayloadSize() int {
	return DefaultMaxDatagramPayloadSize
}

func (t *quicDatagramTransport) ConnectionState() quic.ConnectionState {
	return t.conn.ConnectionState()
}

func (t *quicDatagramTransport) VerifyPeerFingerprint(expected string) error {
	state := t.conn.ConnectionState()
	if len(state.TLS.PeerCertificates) == 0 {
		return fmt.Errorf("missing quic peer certificate")
	}
	return verifyFingerprint(expected, [][]byte{state.TLS.PeerCertificates[0].Raw})
}

func (t *quicDatagramTransport) Close() error {
	return t.conn.CloseWithError(0, "")
}

func (t *quicDatagramTransport) LocalAddr() net.Addr {
	return t.conn.LocalAddr()
}

func (t *quicDatagramTransport) RemoteAddr() net.Addr {
	return t.conn.RemoteAddr()
}

// Dial establishes an outgoing QUIC DATAGRAM connection over an already
// punched UDP socket.
func Dial(ctx context.Context, conn *net.UDPConn, raddr *net.UDPAddr, tlsConfig *tls.Config, opts Options) (DatagramTransport, error) {
	quicConn, err := quic.Dial(ctx, conn, raddr, tlsConfig, opts.quicConfig())
	if err != nil {
		return nil, err
	}
	return &quicDatagramTransport{conn: quicConn}, nil
}

type Listener struct {
	inner *quic.Listener
}

// Listen starts a QUIC DATAGRAM listener on the already punched UDP socket.
func Listen(conn *net.UDPConn, tlsConfig *tls.Config, opts Options) (*Listener, error) {
	listener, err := quic.Listen(conn, tlsConfig, opts.quicConfig())
	if err != nil {
		return nil, err
	}
	return &Listener{inner: listener}, nil
}

func (l *Listener) Accept(ctx context.Context) (DatagramTransport, error) {
	conn, err := l.inner.Accept(ctx)
	if err != nil {
		return nil, err
	}
	return &quicDatagramTransport{conn: conn}, nil
}

func (l *Listener) Close() error {
	return l.inner.Close()
}
