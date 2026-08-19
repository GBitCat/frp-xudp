# FRP XUDP Extension Design Document

版本：v0.2

> 注意：XUDP 是 frp 的**独立扩展**，未合入上游 fatedier/frp（上游多次收到
> 相关请求后未实现，见 fatedier/frp issues #1729 / #4173）。
> 本扩展仅在本仓库（frp-xudp）维护，请勿在官方项目中期望该功能。

目标：为 FRP 增加 P2P UDP Proxy 能力。

## 当前实现状态

- XUDP P2P 数据面使用 QUIC DATAGRAM（RFC 9221），不使用 QUIC Stream。
- NAT Hole Punching 继续复用 FRP 原有 `pkg/nathole`。
- P2P 双方通过临时证书 SHA-256 fingerprint 做 peer authentication。
- QUIC DATAGRAM 采用保守 1150 字节 encoded payload 限制，给 1200 字节 QUIC
  初始包预留 UDP、QUIC 和 AEAD 开销，避免依赖 IP fragmentation。
- Visitor 使用显式 P2P/Relay 状态机和 generation/transport epoch 隔离旧 transport。
- 支持 P2P 失败自动 Relay、Relay 周期探测并恢复 P2P。
- SUDP 保持 upstream FRP 原有中继协议和安全模型；本轮仅加固其并发关闭与资源
  回收，不改变消息格式和数据流向。

------------------------------------------------------------------------

# 1. 项目目标

## 1.1 功能目标

新增代理类型：

    xudp

支持：

    内网服务
        |
       frpc
        |
     UDP Hole Punch
        |
       frpc
        |
    客户端

区别于传统 UDP proxy：

传统：

    Client
      |
    frps
      |
    frpc
      |
    Service

XUDP：

    Client
      |
    frpc
      |
    UDP P2P
      |
    frpc
      |
    Service

------------------------------------------------------------------------

# 2. 总体架构

                             Control Plane

                         +-------------+
                         |    frps     |
                         | XUDP Broker |
                         +-------------+

                           /        \

                     frpc-A          frpc-B

                      |                |

                 XUDP Agent      XUDP Agent

                      \                /

                        UDP Hole Punch

                              |

                    QUIC DATAGRAM

------------------------------------------------------------------------

# 3. 模块划分

    frp/

    ├── pkg/
    │
    ├── proxy/
    │    ├── tcp.go
    │    ├── udp.go
    │    └── xudp.go
    │
    ├── xudp/
    │    ├── session/
    │    │     └── table.go
    │    ├── state/
    │    │     └── state.go
    │    └── transport/
    │          ├── quic.go
    │          ├── identity.go
    │          └── mtu.go
    │
    ├── client/
    │    └── xudp_client.go
    │
    └── server/
         └── xudp_server.go

------------------------------------------------------------------------

# 4. 配置设计

frpc.toml：

``` toml
[[proxies]]

name = "game"

type = "xudp"

localIP = "127.0.0.1"

localPort = 2000

remotePort = 2000

[xudp]

enableP2P = true

fallbackRelay = true

stunServer = [
 "stun.example.com:3478"
]
```

------------------------------------------------------------------------

# 5. Proxy生命周期

流程：

1.  frpc 登录 frps
2.  注册 xudp proxy
3.  frps 保存节点信息
4.  请求连接时交换 endpoint
5.  尝试 UDP 打洞
6.  成功后进入 QUIC Handshake
7.  QUIC DATAGRAM 建立后进入 P2P_READY
8.  P2P 失败或断线后进入 RELAY_READY
9.  Relay 周期探测 P2P，成功后切回 P2P_READY

------------------------------------------------------------------------

# 6. 控制协议扩展

新增：

## XUDP_REGISTER

客户端注册：

``` json
{
 "proxy":"game",
 "node":"A",
 "publicKey":"xxx"
}
```

## XUDP_CONNECT

请求连接：

``` json
{
 "target":"game"
}
```

## XUDP_OFFER

返回 peer 地址：

``` json
{
 "peer":{
   "ip":"8.8.8.8",
   "port":45000
 }
}
```

------------------------------------------------------------------------

# 7. NAT 穿透流程

## STUN 地址发现

frpc 查询公网映射：

    192.168.1.20:5000

            NAT

    203.0.113.1:45000

------------------------------------------------------------------------

## UDP Hole Punch

双方同时发送：

    A ---------------- B

           UDP Probe

    A <--------------- B

成功后建立：

    A <=========> B

        Direct UDP

------------------------------------------------------------------------

# 8. Session 管理

UDP 无连接，需要维护：

    Session Table

    Session ID

    Client Addr

    Peer Addr

    Last Active

    State

状态：

    INIT
    NAT_HOLE_PREPARE
    PUNCHING
    QUIC_HANDSHAKE
    P2P_READY
    RELAY_CONNECT
    RELAY_READY
    RECOVERING
    CLOSED

------------------------------------------------------------------------

# 9. 数据模式

P2P 模式：

```text
Application UDP
      |
      v
XUDP UDP Packet
      |
      v
QUIC DATAGRAM
      |
      v
UDP Socket
```

Relay 模式继续使用 FRP 原有 SUDP 风格 relay，不强制应用 QUIC。

## MTU

默认最大 QUIC DATAGRAM encoded payload 为 1150 字节。超过该值的数据报会
被丢弃并记录错误，不依赖底层 IP fragmentation。

