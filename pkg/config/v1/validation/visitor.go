// Copyright 2023 The frp Authors
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

package validation

import (
	"errors"
	"fmt"
	"net"
	"slices"
	"strconv"

	v1 "github.com/fatedier/frp/pkg/config/v1"
)

func ValidateVisitorConfigurer(c v1.VisitorConfigurer) error {
	base := c.GetBaseConfig()
	if err := validateVisitorBaseConfig(base); err != nil {
		return err
	}

	switch v := c.(type) {
	case *v1.STCPVisitorConfig:
	case *v1.SUDPVisitorConfig:
	case *v1.XUDPVisitorConfig:
	case *v1.XTCPVisitorConfig:
		return validateXTCPVisitorConfig(v)
	default:
		return errors.New("unknown visitor config type")
	}
	return nil
}

func validateVisitorBaseConfig(c *v1.VisitorBaseConfig) error {
	if c.Name == "" {
		return errors.New("name is required")
	}

	if c.ServerName == "" {
		return errors.New("server name is required")
	}

	if c.BindPort == 0 {
		return errors.New("bind port is required")
	}
	if c.Plugin.Type == v1.VisitorPluginSocks5UDP {
		if c.Type != "stcp" && c.Type != "xtcp" {
			return errors.New("socks5_udp visitor plugin requires STCP/XTCP")
		}
		if c.BindPort != -1 {
			return errors.New("socks5_udp visitor requires bindPort = -1; configure the SOCKS5 listener in plugin.bindPort")
		}
		options, ok := c.Plugin.VisitorPluginOptions.(*v1.Socks5UDPVisitorPluginOptions)
		if !ok || options == nil {
			return errors.New("invalid socks5_udp visitor options")
		}
		if options.BindPort <= 0 {
			return errors.New("plugin.bindPort must be positive")
		}
		if err := ValidatePort(options.BindPort, "plugin.bindPort"); err != nil {
			return err
		}
		if options.BindAddr != "" && net.ParseIP(options.BindAddr) == nil {
			return errors.New("socks5_udp plugin.bindAddr must be an IP address")
		}
		host, port, err := net.SplitHostPort(options.UDPVisitorAddr)
		if err != nil {
			return fmt.Errorf("invalid plugin.udpVisitorAddr: %w", err)
		}
		ip := net.ParseIP(host)
		if ip == nil || !ip.IsLoopback() {
			return errors.New("plugin.udpVisitorAddr must reference a loopback IP address")
		}
		p, err := strconv.Atoi(port)
		if err != nil || p <= 0 {
			return errors.New("invalid plugin.udpVisitorAddr port")
		}
		if err := ValidatePort(p, "plugin.udpVisitorAddr port"); err != nil {
			return err
		}
	}
	return nil
}

func validateXTCPVisitorConfig(c *v1.XTCPVisitorConfig) error {
	if !slices.Contains([]string{"kcp", "quic"}, c.Protocol) {
		return fmt.Errorf("protocol should be kcp or quic")
	}
	return nil
}
