package plugin

import (
	"bytes"
	"encoding/binary"
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

// These clients deliberately implement the public SOCKS5 wire protocol here,
// rather than reusing the plugin's codecs. This checks interoperability at the
// application boundary as well as the real frpc/frps transport path.
var _ = ginkgo.Describe("[Feature: SOCKS5-UDP]", func() {
	f := framework.NewDefaultFramework()

	for _, tc := range []struct {
		name     string
		udpType  string
		wire     string
		username string
		password string
	}{
		{"authenticated SUDP", "sudp", "v1", "alice", "test-password"},
		{"authenticated XUDP relay", "xudp", "v2", "alice", "test-password"},
		{"unauthenticated SUDP", "sudp", "v2", "", ""},
	} {
		ginkgo.It(tc.name+" supports TCP and isolated dynamic UDP associations", func() {
			socksPort := f.AllocPort()
			provider := consts.DefaultClientConfig + fmt.Sprintf(`
user = "socks-owner"
transport.wireProtocol = %q
natHoleStunServer = "127.0.0.1:1"

[[proxies]]
name = "socks-tcp"
type = "stcp"
secretKey = "test-control-secret"
allowUsers = ["socks-reader"]
[proxies.plugin]
type = "socks5_udp"
username = %q
password = %q
udpProxyName = "socks-udp"

[[proxies]]
name = "socks-udp"
type = %q
secretKey = "test-datagram-secret"
allowUsers = ["socks-reader"]
[proxies.plugin]
type = "socks5_udp"
`, tc.wire, tc.username, tc.password, tc.udpType)
			visitor := consts.DefaultClientConfig + fmt.Sprintf(`
user = "socks-reader"
transport.wireProtocol = %q
natHoleStunServer = "127.0.0.1:1"

[[visitors]]
name = "socks-control"
type = "stcp"
serverUser = "socks-owner"
serverName = "socks-tcp"
secretKey = "test-control-secret"
bindPort = -1
[visitors.plugin]
type = "socks5_udp"
bindAddr = "127.0.0.1"
bindPort = %d
udpVisitorAddr = "127.0.0.1:%d"

[[visitors]]
name = "socks-data"
type = %q
serverUser = "socks-owner"
serverName = "socks-udp"
secretKey = "test-datagram-secret"
bindAddr = "127.0.0.1"
bindPort = %d
`, tc.wire, socksPort, socksPort, tc.udpType, socksPort)
			_, clients := f.RunProcesses(consts.DefaultServerConfig, []string{provider, visitor})
			entry := net.JoinHostPort("127.0.0.1", strconv.Itoa(socksPort))
			framework.ExpectNoError(framework.WaitForTCPReady(entry, 5*time.Second))

			if tc.username != "" {
				bad, err := openSOCKS5TestControl(entry, tc.username, "wrong-password")
				if bad != nil {
					_ = bad.Close()
				}
				gomega.Expect(err).To(gomega.HaveOccurred(), "wrong credentials must not authenticate")
				bad, err = openSOCKS5TestControl(entry, "", "")
				if bad != nil {
					_ = bad.Close()
				}
				gomega.Expect(err).To(gomega.HaveOccurred(), "no-auth must not bypass required credentials")
			}

			ginkgo.By("connecting to a TCP target selected by the SOCKS request")
			tcpTarget := newSOCKS5TCPEchoTarget()
			control, err := openSOCKS5TestControl(entry, tc.username, tc.password)
			framework.ExpectNoError(err)
			defer control.Close()
			_, err = socks5TestCommand(control, 1, "127.0.0.1", tcpTarget.Port)
			framework.ExpectNoError(err)
			_, err = control.Write([]byte("tcp-through-socks"))
			framework.ExpectNoError(err)
			tcpReply := make([]byte, len("tcp-through-socks"))
			_, err = io.ReadFull(control, tcpReply)
			framework.ExpectNoError(err)
			gomega.Expect(string(tcpReply)).To(gomega.Equal("tcp-through-socks"))
			framework.ExpectNoError(control.Close())

			firstTarget := newSOCKS5UDPEchoTarget("first:")
			secondTarget := newSOCKS5UDPEchoTarget("second:")
			first := newSOCKS5TestAssociation(entry, tc.username, tc.password)
			defer first.close()
			second := newSOCKS5TestAssociation(entry, tc.username, tc.password)
			defer second.close()
			gomega.Expect(first.relay.String()).NotTo(gomega.Equal(second.relay.String()),
				"clients on the same IP need distinguishable UDP relay endpoints")

			ginkgo.By("resolving each UDP packet's target at the provider")
			first.expectEcho("127.0.0.1", firstTarget.Port, "one", "first:one")
			first.expectEcho("127.0.0.1", secondTarget.Port, "two", "second:two")
			first.expectEcho("localhost", secondTarget.Port, "domain", "second:domain")
			second.expectEcho("127.0.0.1", firstTarget.Port, "other-client", "first:other-client")
			first.expectEcho("127.0.0.1", firstTarget.Port, "still-first", "first:still-first")

			ginkgo.By("accepting a changed server port while preserving the association's UDP source")
			first.expectAlternateReplyPort()

			ginkgo.By("rejecting fragmented packets and a different UDP source port")
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
			gomega.Expect(err).To(gomega.HaveOccurred(), "a different source port must not borrow an association")
			first.expectEcho("127.0.0.1", firstTarget.Port, "after-rejection", "first:after-rejection")

			ginkgo.By("ending only the association whose TCP control connection closed")
			framework.ExpectNoError(first.control.Close())
			// The close travels through the visitor asynchronously. Verify the
			// remaining client still works before checking the retired endpoint.
			second.expectEcho("127.0.0.1", firstTarget.Port, "survivor", "first:survivor")
			gomega.Eventually(func() error {
				if err := first.udp.SetDeadline(time.Now().Add(150 * time.Millisecond)); err != nil {
					return err
				}
				if _, err := first.udp.Write(socks5TestUDPFrame("127.0.0.1", firstTarget.Port, []byte("closed"))); err != nil {
					return err
				}
				_, err := first.udp.Read(make([]byte, 2048))
				return err
			}, 3*time.Second, 50*time.Millisecond).Should(gomega.HaveOccurred())
			if tc.udpType == "xudp" {
				framework.ExpectNoError(clients[1].WaitForOutput("falling back to relay", 1, 5*time.Second))
			}
		})
	}
})

func openSOCKS5TestControl(entry, username, password string) (net.Conn, error) {
	conn, err := net.DialTimeout("tcp", entry, 3*time.Second)
	if err != nil {
		return nil, err
	}
	fail := func(err error) (net.Conn, error) {
		_ = conn.Close()
		return nil, err
	}
	if err := conn.SetDeadline(time.Now().Add(10 * time.Second)); err != nil {
		return fail(err)
	}
	method := byte(0)
	if username != "" || password != "" {
		method = 2
	}
	if _, err := conn.Write([]byte{5, 1, method}); err != nil {
		return fail(err)
	}
	reply := make([]byte, 2)
	if _, err := io.ReadFull(conn, reply); err != nil {
		return fail(err)
	}
	if reply[0] != 5 || reply[1] != method {
		return fail(fmt.Errorf("unexpected SOCKS method reply %v", reply))
	}
	if method == 2 {
		auth := append([]byte{1, byte(len(username))}, username...)
		auth = append(auth, byte(len(password)))
		auth = append(auth, password...)
		if _, err := conn.Write(auth); err != nil {
			return fail(err)
		}
		if _, err := io.ReadFull(conn, reply); err != nil {
			return fail(err)
		}
		if !bytes.Equal(reply, []byte{1, 0}) {
			return fail(fmt.Errorf("SOCKS authentication rejected: %v", reply))
		}
	}
	return conn, nil
}

func socks5TestCommand(conn net.Conn, command byte, host string, port int) (*net.UDPAddr, error) {
	request := append([]byte{5, command, 0}, socks5TestAddress(host, port)...)
	if _, err := conn.Write(request); err != nil {
		return nil, err
	}
	header := make([]byte, 3)
	if _, err := io.ReadFull(conn, header); err != nil {
		return nil, err
	}
	if !bytes.Equal(header, []byte{5, 0, 0}) {
		return nil, fmt.Errorf("SOCKS command failed: %v", header)
	}
	return readSOCKS5TestAddress(conn)
}

func socks5TestAddress(host string, port int) []byte {
	var b []byte
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			b = append([]byte{1}, v4...)
		} else {
			b = append([]byte{4}, ip.To16()...)
		}
	} else {
		b = append([]byte{3, byte(len(host))}, host...)
	}
	return binary.BigEndian.AppendUint16(b, uint16(port))
}

