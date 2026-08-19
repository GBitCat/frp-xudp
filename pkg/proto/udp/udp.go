// Copyright 2017 fatedier, fatedier@gmail.com
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

package udp

import (
	"context"
	"net"
	"sync"
	"time"

	"github.com/fatedier/golib/errors"
	"github.com/fatedier/golib/pool"

	"github.com/fatedier/frp/pkg/msg"
	netpkg "github.com/fatedier/frp/pkg/util/net"
)

func NewUDPPacket(buf []byte, laddr, raddr *net.UDPAddr) *msg.UDPPacket {
	content := make([]byte, len(buf))
	copy(content, buf)
	return &msg.UDPPacket{
		Content:    content,
		LocalAddr:  laddr,
		RemoteAddr: raddr,
	}
}

func GetContent(m *msg.UDPPacket) (buf []byte, err error) {
	return m.Content, nil
}

type userConn interface {
	ReadFromUDP([]byte) (int, *net.UDPAddr, error)
	WriteToUDP([]byte, *net.UDPAddr) (int, error)
	Close() error
}

type managedConn struct {
	conn      managedUDPConn
	closeOnce sync.Once
}

func (c *managedConn) close() {
	c.closeOnce.Do(func() { _ = c.conn.Close() })
}

// managedUDPConn is the part of *net.UDPConn used by ManagedForwarder. It is
// private so production callers keep the existing API while tests can provide
// a connection whose blocking Write is released by Close.
type managedUDPConn interface {
	Close() error
	ReadFromUDP([]byte) (int, *net.UDPAddr, error)
	SetReadDeadline(time.Time) error
	Write([]byte) (int, error)
}

// ForwardUserConn takes ownership of udpConn. It closes the socket before
// returning and waits for both forwarding directions to stop. Callers may close
// udpConn concurrently to request shutdown; net.UDPConn.Close is idempotent.
func ForwardUserConn(udpConn *net.UDPConn, readCh <-chan *msg.UDPPacket, sendCh chan<- *msg.UDPPacket, bufSize int) {
	forwardUserConn(udpConn, readCh, sendCh, bufSize)
}

func forwardUserConn(udpConn userConn, readCh <-chan *msg.UDPPacket, sendCh chan<- *msg.UDPPacket, bufSize int) {
	forwardUserConnWithWriteHook(udpConn, readCh, sendCh, bufSize, nil)
}

func forwardUserConnWithWriteHook(
	udpConn userConn,
	readCh <-chan *msg.UDPPacket,
	sendCh chan<- *msg.UDPPacket,
	bufSize int,
	beforeWrite func(),
) {
	stopWriter := make(chan struct{})
	writerDone := make(chan struct{})
	defer func() {
		close(stopWriter)
		_ = udpConn.Close()
		<-writerDone
	}()

	// Write packets received from the forwarding path back to UDP users.
	go func() {
		defer close(writerDone)
		for {
			var udpMsg *msg.UDPPacket
			select {
			case <-stopWriter:
				return
			case m, ok := <-readCh:
				if !ok {
					return
				}
				udpMsg = m
			}
			if beforeWrite != nil {
				beforeWrite()
			}
			select {
			case <-stopWriter:
				return
			default:
			}
			buf, err := GetContent(udpMsg)
			if err != nil {
				continue
			}
			_, _ = udpConn.WriteToUDP(buf, udpMsg.RemoteAddr)
		}
	}()

	// write
	buf := pool.GetBuf(bufSize)
	defer pool.PutBuf(buf)
	for {
		n, remoteAddr, err := udpConn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		// NewUDPPacket copies buf[:n], so the read buffer can be reused
		udpMsg := NewUDPPacket(buf[:n], nil, remoteAddr)

		if err = errors.PanicToError(func() {
			select {
			case sendCh <- udpMsg:
			default:
			}
		}); err != nil {
			return
		}
	}
}

