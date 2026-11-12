// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

package proxy

import (
	"context"
	"fmt"
	"net"
	"sync"
	"time"

	"github.com/fatedier/frp/pkg/msg"
	plugin "github.com/fatedier/frp/pkg/plugin/client"
	"github.com/fatedier/frp/pkg/proto/udp"
	netpkg "github.com/fatedier/frp/pkg/util/net"
)

func (pxy *BaseProxy) runDatagramPlugin() error {
	if err := pxy.Run(); err != nil {
		return err
	}
	if _, ok := pxy.proxyPlugin.(plugin.DatagramPlugin); !ok {
		pxy.Close()
		return fmt.Errorf("plugin %q does not support datagrams", pxy.baseCfg.Plugin.Type)
	}
	return nil
}

func (pxy *BaseProxy) forwardDatagrams(ctx context.Context, localAddr *net.UDPAddr,
	readCh <-chan *msg.UDPPacket, sendCh chan<- msg.Message,
) {
	if p, ok := pxy.proxyPlugin.(plugin.DatagramPlugin); ok {
		p.ServePackets(ctx, readCh, sendCh)
		return
	}
	udp.ManagedForwarder(ctx, localAddr, readCh, sendCh, int(pxy.clientCfg.UDPPacketSize), pxy.baseCfg.Transport.ProxyProtocolVersion)
}

// serveDatagramWorkConn owns all workers and never closes their data channels.
// A canceled route may still be held by a live SOCKS5 association after XUDP
// changes transports, so its reply callback must remain safe after return.
func (pxy *BaseProxy) serveDatagramWorkConn(ctx context.Context, conn net.Conn) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	defer conn.Close()
	remote, recycle, err := pxy.wrapWorkConnWithContext(ctx, conn, pxy.encryptionKey)
	if err != nil {
		return
	}
	if recycle != nil {
		defer recycle()
	}
	defer remote.Close()
	workConn := netpkg.WrapReadWriteCloserToConn(remote, conn)
	rw, err := msg.NewUDPPacketReadWriter(workConn, pxy.clientCfg.Transport.WireProtocol, pxy.udpPacketCodec)
	if err != nil {
		return
	}
	stop := context.AfterFunc(ctx, func() { _ = workConn.Close() })
	defer stop()
	readCh := make(chan *msg.UDPPacket, 1024)
	sendCh := make(chan msg.Message, 1024)
	var workers sync.WaitGroup
	for _, worker := range []func(){
		func() {
			for {
				var packet msg.UDPPacket
				if err := rw.ReadMsgInto(&packet); err != nil {
					return
				}
				select {
				case <-ctx.Done():
					return
				case readCh <- &packet:
				}
			}
		},
		func() {
			ticker := time.NewTicker(30 * time.Second)
			defer ticker.Stop()
			for {
				var packet msg.Message
				select {
				case <-ctx.Done():
					return
				case packet = <-sendCh:
				case <-ticker.C:
					packet = &msg.Ping{}
				}
				if err := rw.WriteMsg(packet); err != nil {
					return
				}
			}
		},
		func() { pxy.forwardDatagrams(ctx, nil, readCh, sendCh) },
	} {
		workers.Go(func() { defer cancel(); worker() })
	}
	workers.Wait()
}
