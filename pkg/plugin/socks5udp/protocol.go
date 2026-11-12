// Copyright 2026 The frp Authors
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

// Package socks5udp implements the protocol shared by the paired SOCKS5 plugins.
// The client-facing protocol is RFC 1928. Inside FRP a magic prefix distinguishes
// the control connection, and a random capability binds datagrams to its lifetime.
package socks5udp

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
)

const (
	Version         = 5
	CmdConnect      = 1
	CmdUDPAssociate = 3
	TokenSize       = 32
	// DatagramOverhead is additional to the standard SOCKS5 UDP header.
	DatagramOverhead = 5 + TokenSize
)

var (
	controlMagic     = []byte{'F', 'R', 'P', 'S', '5', 1}
	datagramMagic    = []byte{'F', 'S', '5', 'U', 1}
	ErrInvalidPacket = errors.New("invalid SOCKS5 packet")
	ErrFragmented    = errors.New("fragmented SOCKS5 UDP packets are unsupported")
)

type Token [TokenSize]byte

type Address struct {
	Host string
	Port uint16
}

func (a Address) String() string { return net.JoinHostPort(a.Host, strconv.Itoa(int(a.Port))) }

func AddressFromNetAddr(addr net.Addr) Address {
	if addr == nil {
		return Address{Host: "0.0.0.0"}
	}
	host, port, err := net.SplitHostPort(addr.String())
	if err != nil {
		return Address{Host: "0.0.0.0"}
	}
	p, _ := strconv.ParseUint(port, 10, 16)
	return Address{Host: host, Port: uint16(p)}
}

func WriteMagic(w io.Writer) error { return writeAll(w, controlMagic) }

func readMagic(r io.Reader) error {
	b := make([]byte, len(controlMagic))
	if _, err := io.ReadFull(r, b); err != nil {
		return err
	}
	if !bytes.Equal(b, controlMagic) {
		return errors.New("invalid SOCKS5 UDP control protocol")
	}
	return nil
}

func ReadToken(r io.Reader) (Token, error) {
	var token Token
	_, err := io.ReadFull(r, token[:])
	return token, err
}

func ReadAddress(r io.Reader) (Address, error) {
	var head [1]byte
	if _, err := io.ReadFull(r, head[:]); err != nil {
		return Address{}, err
	}
	var host string
	switch head[0] {
	case 1, 4:
		size := net.IPv4len
		if head[0] == 4 {
			size = net.IPv6len
		}
		ip := make([]byte, size)
		if _, err := io.ReadFull(r, ip); err != nil {
			return Address{}, err
		}
		host = net.IP(ip).String()
	case 3:
		if _, err := io.ReadFull(r, head[:]); err != nil {
			return Address{}, err
		}
		if head[0] == 0 {
			return Address{}, ErrInvalidPacket
		}
		name := make([]byte, int(head[0]))
		if _, err := io.ReadFull(r, name); err != nil {
			return Address{}, err
		}
		if bytes.IndexByte(name, 0) >= 0 {
			return Address{}, ErrInvalidPacket
		}
		host = string(name)
	default:
		return Address{}, ErrInvalidPacket
	}
	var port [2]byte
	if _, err := io.ReadFull(r, port[:]); err != nil {
		return Address{}, err
	}
	return Address{Host: host, Port: binary.BigEndian.Uint16(port[:])}, nil
}

func WriteAddress(w io.Writer, addr Address) error {
	var b []byte
	host := addr.Host
	if host == "" {
		host = "0.0.0.0"
	}
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			b = append([]byte{1}, v4...)
		} else {
			b = append([]byte{4}, ip.To16()...)
		}
	} else {
		if len(host) > 255 || strings.IndexByte(host, 0) >= 0 {
			return ErrInvalidPacket
		}
		b = append([]byte{3, byte(len(host))}, host...)
	}
	b = binary.BigEndian.AppendUint16(b, addr.Port)
	return writeAll(w, b)
}

func ReadRequest(r io.Reader) (byte, Address, error) { return readMessage(r) }
func ReadReply(r io.Reader) (byte, Address, error)   { return readMessage(r) }

func readMessage(r io.Reader) (byte, Address, error) {
	var b [3]byte
	if _, err := io.ReadFull(r, b[:]); err != nil {
		return 0, Address{}, err
	}
	if b[0] != Version || b[2] != 0 {
		return 0, Address{}, ErrInvalidPacket
	}
	addr, err := ReadAddress(r)
	return b[1], addr, err
}

func WriteRequest(w io.Writer, command byte, addr Address) error { return WriteReply(w, command, addr) }

func WriteReply(w io.Writer, code byte, addr Address) error {
	var b bytes.Buffer
	b.Write([]byte{Version, code, 0})
	if err := WriteAddress(&b, addr); err != nil {
		return err
	}
	return writeAll(w, b.Bytes())
}

func ParseUDP(packet []byte) (Address, []byte, error) {
	if len(packet) < 4 || packet[0] != 0 || packet[1] != 0 {
		return Address{}, nil, ErrInvalidPacket
	}
	if packet[2] != 0 {
		return Address{}, nil, ErrFragmented
	}
	r := bytes.NewReader(packet[3:])
	addr, err := ReadAddress(r)
	if err != nil || addr.Port == 0 {
		return Address{}, nil, ErrInvalidPacket
	}
	return addr, packet[len(packet)-r.Len():], nil
}

func BuildUDP(addr Address, payload []byte) ([]byte, error) {
	var b bytes.Buffer
	b.Write([]byte{0, 0, 0})
	if err := WriteAddress(&b, addr); err != nil {
		return nil, err
	}
	b.Write(payload)
	return b.Bytes(), nil
}

// EncodeDatagram wraps a standard SOCKS5 UDP packet. A nil/empty packet is an
// internal route binding: it refreshes the association's return transport but
// sends no data to a target. Visitors send these while a control session is live
// so receive-only applications recover after an XUDP transport switch.
func EncodeDatagram(token Token, packet []byte) []byte {
	b := make([]byte, 0, DatagramOverhead+len(packet))
	b = append(b, datagramMagic...)
	b = append(b, token[:]...)
	return append(b, packet...)
}

func DecodeDatagram(packet []byte) (Token, []byte, error) {
	var token Token
	if len(packet) < DatagramOverhead || !bytes.Equal(packet[:len(datagramMagic)], datagramMagic) {
		return token, nil, fmt.Errorf("invalid SOCKS5 UDP envelope")
	}
	copy(token[:], packet[len(datagramMagic):DatagramOverhead])
	return token, packet[DatagramOverhead:], nil
}

func writeAll(w io.Writer, p []byte) error {
	for len(p) > 0 {
		n, err := w.Write(p)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		p = p[n:]
	}
	return nil
}
