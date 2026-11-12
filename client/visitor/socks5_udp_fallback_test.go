// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

//go:build !frps

package visitor

import (
	"context"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
	"github.com/fatedier/frp/pkg/plugin/socks5udp"
	visitorplugin "github.com/fatedier/frp/pkg/plugin/visitor"
)

type socks5UDPUnavailableTunnel struct{}

func (*socks5UDPUnavailableTunnel) Init(*net.UDPConn, *net.UDPAddr) error { return nil }
func (*socks5UDPUnavailableTunnel) OpenConn(context.Context) (net.Conn, error) {
	return nil, ErrNoTunnelSession
}
func (*socks5UDPUnavailableTunnel) Close() {}

type socks5UDPFallbackHelper struct {
	Helper
	ctx         context.Context
	fallback    *STCPVisitor
	endpoint    *socks5udp.Endpoint
	transferred chan struct{}
	workers     sync.WaitGroup
}

func (h *socks5UDPFallbackHelper) RunID() string { return "socks5-udp-fallback-test" }

func (h *socks5UDPFallbackHelper) ConnectServer() (*msg.Conn, error) {
	client, server := net.Pipe()
	h.workers.Go(func() {
		defer server.Close()
		peer := msg.NewConn(server, msg.NewV1ReadWriter(server))
		var request msg.NewVisitorConn
		if err := peer.ReadMsgInto(&request); err != nil {
			return
		}
		if err := peer.WriteMsg(&msg.NewVisitorConnResp{}); err != nil {
			return
		}
		_ = socks5udp.ServeControl(h.ctx, server, socks5udp.ControlOptions{Endpoint: h.endpoint})
	})
	return msg.NewConn(client, msg.NewV1ReadWriter(client)), nil
}

func (h *socks5UDPFallbackHelper) TransferConn(_ string, conn net.Conn) error {
	close(h.transferred)
	h.workers.Go(func() { h.fallback.handleConn(conn) })
	return nil
}

func TestSocks5UDPXTCPFallbackExceedsHandshakeTimeout(t *testing.T) {
	// Exercise the actual XTCP fallback and STCP stream handlers. The tunnel is
	// unavailable for 11s, longer than the SOCKS protocol's 10s handshake budget.
	ctx, cancel := context.WithCancel(context.Background())
	endpoint := socks5udp.NewEndpoint(socks5udp.EndpointOptions{})
	helper := &socks5UDPFallbackHelper{
		ctx: ctx, endpoint: endpoint, transferred: make(chan struct{}),
	}
	helper.fallback = &STCPVisitor{
		BaseVisitor: &BaseVisitor{ctx: ctx, helper: helper, clientCfg: &v1.ClientCommonConfig{}},
		cfg:         &v1.STCPVisitorConfig{},
	}
	xtcp := &XTCPVisitor{
		BaseVisitor:   &BaseVisitor{ctx: ctx, helper: helper},
		session:       &socks5UDPUnavailableTunnel{},
		startTunnelCh: make(chan struct{}),
		cfg:           &v1.XTCPVisitorConfig{FallbackTo: "stcp", FallbackTimeoutMs: 11000},
	}
	t.Cleanup(func() {
		cancel()
		_ = endpoint.Close()
		helper.workers.Wait()
	})
	reserve, err := net.Listen("tcp4", "127.0.0.1:0")
	require.NoError(t, err)
	addr := reserve.Addr().(*net.TCPAddr)
	require.NoError(t, reserve.Close())
	plugin, err := visitorplugin.NewSocks5UDPPlugin(visitorplugin.PluginContext{
		Ctx: ctx,
		SendConnToVisitor: func(conn net.Conn) {
			helper.workers.Go(func() { xtcp.handleConn(conn) })
		},
	}, &v1.Socks5UDPVisitorPluginOptions{
		BindAddr: "127.0.0.1", BindPort: addr.Port, UDPVisitorAddr: "127.0.0.1:12345",
	})
	require.NoError(t, err)
	t.Cleanup(func() { _ = plugin.Close() })
	plugin.Start()
	client, err := net.Dial("tcp4", addr.String())
	require.NoError(t, err)
	t.Cleanup(func() { _ = client.Close() })
	require.NoError(t, client.SetDeadline(time.Now().Add(15*time.Second)))
	started := time.Now()
	_, err = client.Write([]byte{5, 1, 0})
	require.NoError(t, err)
	var method [2]byte
	_, err = io.ReadFull(client, method[:])
	require.NoError(t, err, "XTCP setup must not consume the SOCKS handshake budget")
	require.Equal(t, [2]byte{5, 0}, method)
	require.Greater(t, time.Since(started), 10*time.Second)
	select {
	case <-helper.transferred:
	default:
		t.Fatal("SOCKS handshake did not use the STCP fallback")
	}
	require.NoError(t, socks5udp.WriteRequest(client, socks5udp.CmdUDPAssociate, socks5udp.Address{}))
	reply, bound, err := socks5udp.ReadReply(client)
	require.NoError(t, err)
	require.Zero(t, reply)
	require.NotZero(t, bound.Port)
}
