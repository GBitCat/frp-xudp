// Copyright 2026 The frp Authors
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

package msg

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"io"
	"reflect"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/fatedier/frp/pkg/proto/wire"
)

func TestV1MessageTypeIDsAreStable(t *testing.T) {
	require.Equal(t, byte('o'), TypeLogin)
	require.Equal(t, byte('1'), TypeLoginResp)
	require.Equal(t, byte('p'), TypeNewProxy)
	require.Equal(t, byte('2'), TypeNewProxyResp)
	require.Equal(t, byte('c'), TypeCloseProxy)
	require.Equal(t, byte('w'), TypeNewWorkConn)
	require.Equal(t, byte('r'), TypeReqWorkConn)
	require.Equal(t, byte('s'), TypeStartWorkConn)
	require.Equal(t, byte('v'), TypeNewVisitorConn)
	require.Equal(t, byte('3'), TypeNewVisitorConnResp)
	require.Equal(t, byte('h'), TypePing)
	require.Equal(t, byte('4'), TypePong)
	require.Equal(t, byte('u'), TypeUDPPacket)
	require.Equal(t, byte('i'), TypeNatHoleVisitor)
	require.Equal(t, byte('n'), TypeNatHoleClient)
	require.Equal(t, byte('m'), TypeNatHoleResp)
	require.Equal(t, byte('5'), TypeNatHoleSid)
	require.Equal(t, byte('6'), TypeNatHoleReport)
}

func TestStartWorkConnXUDPRoleRoundTripAndOmitEmpty(t *testing.T) {
	for _, wireProtocol := range []string{wire.ProtocolV1, wire.ProtocolV2} {
		t.Run(wireProtocol, func(t *testing.T) {
			var encoded bytes.Buffer
			in := &StartWorkConn{ProxyName: "xudp", XUDPRole: XUDPWorkConnRoleRelay}
			require.NoError(t, NewReadWriter(&encoded, wireProtocol).WriteMsg(in))

			var out StartWorkConn
			require.NoError(t, NewReadWriter(&encoded, wireProtocol).ReadMsgInto(&out))
			require.Equal(t, *in, out)
		})
	}

	withoutRole, err := json.Marshal(StartWorkConn{ProxyName: "tcp"})
	require.NoError(t, err)
	require.NotContains(t, string(withoutRole), "xudp_role")

	withRole, err := json.Marshal(StartWorkConn{ProxyName: "xudp", XUDPRole: XUDPWorkConnRoleP2P})
	require.NoError(t, err)
	require.Contains(t, string(withRole), `"xudp_role":"p2p"`)
}

// This test covers optional-field and frame parsing compatibility only. It does
// not prove interoperability between old binaries or XUDP runtime behavior.
func TestStartWorkConnOptionalRoleFrameCompatibility(t *testing.T) {
	legacy := legacyStartWorkConn{
		ProxyName: "xudp",
		SrcAddr:   "127.0.0.1",
		DstAddr:   "127.0.0.2",
		SrcPort:   1234,
		DstPort:   4321,
	}
	current := StartWorkConn{
		ProxyName: legacy.ProxyName,
		SrcAddr:   legacy.SrcAddr,
		DstAddr:   legacy.DstAddr,
		SrcPort:   legacy.SrcPort,
		DstPort:   legacy.DstPort,
		XUDPRole:  XUDPWorkConnRoleP2P,
	}

	for _, wireProtocol := range []string{wire.ProtocolV1, wire.ProtocolV2} {
		t.Run(wireProtocol+"/new-to-old", func(t *testing.T) {
			var encoded bytes.Buffer
			require.NoError(t, NewReadWriter(&encoded, wireProtocol).WriteMsg(&current))

			var out legacyStartWorkConn
			require.NoError(t, json.Unmarshal(startWorkConnJSONPayload(t, wireProtocol, encoded.Bytes()), &out))
			require.Equal(t, legacy, out)
		})

		t.Run(wireProtocol+"/old-to-new", func(t *testing.T) {
			encoded := encodeLegacyStartWorkConn(t, wireProtocol, legacy)
			var out StartWorkConn
			require.NoError(t, NewReadWriter(bytes.NewBuffer(encoded), wireProtocol).ReadMsgInto(&out))
			require.Equal(t, StartWorkConn{
				ProxyName: legacy.ProxyName,
				SrcAddr:   legacy.SrcAddr,
				DstAddr:   legacy.DstAddr,
				SrcPort:   legacy.SrcPort,
				DstPort:   legacy.DstPort,
			}, out)
		})
	}
}

type legacyStartWorkConn struct {
	ProxyName string `json:"proxy_name,omitempty"`
	SrcAddr   string `json:"src_addr,omitempty"`
	DstAddr   string `json:"dst_addr,omitempty"`
	SrcPort   uint16 `json:"src_port,omitempty"`
	DstPort   uint16 `json:"dst_port,omitempty"`
	Error     string `json:"error,omitempty"`
}

func encodeLegacyStartWorkConn(t *testing.T, wireProtocol string, in legacyStartWorkConn) []byte {
	t.Helper()
	payload, err := json.Marshal(in)
	require.NoError(t, err)

	var encoded bytes.Buffer
	switch wireProtocol {
	case wire.ProtocolV1:
		require.NoError(t, encoded.WriteByte(TypeStartWorkConn))
		require.NoError(t, binary.Write(&encoded, binary.BigEndian, int64(len(payload))))
		_, err = encoded.Write(payload)
		require.NoError(t, err)
	case wire.ProtocolV2:
		messagePayload := make([]byte, 2+len(payload))
		binary.BigEndian.PutUint16(messagePayload, V2TypeStartWorkConn)
		copy(messagePayload[2:], payload)
		require.NoError(t, wire.NewConn(&encoded).WriteFrame(&wire.Frame{
			Type:    wire.FrameTypeMessage,
			Payload: messagePayload,
		}))
	default:
		t.Fatalf("unsupported wire protocol %q", wireProtocol)
	}
	return encoded.Bytes()
}

func startWorkConnJSONPayload(t *testing.T, wireProtocol string, encoded []byte) []byte {
	t.Helper()
	reader := bytes.NewReader(encoded)
	switch wireProtocol {
	case wire.ProtocolV1:
		typeByte, err := reader.ReadByte()
		require.NoError(t, err)
		require.Equal(t, TypeStartWorkConn, typeByte)
		var length int64
		require.NoError(t, binary.Read(reader, binary.BigEndian, &length))
		require.GreaterOrEqual(t, length, int64(0))
		payload := make([]byte, length)
		_, err = io.ReadFull(reader, payload)
		require.NoError(t, err)
		return payload
	case wire.ProtocolV2:
		frame, err := wire.NewConn(bytes.NewBuffer(encoded)).ReadFrame()
		require.NoError(t, err)
		require.Equal(t, wire.FrameTypeMessage, frame.Type)
		require.GreaterOrEqual(t, len(frame.Payload), 2)
		require.Equal(t, V2TypeStartWorkConn, binary.BigEndian.Uint16(frame.Payload[:2]))
		return frame.Payload[2:]
	default:
		t.Fatalf("unsupported wire protocol %q", wireProtocol)
		return nil
	}
}

func TestMessageTypeMapIsCompleteAndUnique(t *testing.T) {
	require.Len(t, msgTypeMap, 18)

	msgTypes := make(map[reflect.Type]struct{}, len(msgTypeMap))

	for _, m := range msgTypeMap {
		msgType := reflect.TypeOf(m)
		require.NotContains(t, msgTypes, msgType)
		msgTypes[msgType] = struct{}{}
	}
}
