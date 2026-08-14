# frp-xudp

基于 [fatedier/frp](https://github.com/fatedier/frp) 的扩展版本，新增
**XUDP P2P UDP 代理**能力。

[![GitHub release](https://img.shields.io/github/tag/GBitCat/frp-xudp.svg?label=release)](https://github.com/GBitCat/frp-xudp/releases)

> XUDP 为 frp 的**独立扩展**，未合入上游 fatedier/frp，仅在本仓库维护。
> 版本号与上游发布对齐，可跟随上游发布 tag 升级，详见
> [UPSTREAM_SYNC.md](UPSTREAM_SYNC.md)。

## 核心特性

- **`xudp` 代理类型**：UDP 流量在两个 frpc 之间直接 P2P 传输
  （NAT 打洞 + QUIC DATAGRAM），低延迟、不占用 frps 带宽
- **自动回退**：NAT 打洞失败（对称 NAT、STUN 不可达等）时自动回退为
  frps relay 中转，保证可用性
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

## 文档

- 扩展设计：[FRP_XUDP_Extension_Design_Document.md](FRP_XUDP_Extension_Design_Document.md)
- 上游升级维护：[UPSTREAM_SYNC.md](UPSTREAM_SYNC.md)
- 开发环境：[dev/README.md](dev/README.md)
- Release 说明：[dev/RELEASE_NOTES.md](dev/RELEASE_NOTES.md)
- 官方 frp 文档：[fatedier/frp](https://github.com/fatedier/frp)

## 许可证

Apache License 2.0（与上游一致），详见 [LICENSE](LICENSE)。
