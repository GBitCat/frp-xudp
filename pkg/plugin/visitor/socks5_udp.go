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

package visitor

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"sync"
	"time"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/plugin/socks5udp"
)

const (
	// Tunnel setup includes up to 20s of XTCP hole punching followed by STCP
	// fallback (normally a 10s server dial and a 10s visitor response wait).
	// Keep it separate from the SOCKS handshake while bounding pending clients.
	socks5UDPConnectTimeout   = 60 * time.Second
	socks5UDPHandshakeTimeout = 10 * time.Second
	socks5UDPMaxConnections   = 1024
	socks5UDPBindInterval     = 2 * time.Second
)

func init() {
	Register(v1.VisitorPluginSocks5UDP, NewSocks5UDPPlugin)
}

// Socks5UDPPlugin exposes a standard SOCKS5 listener. Reliable connections use
// the owning STCP/XTCP visitor; datagrams enter a separate local SUDP/XUDP
// visitor. The local hop keeps the existing UDP transport and recovery logic
// responsible for selecting the active path.
type Socks5UDPPlugin struct {
	pluginCtx  PluginContext
	listener   net.Listener
	udpAddr    *net.UDPAddr
	packetSize int

	ctx    context.Context
	cancel context.CancelFunc

	mu      sync.Mutex
	started bool
	closed  bool
	clients map[net.Conn]net.Conn
	workers sync.WaitGroup
}

func NewSocks5UDPPlugin(pluginCtx PluginContext, options v1.VisitorPluginOptions) (Plugin, error) {
	opts, ok := options.(*v1.Socks5UDPVisitorPluginOptions)
	if !ok || opts == nil {
		return nil, errors.New("invalid socks5_udp visitor options")
	}
	if pluginCtx.SendConnToVisitor == nil {
		return nil, errors.New("socks5_udp requires a stream visitor")
	}
	host, port, err := net.SplitHostPort(opts.UDPVisitorAddr)
	if err != nil {
		return nil, fmt.Errorf("invalid udpVisitorAddr: %w", err)
	}
	ip := net.ParseIP(host)
	n, err := strconv.Atoi(port)
	if err != nil || n < 1 || n > 65535 || ip == nil || !ip.IsLoopback() {
		return nil, errors.New("udpVisitorAddr must be a loopback IP and a valid port")
	}
	bindAddr := opts.BindAddr
	if bindAddr == "" {
		bindAddr = "127.0.0.1"
	}
	listener, err := net.Listen("tcp", net.JoinHostPort(bindAddr, strconv.Itoa(opts.BindPort)))
	if err != nil {
		return nil, fmt.Errorf("listen for socks5_udp: %w", err)
	}
	parent := pluginCtx.Ctx
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithCancel(parent)
	packetSize := pluginCtx.UDPPacketSize
	if packetSize <= 0 {
		packetSize = 1500
	}
	return &Socks5UDPPlugin{
		pluginCtx:  pluginCtx,
		listener:   listener,
		udpAddr:    &net.UDPAddr{IP: ip, Port: n},
		packetSize: packetSize,
		ctx:        ctx,
		cancel:     cancel,
		clients:    make(map[net.Conn]net.Conn),
	}, nil
}

func (p *Socks5UDPPlugin) Name() string { return v1.VisitorPluginSocks5UDP }

func (p *Socks5UDPPlugin) Start() {
	p.mu.Lock()
	if p.started || p.closed {
		p.mu.Unlock()
		return
	}
	p.started = true
	p.workers.Add(2)
	p.mu.Unlock()
	go func() {
		defer p.workers.Done()
		p.acceptLoop()
	}()
	go func() {
		defer p.workers.Done()
		<-p.ctx.Done()
		p.shutdown()
	}()
}

func (p *Socks5UDPPlugin) shutdown() {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return
	}
	p.closed = true
	p.cancel()
	_ = p.listener.Close()
	for client, control := range p.clients {
		_ = client.Close()
		_ = control.Close()
	}
	p.mu.Unlock()
}

func (p *Socks5UDPPlugin) Close() error {
	p.shutdown()
	p.workers.Wait()
	return nil
}

func (p *Socks5UDPPlugin) acceptLoop() {
	for {
		client, err := p.listener.Accept()
		if err != nil {
			return
		}
		control, visitorConn := net.Pipe()
		p.mu.Lock()
		if p.closed || len(p.clients) >= socks5UDPMaxConnections {
			p.mu.Unlock()
			_ = client.Close()
			_ = control.Close()
			_ = visitorConn.Close()
			continue
		}
		p.clients[client] = control
		p.workers.Add(1)
		p.mu.Unlock()
		go func() {
			defer p.workers.Done()
			defer func() {
				_ = client.Close()
				_ = control.Close()
				_ = visitorConn.Close()
				p.mu.Lock()
				delete(p.clients, client)
				p.mu.Unlock()
			}()
			p.pluginCtx.SendConnToVisitor(visitorConn)
			p.handle(client, control)
		}()
	}
}

