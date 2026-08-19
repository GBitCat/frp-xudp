package main

import (
	"fmt"
	"net"
	"os"
	"strings"
	"time"
)

const (
	listenHost      = "127.0.0.1"
	listenPort      = 2000
	maxPackets      = 3
	maxPacketBytes  = 4096
	packetReadLimit = 60 * time.Second
	exitUsage       = 2
	exitNetwork     = 1
	exitTimeout     = 124
)

func usage() {
	fmt.Fprintln(os.Stderr, "usage: udp_echo 127.0.0.1:2000")
}

func fail(code int, format string, args ...any) {
	fmt.Fprintf(os.Stderr, "udp_echo: "+format+"\n", args...)
	os.Exit(code)
}

func parseListenEndpoint(value string) bool {
	return value == "127.0.0.1:2000"
}

func main() {
	if len(os.Args) != 2 || !parseListenEndpoint(os.Args[1]) {
		usage()
		os.Exit(exitUsage)
	}
	addr := &net.UDPAddr{
		IP:   net.ParseIP(listenHost).To4(),
		Port: listenPort,
	}
	conn, err := net.ListenUDP("udp4", addr)
	if err != nil {
		fail(exitNetwork, "listen %s: %v", addr.String(), err)
	}
	defer conn.Close()

	buffer := make([]byte, maxPacketBytes+1)
	for packet := 0; packet < maxPackets; packet++ {
		if err := conn.SetReadDeadline(time.Now().Add(packetReadLimit)); err != nil {
			fail(exitNetwork, "set deadline: %v", err)
		}
		n, source, err := conn.ReadFromUDP(buffer)
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				fail(exitTimeout, "read timeout after %d/%d packets", packet, maxPackets)
			}
			fail(exitNetwork, "read: %v", err)
		}
		if source.IP.To4() == nil || !source.IP.To4().Equal(net.ParseIP(listenHost).To4()) {
			fail(exitNetwork, "unexpected source address %s", source.String())
		}
		if n == 0 || n > maxPacketBytes || strings.ContainsAny(string(buffer[:n]), "\x00\r\n") {
			fail(exitNetwork, "invalid packet")
		}
		response := append([]byte("echo: "), buffer[:n]...)
		if _, err := conn.WriteToUDP(response, source); err != nil {
			fail(exitNetwork, "write to %s: %v", source.String(), err)
		}
	}
}
