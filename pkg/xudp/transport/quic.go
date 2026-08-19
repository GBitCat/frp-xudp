// XUDP extension: QUIC DATAGRAM transport.

package transport

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
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

	// enablePathMTUDiscovery is an internal-only experiment switch. It is
	// intentionally unexported so PMTUD cannot become an XUDP user setting;
	// production-created Options keep the conservative default disabled.
	enablePathMTUDiscovery bool
}

func OptionsFromClientCfg(cfg *v1.ClientCommonConfig) Options {
	if cfg == nil {
		return Options{
			KeepalivePeriod:        defaultKeepalivePeriod,
			MaxIdleTimeout:         defaultMaxIdleTimeout,
			enablePathMTUDiscovery: experimentalPathMTUDiscoveryDefault,
		}
	}
	return Options{
		KeepalivePeriod:        time.Duration(cfg.Transport.QUIC.KeepalivePeriod) * time.Second,
		MaxIdleTimeout:         time.Duration(cfg.Transport.QUIC.MaxIdleTimeout) * time.Second,
		enablePathMTUDiscovery: experimentalPathMTUDiscoveryDefault,
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
		KeepAlivePeriod:       keepalive,
		MaxIdleTimeout:        idleTimeout,
		EnableDatagrams:       true,
		MaxIncomingStreams:    -1,
		MaxIncomingUniStreams: -1,
		HandshakeIdleTimeout:  10 * time.Second,
		InitialPacketSize:     DefaultQUICInitialPacketSize,
		// PMTUD is opt-in for an internal experiment. The production default
		// remains DisablePathMTUDiscovery=true for conservative XUDP sizing.
		DisablePathMTUDiscovery: !o.enablePathMTUDiscovery,
	}
}

type quicDatagramTransport struct {
	conn            *quic.Conn
	packetConn      net.PacketConn
	closePacketConn bool
	closeOnce       sync.Once
	closeErr        error
	closed          atomic.Bool
}

func (t *quicDatagramTransport) SendDatagram(p []byte) error {
	if t.closed.Load() {
		return net.ErrClosed
	}
	if err := ValidateDatagramSizeAgainstLimit(len(p), t.MaxDatagramPayloadSize()); err != nil {
		return err
	}
	if err := t.conn.SendDatagram(p); err != nil {
		// CloseWithError closes quic-go's DATAGRAM queue and wakes senders
		// blocked because that queue is full. Normalize that concurrent-close
		// result without holding a transport lock across SendDatagram.
		if t.closed.Load() {
			return net.ErrClosed
		}
		var tooLarge *quic.DatagramTooLargeError
		if errors.As(err, &tooLarge) {
			return fmt.Errorf("%w: size %d exceeds QUIC payload limit %d", ErrDatagramTooLarge, len(p), tooLarge.MaxDatagramPayloadSize)
		}
		return err
	}
	return nil
}

func (t *quicDatagramTransport) ReceiveDatagram(ctx context.Context) ([]byte, error) {
	if t.closed.Load() {
		return nil, net.ErrClosed
	}
	data, err := t.conn.ReceiveDatagram(ctx)
	if err != nil && t.closed.Load() {
		return nil, net.ErrClosed
	}
	return data, err
}

func (t *quicDatagramTransport) MaxDatagramPayloadSize() int {
	return ConservativeXUDPDatagramPayloadLimit
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
	t.closeOnce.Do(func() {
		// Publish closure before closing the QUIC connection so new operations
		// are rejected while CloseWithError wakes any blocked send or receive.
		t.closed.Store(true)

		// quic-go does not take ownership of the PacketConn passed to Dial or
		// Listen. Dial transports own their socket. An accepted transport keeps
		// a reference to the listener's socket but must not close it: the
		// listener may still need that socket for future Accept calls.
		t.closeErr = t.conn.CloseWithError(0, "")
		if t.closePacketConn {
			t.closeErr = errors.Join(t.closeErr, t.packetConn.Close())
		}
	})
	return t.closeErr
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
		// Dial does not own or close the PacketConn when the handshake fails.
		// The caller must not need to remember a separate failure cleanup path.
		_ = conn.Close()
		return nil, err
	}
	return &quicDatagramTransport{conn: quicConn, packetConn: conn, closePacketConn: true}, nil
}

type Listener struct {
	inner      *quic.Listener
	packetConn net.PacketConn
	closeOnce  sync.Once
	closeErr   error
}

// Listen starts a QUIC DATAGRAM listener on the already punched UDP socket.
func Listen(conn *net.UDPConn, tlsConfig *tls.Config, opts Options) (*Listener, error) {
	listener, err := quic.Listen(conn, tlsConfig, opts.quicConfig())
	if err != nil {
		// Listen does not close the supplied PacketConn on setup failure.
		_ = conn.Close()
		return nil, err
	}
	return &Listener{inner: listener, packetConn: conn}, nil
}

func (l *Listener) Accept(ctx context.Context) (DatagramTransport, error) {
	conn, err := l.inner.Accept(ctx)
	if err != nil {
		return nil, err
	}
	return &quicDatagramTransport{conn: conn, packetConn: l.packetConn}, nil
}

func (l *Listener) Close() error {
	l.closeOnce.Do(func() {
		// Close the QUIC listener first so blocked Accept calls are released,
		// then close the UDP socket that backed the NAT hole.
		l.closeErr = errors.Join(l.inner.Close(), l.packetConn.Close())
	})
	return l.closeErr
}
