// Copyright 2026 The frp Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//go:build !frps

package proxy

import (
	"bytes"
	"errors"
	"io"
	"math/rand"
	"net"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
	"github.com/fatedier/frp/pkg/proto/wire"
	"github.com/fatedier/frp/pkg/util/xlog"
)

func TestClassifyXUDPWorkConnExplicitRoleDoesNotReadPayload(t *testing.T) {
	for _, wireProtocol := range []string{wire.ProtocolV1, wire.ProtocolV2} {
		t.Run(wireProtocol, func(t *testing.T) {
			for _, role := range []string{msg.XUDPWorkConnRoleRelay, msg.XUDPWorkConnRoleP2P} {
				t.Run(role, func(t *testing.T) {
					conn := newMemoryConn([]byte("encrypted-or-compressed-relay-payload"))
					gotRole, routed, err := classifyXUDPWorkConn(conn, &msg.StartWorkConn{XUDPRole: role}, wireProtocol)
					require.NoError(t, err)
					require.Equal(t, role, gotRole)
					require.Same(t, conn, routed)
					require.Zero(t, conn.reads)
					require.Zero(t, conn.readDeadlineCalls)
				})
			}
		})
	}
}

func TestXUDPWorkConnUnknownRoleIsRejectedAndClosed(t *testing.T) {
	conn := newMemoryConn([]byte("must-not-be-read"))
	pxy := &XUDPProxy{BaseProxy: &BaseProxy{
		clientCfg: &v1.ClientCommonConfig{},
		xl:        xlog.New(),
	}}

	pxy.InWorkConn(conn, &msg.StartWorkConn{XUDPRole: "future-unknown-role"})
	require.True(t, conn.closed)
	require.Zero(t, conn.reads)
}

func TestClassifyLegacyXUDPWorkConnFullyValidatesNatHoleSid(t *testing.T) {
	for _, wireProtocol := range []string{wire.ProtocolV1, wire.ProtocolV2} {
		t.Run(wireProtocol, func(t *testing.T) {
			tests := []struct {
				name string
				in   msg.Message
				want string
			}{
				{name: "valid xudp sid", in: &msg.NatHoleSid{Sid: "sid", Nonce: "xudp"}, want: msg.XUDPWorkConnRoleP2P},
				{name: "wrong nonce", in: &msg.NatHoleSid{Sid: "sid", Nonce: "other"}, want: msg.XUDPWorkConnRoleRelay},
				{name: "empty sid", in: &msg.NatHoleSid{Nonce: "xudp"}, want: msg.XUDPWorkConnRoleRelay},
				{name: "different message", in: &msg.UDPPacket{Content: []byte("relay")}, want: msg.XUDPWorkConnRoleRelay},
			}
			for _, tc := range tests {
				t.Run(tc.name, func(t *testing.T) {
					encoded := encodeTestMessage(t, wireProtocol, tc.in)
					conn := newMemoryConn(encoded)
					gotRole, routed, err := classifyXUDPWorkConn(conn, &msg.StartWorkConn{}, wireProtocol)
					require.NoError(t, err)
					require.Equal(t, tc.want, gotRole)

					replayed, err := io.ReadAll(routed)
					require.NoError(t, err)
					require.Equal(t, encoded, replayed, "legacy classification must not consume payload")
				})
			}
		})
	}
}

func TestClassifyLegacyXUDPWorkConnHandlesPartialReads(t *testing.T) {
	for _, wireProtocol := range []string{wire.ProtocolV1, wire.ProtocolV2} {
		t.Run(wireProtocol, func(t *testing.T) {
			encoded := encodeTestMessage(t, wireProtocol, &msg.NatHoleSid{Sid: "sid", Nonce: "xudp"})
			conn := newMemoryConn(encoded)
			conn.maxReadSize = 1

			role, routed, err := classifyLegacyXUDPWorkConn(conn, wireProtocol)
			require.NoError(t, err)
			require.Equal(t, msg.XUDPWorkConnRoleP2P, role)
			replayed, err := io.ReadAll(routed)
			require.NoError(t, err)
			require.Equal(t, encoded, replayed)
			require.Greater(t, conn.reads, 1)
		})
	}
}

func TestClassifyLegacyXUDPWorkConnReplaysCompleteNatHoleSidAndTrailingData(t *testing.T) {
	trailing := []byte("\x00encrypted-or-compressed-trailing-data\xff")
	for _, wireProtocol := range []string{wire.ProtocolV1, wire.ProtocolV2} {
		t.Run(wireProtocol, func(t *testing.T) {
			encoded := encodeTestMessage(t, wireProtocol, &msg.NatHoleSid{Sid: "sid", Nonce: "xudp"})
			payload := append(append([]byte(nil), encoded...), trailing...)
			conn := newMemoryConn(payload)

			role, routed, err := classifyLegacyXUDPWorkConn(conn, wireProtocol)
			require.NoError(t, err)
			require.Equal(t, msg.XUDPWorkConnRoleP2P, role)
			replayed, err := io.ReadAll(routed)
			require.NoError(t, err)
			require.Equal(t, payload, replayed)
		})
	}
}

