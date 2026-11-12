// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0.

//go:build !frps

package proxy

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
	plugin "github.com/fatedier/frp/pkg/plugin/client"
	"github.com/fatedier/frp/pkg/plugin/socks5udp"
)

func TestSOCKS5UDPRepeatedRunPreservesAndClosesAssociation(t *testing.T) {
	for _, dataType := range []string{"sudp", "xudp"} {
		for _, controlType := range []string{"stcp", "xtcp"} {
			t.Run(controlType+"-"+dataType, func(t *testing.T) {
				ctx := plugin.WithSharedStore(context.Background())
				common := &v1.ClientCommonConfig{UDPPacketSize: 1500}
				makeProxy := func(kind, name, udpName string) Proxy {
					cfg := v1.NewProxyConfigurerByType(v1.ProxyType(kind))
					base := cfg.GetBaseConfig()
					base.Name = name
					base.Plugin = v1.TypedClientPluginOptions{
						Type:                v1.PluginSocks5UDP,
						ClientPluginOptions: &v1.Socks5UDPPluginOptions{Type: v1.PluginSocks5UDP, UDPProxyName: udpName},
					}
					return NewProxy(ctx, cfg, common, nil, nil, nil, "")
				}
				dataProxy := makeProxy(dataType, "data", "")
				controlProxy := makeProxy(controlType, "control", "data")
				t.Cleanup(dataProxy.Close)
				t.Cleanup(controlProxy.Close)
				require.NoError(t, dataProxy.Run())
				require.NoError(t, controlProxy.Run())
				dataOwner := dataProxy.(interface{ getPlugin() plugin.Plugin })
				controlOwner := controlProxy.(interface{ getPlugin() plugin.Plugin })
				dataPlugin, controlPlugin := dataOwner.getPlugin(), controlOwner.getPlugin()
				provider, visitor := net.Pipe()
				t.Cleanup(func() { _ = visitor.Close() })
				controlDone := make(chan struct{})
				go func() {
					controlPlugin.Handle(context.Background(), &plugin.ConnectionInfo{Conn: provider, UnderlyingConn: provider})
					close(controlDone)
				}()
				token := openSOCKS5TransportTestAssociation(t, visitor)
				target, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
				require.NoError(t, err)
				t.Cleanup(func() { _ = target.Close() })
				go func() {
					buf := make([]byte, 1500)
					for {
						n, peer, err := target.ReadFromUDP(buf)
						if err != nil {
							return
						}
						_, _ = target.WriteToUDP(buf[:n], peer)
					}
				}()
				readCh := make(chan *msg.UDPPacket, 4)
				sendCh := make(chan msg.Message, 4)
				packetsDone := make(chan struct{})
				go func() {
					dataPlugin.(plugin.DatagramPlugin).ServePackets(ctx, readCh, sendCh)
					close(packetsDone)
				}()
				packet, err := socks5udp.BuildUDP(socks5udp.AddressFromNetAddr(target.LocalAddr()), []byte("existing-association"))
				require.NoError(t, err)
				request := &msg.UDPPacket{
					Content:    socks5udp.EncodeDatagram(token, packet),
					RemoteAddr: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 40123},
				}
				roundTrip := func() {
					t.Helper()
					readCh <- request
					select {
					case response := <-sendCh:
						require.Equal(t, request.Content, response.(*msg.UDPPacket).Content)
					case <-time.After(3 * time.Second):
						t.Fatal("existing association stopped forwarding")
					}
				}
				roundTrip()
				// Health-check recovery invokes Run on the same wrapper and proxy.
				require.NoError(t, dataProxy.Run())
				require.NoError(t, controlProxy.Run())
				require.Same(t, dataPlugin, dataOwner.getPlugin())
				require.Same(t, controlPlugin, controlOwner.getPlugin())
				roundTrip()
				controlProxy.Close()
				select {
				case <-controlDone:
				case <-time.After(time.Second):
					t.Fatal("Close lost ownership of the original control connection")
				}
				readCh <- request
				select {
				case <-sendCh:
					t.Fatal("closed association still forwards UDP")
				case <-time.After(50 * time.Millisecond):
				}
				dataProxy.Close()
				select {
				case <-packetsDone:
				case <-time.After(time.Second):
					t.Fatal("data worker outlived proxy Close")
				}
				// A replacement wrapper can reuse the manager-scoped endpoint name.
				replacement := makeProxy(dataType, "data", "")
				t.Cleanup(replacement.Close)
				require.NoError(t, replacement.Run())
			})
		}
	}
}