func (p *Socks5UDPPlugin) handle(client, control net.Conn) {
	// control is a synchronous net.Pipe: the visitor only consumes its bytes
	// after its transport (including any fallback) is ready to relay them.
	_ = control.SetWriteDeadline(time.Now().Add(socks5UDPConnectTimeout))
	if err := socks5udp.WriteMagic(control); err != nil {
		return
	}
	deadline := time.Now().Add(socks5UDPHandshakeTimeout)
	_ = client.SetDeadline(deadline)
	_ = control.SetDeadline(deadline)
	if err := relaySOCKS5Auth(client, control); err != nil {
		return
	}
	command, address, err := socks5udp.ReadRequest(client)
	if err != nil {
		_ = socks5udp.WriteReply(client, 1, socks5udp.Address{})
		return
	}
	if command != socks5udp.CmdConnect && command != socks5udp.CmdUDPAssociate {
		_ = socks5udp.WriteReply(client, 7, socks5udp.Address{})
		return
	}
	if command == socks5udp.CmdUDPAssociate {
		p.associate(client, control, address)
		return
	}
	if err := socks5udp.WriteRequest(control, command, address); err != nil {
		return
	}
	reply, bound, err := socks5udp.ReadReply(control)
	if err != nil {
		_ = socks5udp.WriteReply(client, 1, socks5udp.Address{})
		return
	}
	if err := socks5udp.WriteReply(client, reply, bound); err != nil || reply != 0 {
		return
	}
	_ = client.SetDeadline(time.Time{})
	_ = control.SetDeadline(time.Time{})
	joinSOCKS5(client, control)
}

// relaySOCKS5Auth leaves credential validation at the providing frpc. Only
// bounded SOCKS5 greeting and RFC 1929 authentication frames cross this relay.
func relaySOCKS5Auth(client, control net.Conn) error {
	var greeting [2]byte
	if _, err := io.ReadFull(client, greeting[:]); err != nil {
		return err
	}
	if greeting[0] != 5 || greeting[1] == 0 {
		return errors.New("invalid SOCKS5 greeting")
	}
	methods := make([]byte, int(greeting[1]))
	if _, err := io.ReadFull(client, methods); err != nil {
		return err
	}
	if _, err := control.Write(append(greeting[:], methods...)); err != nil {
		return err
	}
	var selected [2]byte
	if _, err := io.ReadFull(control, selected[:]); err != nil {
		return err
	}
	if selected[0] != 5 {
		return errors.New("invalid SOCKS5 method response")
	}
	if _, err := client.Write(selected[:]); err != nil {
		return err
	}
	switch selected[1] {
	case 0:
		return nil
	case 2:
		var head [2]byte
		if _, err := io.ReadFull(client, head[:]); err != nil {
			return err
		}
		if head[0] != 1 {
			return errors.New("invalid SOCKS5 authentication")
		}
		credentials := make([]byte, int(head[1])+1)
		if _, err := io.ReadFull(client, credentials); err != nil {
			return err
		}
		passwordLength := int(credentials[len(credentials)-1])
		password := make([]byte, passwordLength)
		if _, err := io.ReadFull(client, password); err != nil {
			return err
		}
		frame := append(head[:], credentials...)
		frame = append(frame, password...)
		if _, err := control.Write(frame); err != nil {
			return err
		}
		var authReply [2]byte
		if _, err := io.ReadFull(control, authReply[:]); err != nil {
			return err
		}
		if _, err := client.Write(authReply[:]); err != nil {
			return err
		}
		if authReply[0] != 1 || authReply[1] != 0 {
			return errors.New("SOCKS5 authentication failed")
		}
		return nil
	default:
		return errors.New("no supported SOCKS5 authentication method")
	}
}

