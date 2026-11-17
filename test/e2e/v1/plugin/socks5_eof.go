package plugin

import (
	"bytes"
	"crypto/rand"
	"fmt"
	"io"
	"net"
	"strconv"
	"time"

	"github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"

	"github.com/fatedier/frp/test/e2e/framework"
	"github.com/fatedier/frp/test/e2e/framework/consts"
)

var _ = ginkgo.Describe("[Feature: SOCKS5-TCP-EOF]", func() {
	f := framework.NewDefaultFramework()

	for _, tc := range []struct {
		name          string
		wire          string
		protocol      string
		mux           bool
		encryption    bool
		compression   bool
		authenticated bool
		fallback      bool
	}{
		{"v1 TCP mux plaintext", "v1", "tcp", true, false, false, false, false},
		{"v2 TCP mux encrypted", "v2", "tcp", true, true, false, true, false},
		{"v2 TCP mux compressed", "v2", "tcp", true, false, true, false, false},
		{"v2 TCP mux encrypted and compressed", "v2", "tcp", true, true, true, true, false},
		{"v2 TCP without mux plaintext", "v2", "tcp", false, false, false, false, false},
		{"v2 TCP without mux encrypted and compressed", "v2", "tcp", false, true, true, true, false},
		{"v2 QUIC plaintext", "v2", "quic", true, false, false, false, false},
		{"v2 QUIC encrypted and compressed", "v2", "quic", true, true, true, true, false},
		{"v2 XTCP fallback to STCP", "v2", "tcp", true, true, true, true, true},
	} {
		ginkgo.It(tc.name+" delivers target EOF without closing another connection", func() {
			username, password := "", ""
			if tc.authenticated {
				username, password = "alice", "test-password"
			}
			entryPort := f.AllocPort()
			server := consts.DefaultServerConfig + fmt.Sprintf("\ntransport.tcpMux = %t\n", tc.mux)
			if tc.protocol == "quic" {
				server += fmt.Sprintf("quicBindPort = {{ .%s }}\n", consts.PortServerName)
			}
			common := consts.DefaultClientConfig + fmt.Sprintf(`
transport.protocol = %q
transport.wireProtocol = %q
transport.tcpMux = %t
natHoleStunServer = "127.0.0.1:1"
`, tc.protocol, tc.wire, tc.mux)
			provider := common + fmt.Sprintf(`
[[proxies]]
name = "socks-eof"
type = "stcp"
secretKey = "eof-test-secret"
transport.useEncryption = %t
transport.useCompression = %t
[proxies.plugin]
type = "socks5"
username = %q
password = %q
`, tc.encryption, tc.compression, username, password)
			stcpPort := entryPort
			if tc.fallback {
				stcpPort = -1
			}
			visitor := common + fmt.Sprintf(`
[[visitors]]
name = "socks-eof-visitor"
type = "stcp"
serverName = "socks-eof"
secretKey = "eof-test-secret"
bindAddr = "127.0.0.1"
bindPort = %d
transport.useEncryption = %t
transport.useCompression = %t
`, stcpPort, tc.encryption, tc.compression)
			if tc.fallback {
				// No XTCP provider exists, so this exercises the actual connection
				// transfer to STCP without depending on an external STUN server.
				visitor += fmt.Sprintf(`
[[visitors]]
name = "socks-eof-fallback"
type = "xtcp"
serverName = "unavailable-xtcp"
secretKey = "eof-test-secret"
bindAddr = "127.0.0.1"
bindPort = %d
fallbackTo = "socks-eof-visitor"
fallbackTimeoutMs = 200
transport.useEncryption = %t
transport.useCompression = %t
`, entryPort, tc.encryption, tc.compression)
			}
			_, clients := f.RunProcesses(server, []string{provider, visitor})
			entry := net.JoinHostPort("127.0.0.1", strconv.Itoa(entryPort))
			framework.ExpectNoError(framework.WaitForTCPReady(entry, 5*time.Second))

			// Keep another stream alive throughout both EOF cases to detect an
			// accidental shutdown of the shared mux session or QUIC connection.
			echoTarget := newSOCKS5TCPEchoTarget()
			sibling, err := openSOCKS5TestControl(entry, username, password)
			framework.ExpectNoError(err)
			defer sibling.Close()
			_, err = socks5TestCommand(sibling, 1, echoTarget.IP.String(), echoTarget.Port)
			framework.ExpectNoError(err)
			expectSOCKS5EOFSiblingEcho(sibling)

			largeResponse := make([]byte, 256*1024)
			_, err = rand.Read(largeResponse)
			framework.ExpectNoError(err)
			for _, response := range [][]byte{[]byte("complete response"), largeResponse} {
				expectSOCKS5TargetEOF(entry, username, password, response)
				expectSOCKS5EOFSiblingEcho(sibling)
			}
			if tc.fallback {
				framework.ExpectNoError(clients[1].WaitForOutput(
					"try to transfer connection to visitor: socks-eof-visitor", 1, 5*time.Second))
			}
		})
	}
})

func expectSOCKS5TargetEOF(entry, username, password string, response []byte) {
	listener, err := net.ListenTCP("tcp", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	framework.ExpectNoError(err)
	defer listener.Close()
	framework.ExpectNoError(listener.SetDeadline(time.Now().Add(10 * time.Second)))

	client, err := openSOCKS5TestControl(entry, username, password)
	framework.ExpectNoError(err)
	defer client.Close()
	_, err = socks5TestCommand(client, 1, "127.0.0.1", listener.Addr().(*net.TCPAddr).Port)
	framework.ExpectNoError(err)
	target, err := listener.AcceptTCP()
	framework.ExpectNoError(err)
	defer target.Close()
	framework.ExpectNoError(target.SetDeadline(time.Now().Add(10 * time.Second)))

	request := []byte("send response, then close")
	targetDone := make(chan error, 1)
	go func() {
		got := make([]byte, len(request))
		_, targetErr := io.ReadFull(target, got)
		if targetErr == nil && !bytes.Equal(got, request) {
			targetErr = fmt.Errorf("SOCKS request payload changed in transit")
		}
		if targetErr == nil {
			_, targetErr = io.Copy(target, bytes.NewReader(response))
		}
		_ = target.Close()
		targetDone <- targetErr
	}()

	_, err = client.Write(request)
	framework.ExpectNoError(err)
	got := make([]byte, len(response))
	_, err = io.ReadFull(client, got)
	framework.ExpectNoError(err)
	gomega.Expect(got).To(gomega.Equal(response), "the complete response must precede EOF")

	// Do not close the client's write half: applications that read until EOF
	// must receive the target's closure without first ending their own stream.
	framework.ExpectNoError(client.SetReadDeadline(time.Now().Add(3 * time.Second)))
	var next [1]byte
	n, err := client.Read(next[:])
	gomega.Expect(n).To(gomega.BeZero())
	gomega.Expect(err).To(gomega.Equal(io.EOF), "a timeout or reset is not a graceful EOF")
	gomega.Eventually(targetDone, time.Second).Should(gomega.Receive(gomega.Succeed()))
}

func expectSOCKS5EOFSiblingEcho(conn net.Conn) {
	framework.ExpectNoError(conn.SetDeadline(time.Now().Add(10 * time.Second)))
	message := []byte("sibling-still-open")
	_, err := conn.Write(message)
	framework.ExpectNoError(err)
	got := make([]byte, len(message))
	_, err = io.ReadFull(conn, got)
	framework.ExpectNoError(err)
	gomega.Expect(got).To(gomega.Equal(message))
}