func TestClassifyLegacyXUDPWorkConnDeadlineFailures(t *testing.T) {
	deadlineSetErr := errors.New("deadline set failed")
	conn := newMemoryConn([]byte("must-not-be-read"))
	conn.setReadDeadlineErr = deadlineSetErr
	role, routed, err := classifyLegacyXUDPWorkConn(conn, wire.ProtocolV1)
	require.ErrorIs(t, err, deadlineSetErr)
	require.Empty(t, role)
	require.Same(t, conn, routed)
	require.Zero(t, conn.reads)

	deadlineClearErr := errors.New("deadline clear failed")
	encoded := encodeTestMessage(t, wire.ProtocolV1, &msg.NatHoleSid{Sid: "sid", Nonce: "xudp"})
	conn = newMemoryConn(encoded)
	conn.clearReadDeadlineErr = deadlineClearErr
	role, routed, err = classifyLegacyXUDPWorkConn(conn, wire.ProtocolV1)
	require.ErrorIs(t, err, deadlineClearErr)
	require.Empty(t, role)
	require.Same(t, conn, routed)
	require.NotZero(t, conn.reads)
	require.Equal(t, 2, conn.readDeadlineCalls)
}

func TestXUDPWorkConnDeadlineFailuresAreRejectedAndClosed(t *testing.T) {
	for _, tc := range []struct {
		name     string
		setErr   error
		clearErr error
	}{
		{name: "set", setErr: errors.New("set failed")},
		{name: "clear", clearErr: errors.New("clear failed")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			encoded := encodeTestMessage(t, wire.ProtocolV1, &msg.NatHoleSid{Sid: "sid", Nonce: "xudp"})
			conn := newMemoryConn(encoded)
			conn.setReadDeadlineErr = tc.setErr
			conn.clearReadDeadlineErr = tc.clearErr
			pxy := &XUDPProxy{BaseProxy: &BaseProxy{
				clientCfg: &v1.ClientCommonConfig{},
				xl:        xlog.New(),
			}}

			pxy.InWorkConn(conn, &msg.StartWorkConn{})
			require.True(t, conn.closed)
		})
	}
}

func TestClassifyLegacyXUDPWorkConnCiphertextIsRelay(t *testing.T) {
	rng := rand.New(rand.NewSource(20260308))
	for _, wireProtocol := range []string{wire.ProtocolV1, wire.ProtocolV2} {
		t.Run(wireProtocol, func(t *testing.T) {
			malicious := encodeTestMessage(t, wireProtocol, &msg.NatHoleSid{Sid: "sid", Nonce: "xudp"})
			malicious[len(malicious)-1] ^= 0xff
			assertLegacyRelayClassification(t, wireProtocol, malicious)

			for i := 0; i < 128; i++ {
				ciphertext := make([]byte, 1+rng.Intn(256))
				_, err := rng.Read(ciphertext)
				require.NoError(t, err)
				assertLegacyRelayClassification(t, wireProtocol, ciphertext)
			}
		})
	}
}

func assertLegacyRelayClassification(t *testing.T, wireProtocol string, payload []byte) {
	t.Helper()
	conn := newMemoryConn(payload)
	role, routed, err := classifyLegacyXUDPWorkConn(conn, wireProtocol)
	require.NoError(t, err)
	require.Equal(t, msg.XUDPWorkConnRoleRelay, role)
	replayed, err := io.ReadAll(routed)
	require.NoError(t, err)
	require.Equal(t, payload, replayed)
}

func encodeTestMessage(t *testing.T, wireProtocol string, m msg.Message) []byte {
	t.Helper()
	var encoded bytes.Buffer
	require.NoError(t, msg.NewReadWriter(&encoded, wireProtocol).WriteMsg(m))
	return encoded.Bytes()
}

type memoryConn struct {
	reader               *bytes.Reader
	reads                int
	maxReadSize          int
	closed               bool
	setReadDeadlineErr   error
	clearReadDeadlineErr error
	readDeadlineCalls    int
}

func newMemoryConn(payload []byte) *memoryConn {
	return &memoryConn{reader: bytes.NewReader(payload)}
}

func (c *memoryConn) Read(p []byte) (int, error) {
	c.reads++
	if c.maxReadSize > 0 && len(p) > c.maxReadSize {
		p = p[:c.maxReadSize]
	}
	return c.reader.Read(p)
}

func (c *memoryConn) Write(p []byte) (int, error) { return len(p), nil }
func (c *memoryConn) Close() error {
	c.closed = true
	return nil
}
func (c *memoryConn) LocalAddr() net.Addr         { return testAddr("local") }
func (c *memoryConn) RemoteAddr() net.Addr        { return testAddr("remote") }
func (c *memoryConn) SetDeadline(time.Time) error { return nil }
func (c *memoryConn) SetReadDeadline(deadline time.Time) error {
	c.readDeadlineCalls++
	if deadline.IsZero() {
		return c.clearReadDeadlineErr
	}
	return c.setReadDeadlineErr
}
func (c *memoryConn) SetWriteDeadline(time.Time) error { return nil }

type testAddr string

func (a testAddr) Network() string { return string(a) }
func (a testAddr) String() string  { return string(a) }
