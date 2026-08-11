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

package proxy

import (
	"fmt"
	"net"
	"reflect"
	"sync"

	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/msg"
)

func init() {
	RegisterProxyFactory(reflect.TypeFor[*v1.XUDPProxyConfig](), NewXUDPProxy)
}

type XUDPProxy struct {
	*BaseProxy
	cfg *v1.XUDPProxyConfig

	closeCh   chan struct{}
	closeOnce sync.Once
}

func NewXUDPProxy(baseProxy *BaseProxy) Proxy {
	unwrapped, ok := baseProxy.GetConfigurer().(*v1.XUDPProxyConfig)
	if !ok {
		return nil
	}
	return &XUDPProxy{
		BaseProxy: baseProxy,
		cfg:       unwrapped,
		closeCh:   make(chan struct{}),
	}
}

func (pxy *XUDPProxy) Run() (remoteAddr string, err error) {
	xl := pxy.xl

	// Start visitor listener for relay fallback (like SUDP).
	if err = pxy.startVisitorListener(pxy.cfg.Secretkey, pxy.cfg.AllowUsers, "xudp"); err != nil {
		return
	}

	// Start NatHoleController listener for P2P (like XTCP).
	if pxy.rc.NatHoleController == nil {
		xl.Warnf("xudp P2P is not supported in frps, but relay mode is available")
		return
	}

	allowUsers := pxy.cfg.AllowUsers
	if len(allowUsers) == 0 {
		allowUsers = []string{pxy.GetUserInfo().User}
	}
	sidCh, err := pxy.rc.NatHoleController.ListenClient(pxy.GetName(), pxy.cfg.Secretkey, allowUsers)
	if err != nil {
		return "", fmt.Errorf("listen nat hole client error: %v", err)
	}

	go func() {
		for {
			select {
			case <-pxy.closeCh:
				return
			case sid := <-sidCh:
				workConn, errRet := pxy.GetWorkConnFromPool(nil, nil)
				if errRet != nil {
					xl.Warnf("get work conn for xudp p2p error: %v", errRet)
					continue
				}
				errRet = writeXUDPNatHoleSid(workConn, pxy.wireProtocol, sid)
				if errRet != nil {
					xl.Warnf("write nat hole sid package error for xudp: %v", errRet)
				}
				workConn.Close()
			}
		}
	}()

	return
}

func writeXUDPNatHoleSid(workConn net.Conn, wireProtocol string, sid string) error {
	workMsgConn := msg.NewConn(workConn, msg.NewReadWriter(workConn, wireProtocol))
	return workMsgConn.WriteMsg(&msg.NatHoleSid{
		Sid:   sid,
		Nonce: "xudp",
	})
}

func (pxy *XUDPProxy) Close() {
	pxy.closeOnce.Do(func() {
		pxy.BaseProxy.Close()
		if pxy.rc.NatHoleController != nil {
			pxy.rc.NatHoleController.CloseClient(pxy.GetName())
		}
		pxy.rc.VisitorManager.CloseListener(pxy.GetName())
		close(pxy.closeCh)
	})
}
