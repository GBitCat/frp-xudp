// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

package socks5udp

import (
	"context"
	"crypto/rand"
	"errors"
	"net"
	"sync"
	"time"
)

var (
	ErrAssociationNotFound = errors.New("SOCKS5 UDP association not found")
	ErrCapacity            = errors.New("SOCKS5 UDP capacity exceeded")
)

// EndpointOptions bounds the resources used by one UDP proxy. Zero values use
// conservative defaults. Target limits apply to cached destination addresses.
// IdleTimeout expires those addresses and their permission to send replies;
// sockets with no remaining targets are closed. The TCP connection controls
// the association's lifetime.
type EndpointOptions struct {
	MaxAssociations          int
	MaxTargetsPerAssociation int
	MaxTargets               int
	IdleTimeout              time.Duration
	DialTimeout              time.Duration
}

type Endpoint struct {
	mu           sync.Mutex
	closed       bool
	associations map[Token]*association
	options      EndpointOptions
	targetSlots  chan struct{}
}

func NewEndpoint(options EndpointOptions) *Endpoint {
	if options.MaxAssociations <= 0 {
		options.MaxAssociations = 1024
	}
	if options.MaxTargetsPerAssociation <= 0 {
		options.MaxTargetsPerAssociation = 64
	}
	if options.MaxTargets <= 0 {
		options.MaxTargets = 4096
	}
	if options.IdleTimeout <= 0 {
		options.IdleTimeout = 2 * time.Minute
	}
	if options.DialTimeout <= 0 {
		options.DialTimeout = 5 * time.Second
	}
	return &Endpoint{
		associations: make(map[Token]*association), options: options,
		targetSlots: make(chan struct{}, options.MaxTargets),
	}
}

type returnRoute struct {
	ctx   context.Context
	reply func([]byte)
}

type packetJob struct {
	address Address
	payload []byte
	route   returnRoute
}

type association struct {
	endpoint *Endpoint
	token    Token
	control  net.Conn
	ctx      context.Context
	cancel   context.CancelFunc
	jobs     chan packetJob
	wg       sync.WaitGroup
	mu       sync.Mutex
	closed   bool
	targets  map[string]*targetAddress
	sockets  map[string]*egressSocket
	route    returnRoute
}

type targetAddress struct {
	address *net.UDPAddr
	network string
	expires time.Time
}

// Each association shares one unconnected socket per address family. Besides
// accepting a server's replies from another port (for example TFTP), this keeps
// the client's source port stable when it sends to that new server port.
type egressSocket struct {
	conn    *net.UDPConn
	network string
}

