// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0.

//go:build !frps

package client

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
)

func TestSocks5UDPEndpointRegistryOwnership(t *testing.T) {
	first, second := &sync.Map{}, &sync.Map{}
	opts := &v1.Socks5UDPPluginOptions{Type: v1.PluginSocks5UDP}
	makePlugin := func(store *sync.Map) (Plugin, error) {
		return NewSocks5UDPPlugin(PluginContext{Name: "data", ProxyType: "xudp", SharedStore: store}, opts)
	}
	a, err := makePlugin(first)
	require.NoError(t, err)
	t.Cleanup(func() { _ = a.Close() })
	_, err = makePlugin(first)
	require.Error(t, err, "an existing endpoint must not be silently replaced")
	b, err := makePlugin(second)
	require.NoError(t, err, "same names in separate frpc managers must be isolated")
	t.Cleanup(func() { _ = b.Close() })
	require.NoError(t, a.Close())
	c, err := makePlugin(first)
	require.NoError(t, err, "closed endpoint must release its registration")
	t.Cleanup(func() { _ = c.Close() })
	require.NoError(t, a.Close())
	_, err = makePlugin(first)
	require.Error(t, err, "closing a retired plugin must not unregister the replacement")
}

func TestSocks5UDPPluginCloseStopsPacketWorker(t *testing.T) {
	p, err := NewSocks5UDPPlugin(PluginContext{Name: "data", ProxyType: "sudp", SharedStore: &sync.Map{}},
		&v1.Socks5UDPPluginOptions{Type: v1.PluginSocks5UDP})
	require.NoError(t, err)
	done := make(chan struct{})
	go func() {
		p.(DatagramPlugin).ServePackets(context.Background(), make(chan *msg.UDPPacket), make(chan msg.Message))
		close(done)
	}()
	require.NoError(t, p.Close())
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("packet worker survived plugin close")
	}
}