func Forwarder(dstAddr *net.UDPAddr, readCh <-chan *msg.UDPPacket, sendCh chan<- msg.Message, bufSize int, proxyProtocolVersion string) {
	var mu sync.RWMutex
	udpConnMap := make(map[string]*net.UDPConn)

	// read from dstAddr and write to sendCh
	writerFn := func(raddr *net.UDPAddr, udpConn *net.UDPConn) {
		addr := raddr.String()
		defer func() {
			mu.Lock()
			delete(udpConnMap, addr)
			mu.Unlock()
			udpConn.Close()
		}()

		buf := pool.GetBuf(bufSize)
		defer pool.PutBuf(buf)
		for {
			_ = udpConn.SetReadDeadline(time.Now().Add(30 * time.Second))
			n, _, err := udpConn.ReadFromUDP(buf)
			if err != nil {
				return
			}

			udpMsg := NewUDPPacket(buf[:n], nil, raddr)
			if err = errors.PanicToError(func() {
				select {
				case sendCh <- udpMsg:
				default:
				}
			}); err != nil {
				return
			}
		}
	}

	// read from readCh
	go func() {
		for udpMsg := range readCh {
			buf, err := GetContent(udpMsg)
			if err != nil {
				continue
			}

			mu.Lock()
			udpConn, ok := udpConnMap[udpMsg.RemoteAddr.String()]
			if !ok {
				udpConn, err = net.DialUDP("udp", nil, dstAddr)
				if err != nil {
					mu.Unlock()
					continue
				}
				udpConnMap[udpMsg.RemoteAddr.String()] = udpConn
			}
			mu.Unlock()

			// Add proxy protocol header if configured (only for the first packet of a new connection)
			if !ok && proxyProtocolVersion != "" && udpMsg.RemoteAddr != nil {
				ppBuf, err := netpkg.BuildProxyProtocolHeader(udpMsg.RemoteAddr, dstAddr, proxyProtocolVersion)
				if err == nil {
					// Prepend proxy protocol header to the UDP payload
					finalBuf := make([]byte, len(ppBuf)+len(buf))
					copy(finalBuf, ppBuf)
					copy(finalBuf[len(ppBuf):], buf)
					buf = finalBuf
				}
			}

			_, err = udpConn.Write(buf)
			if err != nil {
				udpConn.Close()
			} else {
				_ = udpConn.SetReadDeadline(time.Now().Add(30 * time.Second))
			}

			if !ok {
				go writerFn(udpMsg.RemoteAddr, udpConn)
			}
		}
	}()
}

// ManagedForwarder forwards UDP packets until ctx is canceled or readCh is
// closed. Unlike Forwarder, it blocks until its dispatcher and every per-user
// UDP reader have exited. It never closes readCh or sendCh; their ownership
// remains with the caller.
func ManagedForwarder(
	ctx context.Context,
	dstAddr *net.UDPAddr,
	readCh <-chan *msg.UDPPacket,
	sendCh chan<- msg.Message,
	bufSize int,
	proxyProtocolVersion string,
) {
	managedForwarder(ctx, dstAddr, readCh, sendCh, bufSize, proxyProtocolVersion, func(addr *net.UDPAddr) (managedUDPConn, error) {
		return net.DialUDP("udp", nil, addr)
	})
}

