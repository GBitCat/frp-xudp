package plugin

import (
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

var _ = ginkgo.Describe("[Feature: SOCKS5-UDP] standalone datagram sessions", func() {
	f := framework.NewDefaultFramework()

	for _, tc := range []struct {
		name, udpType, wire, username, password string
	}{
		{"authenticated SUDP", "sudp", "v1", "alice", "test-password"},
		{"unauthenticated SUDP", "sudp", "v2", "", ""},
		{"SUDP with an empty password", "sudp", "v2", "alice", ""},
		{"authenticated XUDP relay", "xudp", "v2", "alice", "test-password"},
	} {
		ginkgo.It(tc.name+" authenticates and forwards UDP without a stream proxy", func() {
			socksPort := f.AllocPort()
			// There is intentionally no STCP/XTCP proxy or visitor. Negotiation,
			// authentication, association creation, and revocation must all pass
			// through the private UDP transport, including the relay fallback.
			provider := consts.DefaultClientConfig + fmt.Sprintf(`
user = "standalone-owner"
transport.wireProtocol = %q
natHoleStunServer = "127.0.0.1:1"

[[proxies]]
name = "socks-udp"
type = %q
secretKey = "standalone-datagram-secret"
allowUsers = ["standalone-reader"]
[proxies.plugin]
type = "socks5_udp"
sessionMode = "datagram"
username = %q
password = %q
`, tc.wire, tc.udpType, tc.username, tc.password)
			visitor := consts.DefaultClientConfig + fmt.Sprintf(`
user = "standalone-reader"
transport.wireProtocol = %q
natHoleStunServer = "127.0.0.1:1"

[[visitors]]
name = "socks-data"
type = %q
serverUser = "standalone-owner"
serverName = "socks-udp"
secretKey = "standalone-datagram-secret"
bindPort = -1
[visitors.plugin]
type = "socks5_udp"
bindAddr = "127.0.0.1"
bindPort = %d
`, tc.wire, tc.udpType, socksPort)
			_, clients := f.RunProcesses(consts.DefaultServerConfig, []string{provider, visitor})
			entry := net.JoinHostPort("127.0.0.1", strconv.Itoa(socksPort))
			framework.ExpectNoError(framework.WaitForTCPReady(entry, 5*time.Second))

			if tc.username != "" || tc.password != "" {
				ginkgo.By("enforcing provider credentials on the datagram path")
				for _, credentials := range [][2]string{{tc.username, "wrong-password"}, {"", ""}} {
					bad, err := openSOCKS5TestControlWithTimeout(entry, credentials[0], credentials[1], 60*time.Second)
					if bad != nil {
						_ = bad.Close()
					}
					gomega.Expect(err).To(gomega.HaveOccurred(), "wrong credentials and no-auth must both be rejected")
				}
			}

			ginkgo.By("rejecting TCP CONNECT on the UDP-only plugin")
			control, err := openSOCKS5TestControlWithTimeout(entry, tc.username, tc.password, 60*time.Second)
			framework.ExpectNoError(err)
			defer control.Close()
			tcpTarget := newSOCKS5TCPEchoTarget()
			request := append([]byte{5, 1, 0}, socks5TestAddress("127.0.0.1", tcpTarget.Port)...)
			_, err = control.Write(request)
			framework.ExpectNoError(err)
			var reply [3]byte
			_, err = io.ReadFull(control, reply[:])
			framework.ExpectNoError(err)
			gomega.Expect(reply).To(gomega.Equal([3]byte{5, 7, 0}), "CONNECT must return command-not-supported")
			_, err = readSOCKS5TestAddress(control)
			framework.ExpectNoError(err)
			framework.ExpectNoError(control.Close())

			first := newSOCKS5TestAssociationWithTimeout(entry, tc.username, tc.password, 60*time.Second)
			defer first.close()
			second := newSOCKS5TestAssociationWithTimeout(entry, tc.username, tc.password, 60*time.Second)
			defer second.close()
			gomega.Expect(first.relay.String()).NotTo(gomega.Equal(second.relay.String()))
			firstTarget := newSOCKS5UDPEchoTarget("first:")
			secondTarget := newSOCKS5UDPEchoTarget("second:")

			ginkgo.By("routing independent sessions to multiple targets with provider DNS resolution")
			first.expectEcho("127.0.0.1", firstTarget.Port, "one", "first:one")
			first.expectEcho("127.0.0.1", secondTarget.Port, "two", "second:two")
			first.expectEcho("localhost", secondTarget.Port, "domain", "second:domain")
			second.expectEcho("127.0.0.1", firstTarget.Port, "other-client", "first:other-client")
			first.expectAlternateReplyPort()

			ginkgo.By("rejecting fragments and attempts to borrow another local association")
			fragment := socks5TestUDPFrame("127.0.0.1", firstTarget.Port, []byte("fragment"))
			fragment[2] = 1
			_, err = first.udp.Write(fragment)
			framework.ExpectNoError(err)
			first.expectNoReply()
			foreign, err := net.DialUDP("udp", nil, first.relay)
			framework.ExpectNoError(err)
			defer foreign.Close()
			_, err = foreign.Write(socks5TestUDPFrame("127.0.0.1", firstTarget.Port, []byte("foreign")))
			framework.ExpectNoError(err)
			framework.ExpectNoError(foreign.SetReadDeadline(time.Now().Add(250 * time.Millisecond)))
			_, err = foreign.Read(make([]byte, 2048))
			gomega.Expect(err).To(gomega.HaveOccurred())
			first.expectEcho("127.0.0.1", firstTarget.Port, "after-rejection", "first:after-rejection")

			ginkgo.By("closing only the association whose application TCP connection ended")
			framework.ExpectNoError(first.control.Close())
			second.expectEcho("127.0.0.1", firstTarget.Port, "survivor", "first:survivor")
			gomega.Eventually(func() bool {
				listener, err := net.ListenUDP("udp", first.relay)
				if err != nil {
					return false
				}
				_ = listener.Close()
				return true
			}, 3*time.Second, 20*time.Millisecond).Should(gomega.BeTrue(), "the closed local UDP relay must release its socket")
			third := newSOCKS5TestAssociationWithTimeout(entry, tc.username, tc.password, 60*time.Second)
			defer third.close()
			third.expectEcho("127.0.0.1", secondTarget.Port, "replacement", "second:replacement")
			if tc.udpType == "xudp" {
				framework.ExpectNoError(clients[1].WaitForOutput("falling back to relay", 1, 5*time.Second))
			}
		})
	}
})