## P2P模式

    frpc-A

       UDP

    frpc-B

## Relay模式

失败时：

    A

    |

    frps

    |

    B

------------------------------------------------------------------------

# 10. NAT 类型处理

支持检测：

-   Full Cone
-   Restricted Cone
-   Port Restricted
-   Symmetric NAT

策略：

  类型         策略
  ------------ -----------
  Full Cone    P2P
  Restricted   尝试打洞
  Symmetric    优先Relay

------------------------------------------------------------------------

# 11. Keepalive

建立连接后：

每 20\~30 秒发送：

    PING

防止 NAT 映射过期。

------------------------------------------------------------------------

# 12. 安全设计

Probe 包需要：

-   session token
-   timestamp
-   HMAC

防止：

-   UDP伪造
-   会话劫持

------------------------------------------------------------------------

# 13. 与官方 upstream 及旧版 frp-xudp 的兼容边界

XUDP 是本仓库维护的独立扩展，当前未进入官方
`fatedier/frp` upstream。官方 upstream 的 `frpc`/`frps` 不提供
`xudp` proxy 类型，因此不能把官方旧版本当作支持 XUDP 的兼容端，也不能
声称新版本会与官方旧版本自动降级。

当前 wire v1/v2 的 `ClientHello` 能力协商只包含消息 codec、UDP packet
codec 和加密算法，不包含名为 `xudp` 的 capability 字段。
`XUDPRole` 是 `StartWorkConn` 中的可选扩展字段，用于新版本 frpc/frps
显式区分 P2P 与 Relay；它不是 capability，也不是能力协商结果。

兼容行为如下：

| 组合 | 实际行为与边界 |
| --- | --- |
| 新版 frpc + 新版支持 XUDP 的 frps | 使用 `XUDPRole` 显式选择 P2P 或 Relay。 |
| 新版 frpc + 旧版支持 XUDP 的 frps | 缺少 `XUDPRole` 时，新版 frpc 对旧 wire 行为使用 legacy probe；这不是能力协商，Relay 建立可能有首包探测延迟。 |
| 旧版 frpc + 新版支持 XUDP 的 frps | 旧版 frpc 忽略未知的 `XUDPRole` 字段，仍使用旧式首包 heuristic；可能产生 Relay 延迟或误判，必须用真实旧二进制验证。 |
| 任意 frp-xudp 版本 + 官方 upstream frps/frpc | 不保证支持 XUDP；官方端没有 XUDP proxy 类型，不应声称自动降级。 |

滚动升级支持 XUDP 的 frp-xudp 部署时：

1. 先升级所有参与 XUDP 的 frpc，包括代理端和 visitor 端。
2. 保持旧版支持 XUDP 的 frps 运行，验证新版 frpc 的 legacy P2P 与 Relay
   路径，并确认 Relay 首包行为。
3. 再升级支持 XUDP 的 frps，使新客户端可以使用显式 `XUDPRole`。
4. 最后逐步启用或扩大 XUDP 流量；不要把官方 upstream 端加入该兼容矩阵。

当前 `pkg/msg/msg_test.go` 的 v1/v2“四象限”测试只证明：增加可选
`xudp_role` 字段不会破坏简化旧结构的 JSON 解析，以及缺少该字段时当前
结构可以解析旧帧。它不证明真实旧 frpc/frps 二进制互通、XUDP capability
协商、P2P/Relay 运行时互通、首包延迟/保留、加密压缩组合或 Docker 滚动升级。

在 Docker-only 条件下，未来可以补充以下真实旧 fork 二进制矩阵；这些测试
不能替代 5G、Wi-Fi、公网 NAT、CGNAT、VPN 或真实移动网络验证：

| 服务端 | 客户端 | 路径 | 目标 |
| --- | --- | --- | --- |
| 旧版支持 XUDP 的 frps | 新版 frpc | P2P、Relay | 验证 legacy probe、首包保留和建立延迟。 |
| 新版支持 XUDP 的 frps | 旧版支持 XUDP 的 frpc | P2P、Relay | 验证旧 heuristic 的延迟、误判和字段忽略行为。 |
| 新版支持 XUDP 的 frps | 新版 frpc | 显式 P2P、Relay | 验证 `XUDPRole` 路径。 |
| 官方 upstream frps/frpc | 任一 XUDP 端 | XUDP 配置 | 明确记录为不支持/拒绝，不把失败误报为自动降级。 |

------------------------------------------------------------------------

# 14. 开发阶段

## Phase 1

完成：

-   xudp proxy
-   控制协议
-   UDP relay

## Phase 2

增加：

-   STUN
-   endpoint交换
-   UDP punch

## Phase 3

增加：

-   NAT检测
-   fallback
-   session管理

## Phase 4

优化：

-   IPv6
-   多节点
-   移动网络

------------------------------------------------------------------------

# 15. 难度评估

  模块        难度
  ----------- ------
  新增proxy   低
  配置扩展    低
  控制协议    中
  STUN        中
  UDP打洞     中高
  NAT兼容     高

------------------------------------------------------------------------

# 16. 推荐路线

第一版：

    FRP
    +
    XUDP Proxy
    +
    STUN
    +
    UDP Hole Punch
    +
    Relay fallback

目标：

实现 FRP 端口映射模型与 P2P UDP 传输结合。