func (e *Endpoint) addAssociation(ctx context.Context, control net.Conn) (*association, error) {
	var token Token
	if _, err := rand.Read(token[:]); err != nil {
		return nil, err
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.closed {
		return nil, net.ErrClosed
	}
	if len(e.associations) >= e.options.MaxAssociations {
		return nil, ErrCapacity
	}
	// Refuse a collision rather than replacing another control connection.
	if _, exists := e.associations[token]; exists {
		return nil, ErrCapacity
	}
	ctx, cancel := context.WithCancel(ctx)
	a := &association{
		endpoint: e, token: token, control: control, ctx: ctx, cancel: cancel,
		jobs: make(chan packetJob, 64), targets: make(map[string]*targetAddress),
		sockets: make(map[string]*egressSocket),
	}
	a.wg.Add(1)
	e.associations[token] = a
	go a.run()
	return a, nil
}

func (e *Endpoint) removeAssociation(a *association) {
	e.mu.Lock()
	if e.associations[a.token] == a {
		delete(e.associations, a.token)
	}
	e.mu.Unlock()
	a.shutdown()
	a.wg.Wait()
}

// HandlePacket queues one capability-authenticated datagram. DNS and network
// operations run outside the caller's transport reader. reply must not block;
// it should enqueue onto its transport or drop when that queue is full. Its
// context identifies the active transport and prevents replies using a retired
// P2P/relay path. The endpoint retains target sockets across those path changes.
// A token-only envelope binds the return route synchronously without creating
// a target socket or producing any response.
func (e *Endpoint) HandlePacket(ctx context.Context, payload []byte, reply func([]byte)) error {
	if ctx == nil || reply == nil {
		return ErrInvalidPacket
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	token, packet, err := DecodeDatagram(payload)
	if err != nil {
		return err
	}
	var address Address
	var data []byte
	if len(packet) != 0 {
		address, data, err = ParseUDP(packet)
		if err != nil {
			return err
		}
	}
	e.mu.Lock()
	a := e.associations[token]
	closed := e.closed
	e.mu.Unlock()
	if closed {
		return net.ErrClosed
	}
	if a == nil {
		return ErrAssociationNotFound
	}
	job := packetJob{address: address, payload: append([]byte(nil), data...), route: returnRoute{ctx: ctx, reply: reply}}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.closed {
		return ErrAssociationNotFound
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if len(packet) == 0 {
		a.route = job.route
		return nil
	}
	select {
	case a.jobs <- job:
		return nil
	default:
		return ErrCapacity
	}
}

func (e *Endpoint) Close() error {
	e.mu.Lock()
	if e.closed {
		e.mu.Unlock()
		return nil
	}
	e.closed = true
	associations := make([]*association, 0, len(e.associations))
	for _, a := range e.associations {
		associations = append(associations, a)
	}
	clear(e.associations)
	e.mu.Unlock()
	for _, a := range associations {
		a.shutdown()
	}
	for _, a := range associations {
		a.wg.Wait()
	}
	return nil
}

func (a *association) shutdown() {
	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		return
	}
	a.closed = true
	a.cancel()
	for range a.targets {
		<-a.endpoint.targetSlots
	}
	clear(a.targets)
	for _, socket := range a.sockets {
		_ = socket.conn.Close()
	}
	clear(a.sockets)
	a.mu.Unlock()
	_ = a.control.Close()
}

func (a *association) run() {
	defer a.wg.Done()
	ticker := time.NewTicker(min(a.endpoint.options.IdleTimeout, time.Second))
	defer ticker.Stop()
	for {
		select {
		case <-a.ctx.Done():
			return
		case now := <-ticker.C:
			a.mu.Lock()
			a.expireTargetsLocked(now)
			a.mu.Unlock()
		case job := <-a.jobs:
			if job.route.ctx.Err() != nil {
				continue
			}
			a.mu.Lock()
			if a.closed {
				a.mu.Unlock()
				return
			}
			a.route = job.route
			a.mu.Unlock()
			target, socket, err := a.target(job.address)
			if err != nil {
				continue
			}
			// The route could have been retired while DNS was resolving.
			if job.route.ctx.Err() != nil || a.ctx.Err() != nil {
				continue
			}
			_ = socket.conn.SetWriteDeadline(time.Now().Add(a.endpoint.options.DialTimeout))
			if _, err := socket.conn.WriteToUDP(job.payload, target.address); err != nil {
				a.removeTarget(job.address.String(), target)
			}
		}
	}
}

func (a *association) target(address Address) (*targetAddress, *egressSocket, error) {
	key := address.String()
	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		return nil, nil, net.ErrClosed
	}
	a.expireTargetsLocked(time.Now())
	if target := a.targets[key]; target != nil {
		target.expires = time.Now().Add(a.endpoint.options.IdleTimeout)
		socket := a.sockets[target.network]
		a.mu.Unlock()
		return target, socket, nil
	}
	if len(a.targets) >= a.endpoint.options.MaxTargetsPerAssociation {
		a.mu.Unlock()
		return nil, nil, ErrCapacity
	}
	a.mu.Unlock()
	ctx, cancel := context.WithTimeout(a.ctx, a.endpoint.options.DialTimeout)
	defer cancel()
	ips, err := net.DefaultResolver.LookupIPAddr(ctx, address.Host)
	if err != nil {
		return nil, nil, err
	}
	if len(ips) == 0 {
		return nil, nil, &net.DNSError{Err: "no such host", Name: address.Host, IsNotFound: true}
	}
	// Match the usual UDP address selection: prefer IPv4 when a hostname has
	// both families. A literal IPv6 destination still selects IPv6 directly.
	ip := ips[0]
	for _, candidate := range ips {
		if candidate.IP.To4() != nil {
			ip = candidate
			break
		}
	}
	network := "udp6"
	if ip.IP.To4() != nil {
		network = "udp4"
	}
	target := &targetAddress{
		address: &net.UDPAddr{IP: ip.IP, Port: int(address.Port), Zone: ip.Zone},
		network: network, expires: time.Now().Add(a.endpoint.options.IdleTimeout),
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.closed {
		return nil, nil, net.ErrClosed
	}
	select {
	case a.endpoint.targetSlots <- struct{}{}:
	default:
		return nil, nil, ErrCapacity
	}
	socket := a.sockets[network]
	if socket == nil {
		conn, err := net.ListenUDP(network, &net.UDPAddr{})
		if err != nil {
			<-a.endpoint.targetSlots
			return nil, nil, err
		}
		socket = &egressSocket{conn: conn, network: network}
		a.sockets[network] = socket
		a.wg.Add(1)
		go a.readSocket(socket)
	}
	a.targets[key] = target
	return target, socket, nil
}

func (a *association) removeTarget(key string, target *targetAddress) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.targets[key] == target {
		delete(a.targets, key)
		<-a.endpoint.targetSlots
	}
	a.closeUnusedSocketsLocked()
}

func (a *association) expireTargetsLocked(now time.Time) {
	for key, target := range a.targets {
		if !target.expires.After(now) {
			delete(a.targets, key)
			<-a.endpoint.targetSlots
		}
	}
	a.closeUnusedSocketsLocked()
}

func (a *association) closeUnusedSocketsLocked() {
	for network, socket := range a.sockets {
		used := false
		for _, target := range a.targets {
			if target.network == network {
				used = true
				break
			}
		}
		if !used {
			delete(a.sockets, network)
			_ = socket.conn.Close()
		}
	}
}

func (a *association) removeSocket(socket *egressSocket) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.sockets[socket.network] == socket {
		delete(a.sockets, socket.network)
		for key, target := range a.targets {
			if target.network == socket.network {
				delete(a.targets, key)
				<-a.endpoint.targetSlots
			}
		}
	}
	_ = socket.conn.Close()
}

func (a *association) readSocket(socket *egressSocket) {
	defer a.wg.Done()
	defer a.removeSocket(socket)
	buffer := make([]byte, 65535)
	for {
		n, source, err := socket.conn.ReadFromUDP(buffer)
		if err != nil {
			return
		}
		a.mu.Lock()
		route, closed := a.route, a.closed
		allowed := false
		now := time.Now()
		for _, target := range a.targets {
			// Some UDP protocols reply from a different port. Accept any port
			// of a recently contacted IP, but never an unsolicited source IP.
			if target.expires.After(now) && target.address.IP.Equal(source.IP) && target.address.Zone == source.Zone {
				target.expires = now.Add(a.endpoint.options.IdleTimeout)
				allowed = true
			}
		}
		a.mu.Unlock()
		if closed {
			return
		}
		if !allowed || route.ctx == nil || route.ctx.Err() != nil {
			continue
		}
		packet, err := BuildUDP(AddressFromNetAddr(source), buffer[:n])
		if err != nil {
			continue
		}
		route.reply(EncodeDatagram(a.token, packet))
	}
}
