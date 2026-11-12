// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0.

package validation

import (
	"testing"

	"github.com/stretchr/testify/require"

	v1 "github.com/fatedier/frp/pkg/config/v1"
)

func TestSocks5UDPProxyRoles(t *testing.T) {
	for _, tc := range []struct {
		name, proxyType, target, username, pp string
		valid                                 bool
	}{
		{"control", "stcp", "data", "alice", "", true},
		{"p2p-control", "xtcp", "data", "alice", "", true},
		{"datagram", "sudp", "", "", "", true},
		{"p2p-datagram", "xudp", "", "", "", true},
		{"missing-pair", "stcp", "", "", "", false},
		{"self-pair", "stcp", "control", "", "", false},
		{"credentials-on-data", "sudp", "", "alice", "", false},
		{"pair-on-data", "xudp", "data", "", "", false},
		{"public-proxy", "tcp", "data", "", "", false},
		{"proxy-protocol", "sudp", "", "", "v2", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := v1.NewProxyConfigurerByType(v1.ProxyType(tc.proxyType))
			base := cfg.GetBaseConfig()
			base.Name = "control"
			base.Transport.ProxyProtocolVersion = tc.pp
			base.Plugin = v1.TypedClientPluginOptions{Type: v1.PluginSocks5UDP, ClientPluginOptions: &v1.Socks5UDPPluginOptions{
				Type: v1.PluginSocks5UDP, UDPProxyName: tc.target, Username: tc.username,
			}}
			cfg.Complete()
			err := ValidateProxyConfigurerForClient(cfg)
			if tc.valid {
				require.NoError(t, err)
			} else {
				require.Error(t, err)
			}
		})
	}
}

func TestSocks5UDPVisitorValidation(t *testing.T) {
	for _, tc := range []struct {
		name, visitorType, udpAddr string
		bindPort, pluginPort       int
		valid                      bool
	}{
		{"valid", "stcp", "127.0.0.1:1234", -1, 1234, true},
		{"ipv6", "xtcp", "[::1]:1234", -1, 1234, true},
		{"remote-udp", "stcp", "192.0.2.1:1234", -1, 1234, false},
		{"hostname-udp", "stcp", "localhost:1234", -1, 1234, false},
		{"zero-udp", "stcp", "127.0.0.1:0", -1, 1234, false},
		{"zero-listener", "stcp", "127.0.0.1:1234", -1, 0, false},
		{"raw-listener", "stcp", "127.0.0.1:1234", 1234, 1234, false},
		{"udp-control", "xudp", "127.0.0.1:1234", -1, 1234, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := v1.NewVisitorConfigurerByType(v1.VisitorType(tc.visitorType))
			base := cfg.GetBaseConfig()
			base.Name, base.ServerName, base.BindPort = "visitor", "provider", tc.bindPort
			base.Plugin = v1.TypedVisitorPluginOptions{Type: v1.VisitorPluginSocks5UDP, VisitorPluginOptions: &v1.Socks5UDPVisitorPluginOptions{
				Type: v1.VisitorPluginSocks5UDP, BindPort: tc.pluginPort, UDPVisitorAddr: tc.udpAddr,
			}}
			cfg.Complete()
			err := ValidateVisitorConfigurer(cfg)
			if tc.valid {
				require.NoError(t, err)
			} else {
				require.Error(t, err)
			}
		})
	}
}