func readSOCKS5TestAddress(r io.Reader) (*net.UDPAddr, error) {
	var typ [1]byte
	if _, err := io.ReadFull(r, typ[:]); err != nil {
		return nil, err
	}
	var addr []byte
	switch typ[0] {
	case 1:
		addr = make([]byte, 4)
	case 4:
		addr = make([]byte, 16)
	case 3:
		if _, err := io.ReadFull(r, typ[:]); err != nil {
			return nil, err
		}
		addr = make([]byte, int(typ[0]))
	default:
		return nil, fmt.Errorf("unexpected SOCKS address type %d", typ[0])
	}
	if _, err := io.ReadFull(r, addr); err != nil {
		return nil, err
	}
	var port [2]byte
	if _, err := io.ReadFull(r, port[:]); err != nil {
		return nil, err
	}
	return &net.UDPAddr{IP: net.IP(addr), Port: int(binary.BigEndian.Uint16(port[:]))}, nil
}

func socks5TestUDPFrame(host string, port int, payload []byte) []byte {
	b := append([]byte{0, 0, 0}, socks5TestAddress(host, port)...)
	return append(b, payload...)
}

type socks5TestAssociation struct {
	control net.Conn
	udp     *net.UDPConn
	relay   *net.UDPAddr
}

func newSOCKS5TestAssociation(entry, username, password string) *socks5TestAssociation {
	control, err := openSOCKS5TestControl(entry, username, password)
	framework.ExpectNoError(err)
	ginkgo.DeferCleanup(func() { _ = control.Close() })
	relay, err := socks5TestCommand(control, 3, "0.0.0.0", 0)
	framework.ExpectNoError(err)
	gomega.Expect(relay.Port).To(gomega.BeNumerically(">", 0))
	gomega.Expect(relay.IP.IsLoopback()).To(gomega.BeTrue(), "visitor must return its reachable local endpoint")
	udpConn, err := net.DialUDP("udp", nil, relay)
	framework.ExpectNoError(err)
	ginkgo.DeferCleanup(func() { _ = udpConn.Close() })
	framework.ExpectNoError(control.SetDeadline(time.Time{}))
	return &socks5TestAssociation{control: control, udp: udpConn, relay: relay}
}

