## 核心特性：XUDP P2P UDP 代理

为 frp 新增 `xudp` 代理类型，让 UDP 流量在两个 frpc 之间**直接 P2P 传输**，
不再依赖 frps 中转：

> XUDP 为 frp 的独立扩展，未合入上游 fatedier/frp，仅在本仓库维护。

- **P2P 直连**：基于 NAT 打洞（STUN + 端点交换）建立 frpc 之间的直接 UDP
  通道，低延迟，不占用 frps 带宽
- **自动回退**：NAT 打洞失败（对称 NAT、STUN 不可达等）时自动回退为
  frps relay 中转，保证可用性
- **会话管理**：内置 Session Table（INIT / PUNCHING / CONNECTED / TIMEOUT），
  自动清理过期会话
- **Keepalive**：P2P 连接定期心跳，保持 NAT 映射存活
- **纯增量扩展**：不影响官方既有代理类型（tcp / udp / xtcp / stcp / sudp /
  http / https / tcpmux 等），新旧 frpc/frps 兼容

## 新增配置

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

## 验证结果（三容器测试）

- **P2P 路径**：NAT 打洞成功建立直连，UDP echo 往返正常
- **Relay 回退**：STUN 不可达时自动回退 frps 中转，UDP echo 往返正常

## 相关文档

- 扩展设计：<https://github.com/GBitCat/frp-xudp/blob/dev/FRP_XUDP_Extension_Design_Document.md>
- 上游升级维护：<https://github.com/GBitCat/frp-xudp/blob/dev/UPSTREAM_SYNC.md>
- 开发环境：<https://github.com/GBitCat/frp-xudp/blob/dev/dev/README.md>
