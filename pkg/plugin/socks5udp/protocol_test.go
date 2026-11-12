package socks5udp

import (
	"bytes"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestUDPAddresses(t *testing.T) {
	for _, address := range []Address{{"127.0.0.1", 5678}, {"2001:db8::1", 5678}, {"service.example", 5678}} {
		t.Run(address.Host, func(t *testing.T) {
			packet, err := BuildUDP(address, []byte("payload"))
			require.NoError(t, err)
			decoded, payload, err := ParseUDP(packet)
			require.NoError(t, err)
			require.Equal(t, address, decoded)
			require.Equal(t, []byte("payload"), payload)
			for end := 0; end < len(packet)-len(payload); end++ {
				_, _, err = ParseUDP(packet[:end])
				require.Error(t, err)
			}
			packet[2] = 1
			_, _, err = ParseUDP(packet)
			require.ErrorIs(t, err, ErrFragmented)
		})
	}
}

func TestDatagramEnvelope(t *testing.T) {
	var token Token
	token[0] = 42
	packet, err := BuildUDP(Address{"127.0.0.1", 5678}, nil)
	require.NoError(t, err)
	encoded := EncodeDatagram(token, packet)
	got, data, err := DecodeDatagram(encoded)
	require.NoError(t, err)
	require.Equal(t, token, got)
	require.Equal(t, packet, data)
	for end := range DatagramOverhead {
		_, _, err := DecodeDatagram(encoded[:end])
		require.Error(t, err)
	}
	encoded[4]++
	_, _, err = DecodeDatagram(encoded)
	require.Error(t, err)
}

func TestInvalidUDPHeaders(t *testing.T) {
	for _, packet := range [][]byte{
		{1, 0, 0, 1, 127, 0, 0, 1, 0, 53},
		{0, 1, 0, 1, 127, 0, 0, 1, 0, 53},
		{0, 0, 0, 3, 0, 0, 53},
		{0, 0, 0, 3, 1, 0, 0, 53},
		{0, 0, 0, 1, 127, 0, 0, 1, 0, 0},
		{0, 0, 0, 0},
	} {
		_, _, err := ParseUDP(packet)
		require.Error(t, err)
	}
}

func TestZeroAddressReply(t *testing.T) {
	var b bytes.Buffer
	require.NoError(t, WriteReply(&b, 1, Address{}))
	code, address, err := ReadReply(&b)
	require.NoError(t, err)
	require.Equal(t, byte(1), code)
	require.Equal(t, Address{"0.0.0.0", 0}, address)
}

func FuzzUDPDecoders(f *testing.F) {
	f.Add([]byte{0, 0, 0, 1, 127, 0, 0, 1, 0, 53})
	f.Add([]byte("FS5U\x01"))
	f.Fuzz(func(t *testing.T, data []byte) {
		_, _, _ = ParseUDP(data)
		_, _, _ = DecodeDatagram(data)
		_, _, _ = ReadRequest(bytes.NewReader(data))
	})
}
