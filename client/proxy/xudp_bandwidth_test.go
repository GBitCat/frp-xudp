//go:build !frps

package proxy

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"golang.org/x/time/rate"

	"github.com/fatedier/frp/pkg/config/types"
	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
)

func TestXUDPP2PClientBandwidth(t *testing.T) {
	for _, direction := range []string{"receive", "send"} {
		for _, mode := range []string{"normal", "small-burst", "close"} {
			t.Run(fmt.Sprintf("%s/%s", direction, mode), func(t *testing.T) {
				target, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
				require.NoError(t, err)
				t.Cleanup(func() { _ = target.Close() })
				cfg := v1.NewProxyConfigurerByType(v1.ProxyType("xudp")).(*v1.XUDPProxyConfig)
				cfg.Name, cfg.LocalIP, cfg.LocalPort = "bandwidth", "127.0.0.1", target.LocalAddr().(*net.UDPAddr).Port
				cfg.Transport.BandwidthLimit, err = types.NewBandwidthQuantity("1KB")
				require.NoError(t, err)
				cfg.Transport.BandwidthLimitMode = types.BandwidthLimitModeClient
				pxy := NewProxy(context.Background(), cfg, &v1.ClientCommonConfig{UDPPacketSize: 1500}, nil, nil, nil, "").(*XUDPProxy)
				require.NoError(t, pxy.Run())
				t.Cleanup(pxy.Close)
				provider, visitor := newSOCKS5TestQUICPair(t)
				_, peer, done := startActiveP2PForward(t, pxy, provider)
				t.Cleanup(func() { _ = peer.Close() })
				payload := bytes.Repeat([]byte{'p'}, 1000)
				addr := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 23456}
				var localAddr *net.UDPAddr
				if direction == "send" {
					// Establish the UDP mapping before exhausting the budget, so
					// this case measures only provider-to-visitor traffic.
					body, err := msg.EncodeUDPPacketBinary(&msg.UDPPacket{Content: []byte("open"), RemoteAddr: addr})
					require.NoError(t, err)
					require.NoError(t, visitor.SendDatagram(body))
					require.NoError(t, target.SetReadDeadline(time.Now().Add(time.Second)))
					_, localAddr, err = target.ReadFromUDP(make([]byte, 1500))
					require.NoError(t, err)
				}
				if mode == "small-burst" {
					pxy.limiter.SetBurst(32)
				}
				if mode == "close" {
					pxy.limiter.SetLimit(rate.Limit(1))
				}
				require.True(t, pxy.limiter.AllowN(time.Now(), int(pxy.limiter.Tokens())))
				if direction == "receive" {
					body, err := msg.EncodeUDPPacketBinary(&msg.UDPPacket{Content: payload, RemoteAddr: addr})
					require.NoError(t, err)
					require.NoError(t, visitor.SendDatagram(body))
				} else {
					_, err := target.WriteToUDP(payload, localAddr)
					require.NoError(t, err)
				}
				// Reservations are observable evidence that the real QUIC data
				// plane uses this configured proxy budget in either direction.
				require.Eventually(t, func() bool { return pxy.limiter.Tokens() < -10 }, time.Second, time.Millisecond)
				if mode == "close" {
					closed := make(chan struct{})
					go func() { pxy.Close(); close(closed) }()
					select {
					case <-closed:
					case <-time.After(time.Second):
						t.Fatal("Close did not cancel P2P bandwidth wait")
					}
					select {
					case <-done:
					case <-time.After(time.Second):
						t.Fatal("P2P workers did not join")
					}
					return
				}
				if direction == "receive" {
					require.NoError(t, target.SetReadDeadline(time.Now().Add(100*time.Millisecond)))
					_, _, err := target.ReadFromUDP(make([]byte, 1500))
					require.Error(t, err, "packet bypassed client bandwidth limit")
					require.NoError(t, target.SetReadDeadline(time.Now().Add(3*time.Second)))
					buffer := make([]byte, 1500)
					n, _, err := target.ReadFromUDP(buffer)
					require.NoError(t, err)
					require.Equal(t, payload, buffer[:n], "rate limiting must not fragment datagrams")
				} else {
					ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
					_, err := visitor.ReceiveDatagram(ctx)
					cancel()
					require.Error(t, err, "packet bypassed client bandwidth limit")
					ctx, cancel = context.WithTimeout(context.Background(), 3*time.Second)
					body, err := visitor.ReceiveDatagram(ctx)
					cancel()
					require.NoError(t, err)
					packet, err := msg.DecodeUDPPacketBinary(body)
					require.NoError(t, err)
					require.Equal(t, payload, packet.Content, "rate limiting must not fragment datagrams")
				}
			})
		}
	}
}
