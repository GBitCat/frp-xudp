package main

import (
	"fmt"
	"net"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	maxMessageBytes = 4096
	// The first application datagram starts XUDP NAT discovery and may also
	// wait for the bounded P2P attempt to fall back to relay. Keep this below
	// the shell watchdog, but long enough for that normal startup path.
	ioTimeout   = 12 * time.Second
	exitUsage   = 2
	exitNetwork = 1
	exitTimeout = 124
)

func usage() {
	fmt.Fprintln(os.Stderr, "usage: udp_send IPV4:PORT MESSAGE")
}

func fail(code int, format string, args ...any) {
	fmt.Fprintf(os.Stderr, "udp_send: "+format+"\n", args...)
	os.Exit(code)
}

func parseEndpoint(value string) *net.UDPAddr {
	host, portText, err := net.SplitHostPort(value)
	if err != nil || host == "" || strings.ContainsAny(host, "\r\n\t ") {
		return nil
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		return nil
	}
	ip, err := netip.ParseAddr(host)
	if err != nil || !ip.Is4() {
		return nil
	}
	return &net.UDPAddr{IP: net.IP(ip.AsSlice()), Port: port}
}

func main() {
	if len(os.Args) != 3 {
		usage()
		os.Exit(exitUsage)
	}
	target := parseEndpoint(os.Args[1])
	if target == nil {
		usage()
		fail(exitUsage, "target must be an IPv4 endpoint")
	}
	message := os.Args[2]
	messageBytes := []byte(message)
	if len(messageBytes) == 0 || len(messageBytes) > maxMessageBytes || strings.ContainsAny(message, "\x00\r\n") {
		fail(exitUsage, "message must be 1..%d bytes without NUL, CR, or LF", maxMessageBytes)
	}

	conn, err := net.DialUDP("udp4", nil, target)
	if err != nil {
		fail(exitNetwork, "dial %s: %v", target.String(), err)
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(ioTimeout)); err != nil {
		fail(exitNetwork, "set deadline: %v", err)
	}
	if _, err := conn.Write(messageBytes); err != nil {
		if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
			fail(exitTimeout, "write timeout")
		}
		fail(exitNetwork, "write: %v", err)
	}

	response := make([]byte, maxMessageBytes+len("echo: "))
	n, err := conn.Read(response)
	if err != nil {
		if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
			fail(exitTimeout, "read timeout")
		}
		fail(exitNetwork, "read: %v", err)
	}
	expected := append([]byte("echo: "), messageBytes...)
	if string(response[:n]) != string(expected) {
		fail(exitNetwork, "unexpected response")
	}
	fmt.Printf("%s\n", response[:n])
}
