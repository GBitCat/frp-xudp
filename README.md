# frp-xudp

基于 [fatedier/frp](https://github.com/fatedier/frp) 的扩展版本，提供
**XUDP P2P UDP 代理**，并支持通过 **SUDP / XUDP 使用 SOCKS5 UDP 插件**。

[![GitHub release](https://img.shields.io/github/tag/GBitCat/frp-xudp.svg?label=release)](https://github.com/GBitCat/frp-xudp/releases)

> XUDP 为 frp 的**独立扩展**，未合入上游 fatedier/frp，仅在本仓库维护。
> `beta` 长期跟随 `upstream/dev`；上游发布 tag 仅作兼容性里程碑，详见
> [UPSTREAM_SYNC.md](UPSTREAM_SYNC.md)。

## 核心特性

- **`xudp` 代理类型**：UDP 流量在两个 frpc 之间直接 P2P 传输
  （NAT 打洞 + QUIC DATAGRAM），低延迟、不占用 frps 带宽
- **自动回退**：NAT 打洞失败（对称 NAT、STUN 不可达等）时自动回退为
  frps relay 中转，保证可用性
- **Peer Authentication**：通过 FRP control channel 交换 QUIC 证书
  fingerprint，拒绝伪造 peer
- **断线恢复**：P2P 断开后自动切到 Relay，Relay 周期探测 P2P 并切回直连
- **SOCKS5 TCP/UDP 插件**：SUDP 和 XUDP 均支持 `socks5_udp`，与
  STCP/XTCP 控制代理配对后，应用可按请求选择 TCP、UDP 目标地址和端口，
  详见[双端配置](doc/socks5-udp.md)
- **会话管理**：Session Table（INIT / PUNCHING / CONNECTED / TIMEOUT），
  自动清理过期会话
- **Keepalive**：QUIC keepalive 保持 P2P 连接与 NAT 映射存活
- **纯增量扩展**：不影响官方既有代理类型
  （tcp / udp / xtcp / stcp / sudp / http / https / tcpmux 等）

## 快速开始

1. 从 [Releases](https://github.com/GBitCat/frp-xudp/releases) 下载对应平台
   的发布包（`frp_<版本>_<os>_<arch>.tar.gz`，内含 frpc / frps 及示例配置）
2. 或使用 Docker 开发环境构建：见 [dev/README.md](dev/README.md)

## XUDP 配置示例

```toml
# frpc 服务提供端（内网 UDP 服务）
[[proxies]]
name = "game"
type = "xudp"
localIP = "127.0.0.1"
localPort = 2000
secretKey = "xudp-secret"
```

```toml
# frpc 访问端（客户端）
[[visitors]]
name = "game-visitor"
type = "xudp"
serverName = "game"
secretKey = "xudp-secret"
bindAddr = "0.0.0.0"
bindPort = 9000
```

## SOCKS5 TCP/UDP 插件

从 `0.72.0` 起，使用 `socks5_udp` 插件可通过同一个标准 SOCKS5 入口访问
提供端的 TCP 和 UDP 服务。目标地址、端口由应用在请求中指定，域名在提供端解析。

| 通道 | 代理类型 | 用途 |
| --- | --- | --- |
| TCP 控制与 TCP 数据 | `stcp` / `xtcp` | SOCKS5 协商、认证、`UDP ASSOCIATE` 控制连接及 TCP `CONNECT` |
| UDP 数据 | `sudp` | 通过 frps 中继 |
| UDP 数据 | `xudp` | 打洞成功后通过 QUIC DATAGRAM 直连，失败时自动回退中继 |

提供端需要成对配置一个 STCP/XTCP 控制代理和一个 SUDP/XUDP 数据代理；
访问端配置对应的 visitor 和 SOCKS5 入口。SOCKS5 协商及会话控制仍使用 TCP，
应用需要支持标准 `UDP ASSOCIATE`，并在 UDP 会话期间保持控制连接。

启用该功能需同时升级两端 frpc。原有 `socks5` 插件继续提供 TCP 功能。
完整的 frps、提供端、访问端配置，以及 SUDP 切换 XUDP 的方法见
[SOCKS5 TCP/UDP 双端示例](doc/socks5-udp.md)。

## 文档

- SOCKS5 TCP/UDP 插件：[doc/socks5-udp.md](doc/socks5-udp.md)
- 扩展设计：[FRP_XUDP_Extension_Design_Document.md](FRP_XUDP_Extension_Design_Document.md)
- 上游升级维护：[UPSTREAM_SYNC.md](UPSTREAM_SYNC.md)
- 开发环境：[dev/README.md](dev/README.md)
- Release 说明：[dev/RELEASE_NOTES.md](dev/RELEASE_NOTES.md)
- 官方 frp 文档：[fatedier/frp](https://github.com/fatedier/frp)

## 许可证

Apache License 2.0（与上游一致），详见 [LICENSE](LICENSE)。