func managedForwarder(
	parentCtx context.Context,
	dstAddr *net.UDPAddr,
	readCh <-chan *msg.UDPPacket,
	sendCh chan<- msg.Message,
	bufSize int,
	proxyProtocolVersion string,
	dial func(*net.UDPAddr) (managedUDPConn, error),
) {
	ctx, cancel := context.WithCancel(parentCtx)
	defer cancel()

	var (
		mu          sync.Mutex
		udpConnMap  = make(map[string]*managedConn)
		stopped     bool
		readerGroup sync.WaitGroup
		closeOnce   sync.Once
		watcherDone = make(chan struct{})
	)

	removeAndClose := func(key string, entry *managedConn) {
		removeManagedConn(&mu, udpConnMap, key, entry)
	}

	startReader := func(key string, raddr *net.UDPAddr, entry *managedConn) {
		readerGroup.Add(1)
		go func() {
			defer readerGroup.Done()
			defer removeAndClose(key, entry)

			buf := pool.GetBuf(bufSize)
			defer pool.PutBuf(buf)
			for {
				_ = entry.conn.SetReadDeadline(time.Now().Add(30 * time.Second))
				n, _, err := entry.conn.ReadFromUDP(buf)
				if err != nil {
					return
				}

				udpMsg := NewUDPPacket(buf[:n], nil, raddr)
				if err = errors.PanicToError(func() {
					select {
					case <-ctx.Done():
					case sendCh <- udpMsg:
					default:
					}
				}); err != nil {
					return
				}
				select {
				case <-ctx.Done():
					return
				default:
				}
			}
		}()
	}

	closeAll := func() {
		closeOnce.Do(func() {
			mu.Lock()
			stopped = true
			entries := make([]*managedConn, 0, len(udpConnMap))
			for _, entry := range udpConnMap {
				entries = append(entries, entry)
			}
			mu.Unlock()
			for _, entry := range entries {
				entry.close()
			}
		})
	}

	// The dispatcher may be blocked in a user-controlled UDP Write. Keep
	// cancellation and socket closure on an independent goroutine so that a
	// canceled context can always interrupt that Write/Read.
	go func() {
		defer close(watcherDone)
		<-ctx.Done()
		closeAll()
	}()

	defer func() {
		cancel()
		closeAll()
		readerGroup.Wait()
		<-watcherDone
	}()

	for {
		var udpMsg *msg.UDPPacket
		select {
		case <-ctx.Done():
			return
		case m, ok := <-readCh:
			if !ok {
				return
			}
			udpMsg = m
		}
		if udpMsg == nil || udpMsg.RemoteAddr == nil {
			continue
		}

		buf, err := GetContent(udpMsg)
		if err != nil {
			continue
		}
		key := udpMsg.RemoteAddr.String()

		mu.Lock()
		if stopped || ctx.Err() != nil {
			mu.Unlock()
			return
		}
		entry, ok := udpConnMap[key]
		if !ok {
			mu.Unlock()
			udpConn, dialErr := dial(dstAddr)
			if dialErr != nil {
				continue
			}
			mu.Lock()
			if stopped || ctx.Err() != nil {
				mu.Unlock()
				_ = udpConn.Close()
				return
			}
			entry = &managedConn{conn: udpConn}
			udpConnMap[key] = entry
			startReader(key, udpMsg.RemoteAddr, entry)
		}
		mu.Unlock()

		// Add a proxy protocol header only to the first packet sent through a
		// newly-created local UDP connection.
		if !ok && proxyProtocolVersion != "" {
			ppBuf, buildErr := netpkg.BuildProxyProtocolHeader(udpMsg.RemoteAddr, dstAddr, proxyProtocolVersion)
			if buildErr == nil {
				finalBuf := make([]byte, len(ppBuf)+len(buf))
				copy(finalBuf, ppBuf)
				copy(finalBuf[len(ppBuf):], buf)
				buf = finalBuf
			}
		}

		select {
		case <-ctx.Done():
			return
		default:
		}
		if _, err = entry.conn.Write(buf); err != nil {
			// Delete only if the map still points at this exact connection. A
			// stale reader must never remove a replacement connection.
			removeAndClose(key, entry)
			continue
		}
		_ = entry.conn.SetReadDeadline(time.Now().Add(30 * time.Second))
	}
}

// removeManagedConn closes entry, but removes it from the map only when entry
// is still the current connection for key. A reader from an older connection
// can finish after the dispatcher has installed a replacement; its cleanup
// must not delete or affect that replacement.
func removeManagedConn(
	mu *sync.Mutex,
	udpConnMap map[string]*managedConn,
	key string,
	entry *managedConn,
) {
	mu.Lock()
	if udpConnMap[key] == entry {
		delete(udpConnMap, key)
	}
	mu.Unlock()
	entry.close()
}
