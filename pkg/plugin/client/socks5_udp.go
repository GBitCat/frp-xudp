// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

//go:build !frps

package client

import (
	"context"
	"fmt"
	"net"
	"sync"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
	"github.com/fatedier/frp/pkg/plugin/socks5udp"
	netpkg "github.com/fatedier/frp/pkg/util/net"
)

func init() { Register(v1.PluginSocks5UDP, NewSocks5UDPPlugin) }

type socks5EndpointKey struct{ name string }

// Socks5UDPPlugin pairs a reliable control proxy with a private UDP proxy in
// the same manager. Only authenticated control connections can mint tokens.
type Socks5UDPPlugin struct {
	opts       v1.Socks5UDPPluginOptions
	store      *sync.Map
	key        socks5EndpointKey
	endpoint   *socks5udp.Endpoint
	packetSize int
	ctx        context.Context
	cancel     context.CancelFunc
	mu         sync.Mutex
	closed     bool
	workers    sync.WaitGroup
	closeOnce  sync.Once
}

func NewSocks5UDPPlugin(pluginCtx PluginContext, options v1.ClientPluginOptions) (Plugin, error) {
	opts, ok := options.(*v1.Socks5UDPPluginOptions)
	if !ok || opts == nil {
		return nil, fmt.Errorf("invalid socks5_udp options")
	}
	if pluginCtx.SharedStore == nil {
		return nil, fmt.Errorf("socks5_udp requires a proxy manager shared store")
	}
	p := &Socks5UDPPlugin{opts: *opts, store: pluginCtx.SharedStore, packetSize: pluginCtx.UDPPacketSize}
	if p.packetSize <= 0 {
		p.packetSize = 1500
	}
	p.ctx, p.cancel = context.WithCancel(context.Background())
	switch pluginCtx.ProxyType {
	case "sudp", "xudp":
		if opts.UDPProxyName != "" || opts.Username != "" || opts.Password != "" {
			p.cancel()
			return nil, fmt.Errorf("socks5_udp credentials and udpProxyName belong on the control proxy")
		}
		p.key = socks5EndpointKey{pluginCtx.Name}
		p.endpoint = socks5udp.NewEndpoint(socks5udp.EndpointOptions{})
		if _, loaded := p.store.LoadOrStore(p.key, p.endpoint); loaded {
			p.cancel()
			_ = p.endpoint.Close()
			return nil, fmt.Errorf("socks5_udp endpoint %q is already registered", pluginCtx.Name)
		}
	case "stcp", "xtcp":
		if opts.UDPProxyName == "" || opts.UDPProxyName == pluginCtx.Name {
			p.cancel()
			return nil, fmt.Errorf("socks5_udp requires a separate udpProxyName")
		}
		p.key = socks5EndpointKey{opts.UDPProxyName}
	default:
		p.cancel()
		return nil, fmt.Errorf("socks5_udp requires STCP/XTCP or SUDP/XUDP")
	}
	return p, nil
}

func (p *Socks5UDPPlugin) Name() string { return v1.PluginSocks5UDP }

func (p *Socks5UDPPlugin) Handle(ctx context.Context, info *ConnectionInfo) {
	defer info.Conn.Close()
	p.mu.Lock()
	if p.closed || p.endpoint != nil {
		p.mu.Unlock()
		return
	}
	p.workers.Add(1)
	p.mu.Unlock()
	defer p.workers.Done()
	conn := netpkg.WrapReadWriteCloserToConn(info.Conn, info.UnderlyingConn)
	stop := context.AfterFunc(p.ctx, func() { _ = conn.Close() })
	defer stop()
	var endpoint *socks5udp.Endpoint
	if value, ok := p.store.Load(p.key); ok {
		endpoint, _ = value.(*socks5udp.Endpoint)
	}
	_ = socks5udp.ServeControl(ctx, conn, socks5udp.ControlOptions{
		Username: p.opts.Username, Password: p.opts.Password, Endpoint: endpoint,
	})
}

func (p *Socks5UDPPlugin) ServePackets(ctx context.Context, readCh <-chan *msg.UDPPacket, sendCh chan<- msg.Message) {
	if p.endpoint == nil {
		return
	}
	for {
		select {
		case <-p.ctx.Done():
			return
		case <-ctx.Done():
			return
		case packet, ok := <-readCh:
			if !ok {
				return
			}
			if packet == nil || packet.RemoteAddr == nil || len(packet.Content) > p.packetSize {
				continue
			}
			remote := *packet.RemoteAddr
			remote.IP = append(net.IP(nil), remote.IP...)
			_ = p.endpoint.HandlePacket(ctx, packet.Content, func(data []byte) {
				if len(data) > p.packetSize || ctx.Err() != nil || p.ctx.Err() != nil {
					return
				}
				response := &msg.UDPPacket{Content: data, RemoteAddr: &remote}
				select {
				case <-ctx.Done():
				case <-p.ctx.Done():
				case sendCh <- response:
				default:
				}
			})
		}
	}
}

func (p *Socks5UDPPlugin) Close() error {
	p.closeOnce.Do(func() {
		p.mu.Lock()
		p.closed = true
		p.cancel()
		p.mu.Unlock()
		if p.endpoint != nil {
			p.store.CompareAndDelete(p.key, p.endpoint)
			_ = p.endpoint.Close()
		}
		p.workers.Wait()
	})
	return nil
}