func (p *Socks5UDPPlugin) associate(client, control net.Conn, source socks5udp.Address) {
	peer, ok := client.RemoteAddr().(*net.TCPAddr)
	if !ok {
		_ = socks5udp.WriteReply(client, 1, socks5udp.Address{})
		return
	}
	sourceIP := net.ParseIP(source.Host)
	if sourceIP == nil || (!sourceIP.IsUnspecified() && !sourceIP.Equal(peer.IP)) {
		_ = socks5udp.WriteReply(client, 2, socks5udp.Address{})
		return
	}
	local, ok := client.LocalAddr().(*net.TCPAddr)
	if !ok {
		return
	}
	udpConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: local.IP, Zone: local.Zone})
	if err != nil {
		_ = socks5udp.WriteReply(client, 1, socks5udp.Address{})
		return
	}
	defer udpConn.Close()
	upstream, err := net.DialUDP("udp", nil, p.udpAddr)
	if err != nil {
		_ = socks5udp.WriteReply(client, 1, socks5udp.Address{})
		return
	}
	defer upstream.Close()
	if err := socks5udp.WriteRequest(control, socks5udp.CmdUDPAssociate, source); err != nil {
		return
	}
	reply, _, err := socks5udp.ReadReply(control)
	if err != nil || reply != 0 {
		if err != nil {
			reply = 1
		}
		_ = socks5udp.WriteReply(client, reply, socks5udp.Address{})
		return
	}
	token, err := socks5udp.ReadToken(control)
	if err != nil {
		_ = socks5udp.WriteReply(client, 1, socks5udp.Address{})
		return
	}
	bound := udpConn.LocalAddr().(*net.UDPAddr)
	if err := socks5udp.WriteReply(client, 0, socks5udp.Address{Host: bound.IP.String(), Port: uint16(bound.Port)}); err != nil {
		return
	}
	_ = client.SetDeadline(time.Time{})
	_ = control.SetDeadline(time.Time{})

	var closeOnce sync.Once
	stopped := make(chan struct{})
	stop := func() {
		closeOnce.Do(func() {
			close(stopped)
			_ = udpConn.Close()
			_ = upstream.Close()
			_ = client.Close()
			_ = control.Close()
		})
	}
	defer stop()
	var group sync.WaitGroup
	group.Add(4)
	go func() {
		defer group.Done()
		// Refresh the return route even when the application only receives
		// data. The capability-only frame follows the current SUDP/XUDP path
		// and never becomes a packet sent to a target service.
		bind := socks5udp.EncodeDatagram(token, nil)
		if len(bind) > p.packetSize {
			return
		}
		ticker := time.NewTicker(socks5UDPBindInterval)
		defer ticker.Stop()
		for {
			select {
			case <-stopped:
				return
			default:
			}
			_, _ = upstream.Write(bind)
			select {
			case <-stopped:
				return
			case <-ticker.C:
			}
		}
	}()
	go func() {
		defer group.Done()
		defer stop()
		// Any EOF, read error, or unexpected extra control bytes end the
		// association. Datagram traffic never uses this reliable connection.
		var b [1]byte
		_, _ = client.Read(b[:])
	}()
	go func() {
		defer group.Done()
		defer stop()
		var b [1]byte
		_, _ = control.Read(b[:])
	}()
	var sourceMu sync.Mutex
	var clientUDPAddr *net.UDPAddr
	go func() {
		defer group.Done()
		defer stop()
		buf := make([]byte, 65535)
		for {
			n, err := upstream.Read(buf)
			if err != nil {
				// A loopback visitor may temporarily disappear during reload.
				// Keep the SOCKS association alive across those UDP errors.
				if errors.Is(err, net.ErrClosed) {
					return
				}
				continue
			}
			if n > p.packetSize {
				continue
			}
			receivedToken, packet, err := socks5udp.DecodeDatagram(buf[:n])
			if err != nil || receivedToken != token {
				continue
			}
			if _, _, err := socks5udp.ParseUDP(packet); err != nil {
				continue
			}
			sourceMu.Lock()
			addr := clientUDPAddr
			sourceMu.Unlock()
			if addr != nil {
				_, _ = udpConn.WriteToUDP(packet, addr)
			}
		}
	}()
	buf := make([]byte, 65535)
	for {
		n, addr, err := udpConn.ReadFromUDP(buf)
		if err != nil {
			break
		}
		if !addr.IP.Equal(peer.IP) || (source.Port != 0 && addr.Port != int(source.Port)) {
			continue
		}
		if _, _, err := socks5udp.ParseUDP(buf[:n]); err != nil {
			continue
		}
		encoded := socks5udp.EncodeDatagram(token, buf[:n])
		if len(encoded) > p.packetSize {
			continue
		}
		sourceMu.Lock()
		if clientUDPAddr == nil {
			clientUDPAddr = addr
		}
		matches := clientUDPAddr.Port == addr.Port
		sourceMu.Unlock()
		if !matches {
			continue
		}
		_, _ = upstream.Write(encoded)
	}
	stop()
	group.Wait()
}

func joinSOCKS5(client, control net.Conn) {
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _ = io.Copy(control, client)
		_ = control.Close()
		_ = client.Close()
	}()
	_, _ = io.Copy(client, control)
	_ = client.Close()
	_ = control.Close()
	<-done
}
