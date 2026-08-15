package transport

import (
	"net"
	"testing"

	"github.com/fatedier/frp/pkg/msg"
)

func BenchmarkValidateDatagramSize(b *testing.B) {
	b.ReportAllocs()
	for range b.N {
		_ = ValidateDatagramSize(ConservativeXUDPDatagramPayloadLimit)
	}
}

func BenchmarkUDPPacketBinaryEncode(b *testing.B) {
	pkt := &msg.UDPPacket{
		Content:    make([]byte, 1200),
		RemoteAddr: &net.UDPAddr{IP: net.ParseIP("203.0.113.9"), Port: 54321},
	}
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		if _, err := msg.EncodeUDPPacketBinary(pkt); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkUDPPacketBinaryDecode(b *testing.B) {
	pkt := &msg.UDPPacket{
		Content:    make([]byte, 1200),
		RemoteAddr: &net.UDPAddr{IP: net.ParseIP("203.0.113.9"), Port: 54321},
	}
	body, err := msg.EncodeUDPPacketBinary(pkt)
	if err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		if _, err := msg.DecodeUDPPacketBinary(body); err != nil {
			b.Fatal(err)
		}
	}
}
