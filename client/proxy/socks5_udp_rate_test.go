// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

//go:build !frps

package proxy

import (
	"bytes"
	"context"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"golang.org/x/time/rate"

	"github.com/fatedier/frp/pkg/config/types"
	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
	plugin "github.com/fatedier/frp/pkg/plugin/client"
	"github.com/fatedier/frp/pkg/plugin/socks5udp"
)

func TestSOCKS5UDPPrivateProxyCloseCancelsRateReservations(t *testing.T) {
	for _, proxyType := range []string{"sudp", "xudp"} {
		t.Run(proxyType, func(t *testing.T) {
			cfg := v1.NewProxyConfigurerByType(v1.ProxyType(proxyType))
			base := cfg.GetBaseConfig()
			base.Name = "rate-test-data"
			base.Plugin = v1.TypedClientPluginOptions{
				Type:                v1.PluginSocks5UDP,
				ClientPluginOptions: &v1.Socks5UDPPluginOptions{Type: v1.PluginSocks5UDP},
			}
			var err error
			base.Transport.BandwidthLimit, err = types.NewBandwidthQuantity("1KB")
			require.NoError(t, err)
			base.Transport.BandwidthLimitMode = types.BandwidthLimitModeClient
			pxy := NewProxy(plugin.WithSharedStore(context.Background()), cfg,
				&v1.ClientCommonConfig{UDPPacketSize: 1500}, nil, nil, nil, "")
			require.NoError(t, pxy.Run())
			t.Cleanup(pxy.Close)
			var limiter *rate.Limiter
			switch p := pxy.(type) {
			case *SUDPProxy:
				limiter = p.limiter
			case *XUDPProxy:
				limiter = p.limiter
			}
			var workers sync.WaitGroup
			ready := make(chan struct{}, 12)
			release := make(chan struct{})
			var releaseOnce sync.Once
			releaseReaders := func() { releaseOnce.Do(func() { close(release) }) }
			t.Cleanup(releaseReaders)
			for range 12 {
				conn, peer := net.Pipe()
				t.Cleanup(func() { _ = peer.Close() })
				workers.Go(func() {
					pxy.InWorkConn(&socks5UDPRateReadBarrier{Conn: conn, ready: ready, release: release},
						&msg.StartWorkConn{XUDPRole: msg.XUDPWorkConnRoleRelay})
				})
				workers.Go(func() {
					rw, err := msg.NewUDPPacketReadWriter(peer, "", "")
					if err == nil {
						_ = rw.WriteMsg(&msg.UDPPacket{
							Content:    bytes.Repeat([]byte{'a'}, 1000),
							RemoteAddr: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 12345},
						})
					}
				})
			}
			// Let every reader finish its small framing reads before any body
			// reserves bandwidth. Otherwise header reservations can delay other
			// bodies and prevent the intended simultaneous backlog from forming.
			for range 12 {
				select {
				case <-ready:
				case <-time.After(3 * time.Second):
					t.Fatal("work connection did not reach its UDP message body")
				}
			}
			releaseReaders()
			// More than eight seconds of reserved shared bandwidth are pending.
			// Closing sockets alone cannot interrupt this wait.
			require.Eventually(t, func() bool { return limiter.Tokens() < -8000 }, time.Second, time.Millisecond)
			done := make(chan struct{})
			go func() {
				pxy.Close()
				workers.Wait()
				close(done)
			}()
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("proxy Close did not cancel shared rate-limit reservations")
			}
		})
	}
}

type socks5UDPRateReadBarrier struct {
	net.Conn
	ready   chan<- struct{}
	release <-chan struct{}
	waited  bool
}

func (c *socks5UDPRateReadBarrier) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	if n >= 1000 && !c.waited {
		c.waited = true
		c.ready <- struct{}{}
		<-c.release
	}
	return n, err
}

func TestWorkConnCloseCancelsRateWaitBeforeCompressionCleanup(t *testing.T) {
	for _, compression := range []bool{false, true} {
		t.Run(map[bool]string{false: "plain", true: "compressed"}[compression], func(t *testing.T) {
			limiter := rate.NewLimiter(1, 1)
			require.True(t, limiter.Allow())
			pxy := &BaseProxy{ctx: context.Background(), baseCfg: &v1.ProxyBaseConfig{}, limiter: limiter}
			pxy.baseCfg.Transport.UseCompression = compression
			conn, peer := net.Pipe()
			t.Cleanup(func() { _ = peer.Close() })
			remote, recycle, err := pxy.wrapWorkConn(conn, nil)
			require.NoError(t, err)
			t.Cleanup(func() {
				_ = remote.Close()
				if recycle != nil {
					recycle()
				}
			})
			done := make(chan error, 1)
			go func() { _, err := remote.Write([]byte("payload")); done <- err }()
			require.Eventually(t, func() bool { return limiter.Tokens() < -0.5 }, time.Second, time.Millisecond)
			require.NoError(t, remote.Close())
			select {
			case err := <-done:
				require.Error(t, err)
			case <-time.After(250 * time.Millisecond):
				t.Fatal("work connection Close did not interrupt the rate-limited writer")
			}
			_, err = io.ReadAll(peer)
			require.NoError(t, err)
		})
	}
}

func TestSOCKS5UDPControlCloseCancelsRateWait(t *testing.T) {
	cfg := v1.NewProxyConfigurerByType(v1.ProxyType("stcp"))
	base := cfg.GetBaseConfig()
	base.Name = "rate-test-control"
	base.Plugin = v1.TypedClientPluginOptions{
		Type:                v1.PluginSocks5UDP,
		ClientPluginOptions: &v1.Socks5UDPPluginOptions{Type: v1.PluginSocks5UDP, UDPProxyName: "data"},
	}
	pxy := NewProxy(plugin.WithSharedStore(context.Background()), cfg,
		&v1.ClientCommonConfig{UDPPacketSize: 1500}, nil, nil, nil, "").(*GeneralTCPProxy)
	pxy.limiter = rate.NewLimiter(1, 64)
	require.True(t, pxy.limiter.AllowN(time.Now(), 64))
	require.NoError(t, pxy.Run())
	t.Cleanup(pxy.Close)
	conn, peer := net.Pipe()
	t.Cleanup(func() { _ = peer.Close() })
	done := make(chan struct{})
	go func() {
		pxy.InWorkConn(conn, &msg.StartWorkConn{})
		close(done)
	}()
	require.NoError(t, socks5udp.WriteMagic(peer))
	require.Eventually(t, func() bool { return pxy.limiter.Tokens() < -5 }, time.Second, time.Millisecond)
	closed := make(chan struct{})
	go func() {
		pxy.Close()
		close(closed)
	}()
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("control plugin Close did not cancel the rate-limited handshake read")
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("control handler remained active after plugin Close")
	}
}