func (a *socks5TestAssociation) close() {
	_ = a.control.Close()
	_ = a.udp.Close()
}

func (a *socks5TestAssociation) expectEcho(host string, port int, payload, expected string) {
	framework.ExpectNoError(a.udp.SetDeadline(time.Now().Add(12 * time.Second)))
	_, err := a.udp.Write(socks5TestUDPFrame(host, port, []byte(payload)))
	framework.ExpectNoError(err)
	a.expectReply(port, expected)
}

func (a *socks5TestAssociation) expectReply(port int, expected string) {
	b := make([]byte, 4096)
	n, err := a.udp.Read(b)
	framework.ExpectNoError(err)
	gomega.Expect(n).To(gomega.BeNumerically(">=", 10))
	gomega.Expect(b[:3]).To(gomega.Equal([]byte{0, 0, 0}))
	r := bytes.NewReader(b[3:n])
	from, err := readSOCKS5TestAddress(r)
	framework.ExpectNoError(err)
	gomega.Expect(from.Port).To(gomega.Equal(port))
	response, err := io.ReadAll(r)
	framework.ExpectNoError(err)
	gomega.Expect(string(response)).To(gomega.Equal(expected))
}

func (a *socks5TestAssociation) expectAlternateReplyPort() {
	request, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	framework.ExpectNoError(err)
	defer request.Close()
	response, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	framework.ExpectNoError(err)
	defer response.Close()
	deadline := time.Now().Add(12 * time.Second)
	framework.ExpectNoError(request.SetDeadline(deadline))
	framework.ExpectNoError(response.SetDeadline(deadline))
	framework.ExpectNoError(a.udp.SetDeadline(deadline))

	_, err = a.udp.Write(socks5TestUDPFrame("127.0.0.1", request.LocalAddr().(*net.UDPAddr).Port, []byte("request")))
	framework.ExpectNoError(err)
	buf := make([]byte, 4096)
	n, initialPeer, err := request.ReadFromUDP(buf)
	framework.ExpectNoError(err)
	gomega.Expect(string(buf[:n])).To(gomega.Equal("request"))
	_, err = response.WriteToUDP([]byte("new-server-port"), initialPeer)
	framework.ExpectNoError(err)
	responsePort := response.LocalAddr().(*net.UDPAddr).Port
	a.expectReply(responsePort, "new-server-port")

	// Like TFTP, the client follows the server's newly advertised UDP port.
	_, err = a.udp.Write(socks5TestUDPFrame("127.0.0.1", responsePort, []byte("followup")))
	framework.ExpectNoError(err)
	n, followupPeer, err := response.ReadFromUDP(buf)
	framework.ExpectNoError(err)
	gomega.Expect(string(buf[:n])).To(gomega.Equal("followup"))
	gomega.Expect(followupPeer.String()).To(gomega.Equal(initialPeer.String()),
		"the client UDP endpoint must remain stable when the target port changes")
	_, err = response.WriteToUDP([]byte("followup-reply"), followupPeer)
	framework.ExpectNoError(err)
	a.expectReply(responsePort, "followup-reply")
}

func (a *socks5TestAssociation) expectNoReply() {
	framework.ExpectNoError(a.udp.SetReadDeadline(time.Now().Add(250 * time.Millisecond)))
	_, err := a.udp.Read(make([]byte, 2048))
	gomega.Expect(err).To(gomega.HaveOccurred())
}

func newSOCKS5UDPEchoTarget(prefix string) *net.UDPAddr {
	conn, err := net.ListenUDP("udp", &net.UDPAddr{})
	framework.ExpectNoError(err)
	ginkgo.DeferCleanup(conn.Close)
	go func() {
		buf := make([]byte, 4096)
		for {
			n, peer, err := conn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			_, _ = conn.WriteToUDP(append([]byte(prefix), buf[:n]...), peer)
		}
	}()
	return conn.LocalAddr().(*net.UDPAddr)
}

func newSOCKS5TCPEchoTarget() *net.TCPAddr {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	framework.ExpectNoError(err)
	ginkgo.DeferCleanup(listener.Close)
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				_, _ = io.Copy(conn, conn)
			}()
		}
	}()
	return listener.Addr().(*net.TCPAddr)
}
