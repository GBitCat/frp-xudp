本次 `0.72.0` 更新同步上游开发分支，并新增 SUDP / XUDP 的 SOCKS5 UDP 插件支持。

## 同步上游更新

- 同步 `fatedier/frp` 的 `upstream/dev` 至
  [`a2c975ef`](https://github.com/fatedier/frp/commit/a2c975efb5e55102068065d61cfc17ffe34e939d)，
  纳入 48 个上游提交，并保留本仓库的 XUDP 直连、中继回退和恢复机制。
- 新增独立的 `metricsServer`，可单独提供健康检查、指标和可选的性能分析端点，
  无需暴露管理接口；frpc 支持使用系统 CA 验证 frps 证书。
- `frpc reload` 支持刷新 HTTPS 插件证书；修复重连期间配置更新丢失、
  控制连接替换后的会话回收、日志前缀并发访问和路由监听器关闭时的连接泄漏等问题。
- 更新至 Go 1.26、quic-go 0.65.0 和 yamux 0.3.0，并吸收相关依赖与构建流程更新。

这里的同步基线是上游开发分支提交；`0.72.0` 是本仓库此次发布版本。

## 新增 SOCKS5 UDP 插件

- 新增 `socks5_udp`，支持标准 SOCKS5 TCP `CONNECT` 和 UDP `ASSOCIATE`。
  应用可动态指定提供端可访问的目标地址、端口，域名由提供端解析。
- SUDP 和 XUDP 均可作为 UDP 数据通道；STCP/XTCP 提供 TCP 控制与 TCP 数据通道。
  XUDP 打洞成功后通过 QUIC DATAGRAM 直连，失败时自动回退 frps 中继。
- 支持用户名/密码认证、同 IP 多会话隔离和控制连接关闭时的资源回收。
  XUDP 直连与中继切换时保留活动会话的 UDP 出口映射。
- 支持目标从不同 UDP 端口回复，并在后续访问新端口时保持会话出口端口，
  适用于 TFTP 一类需要切换服务端端口的协议。

## 修复与验证

- 限速等待可在连接关闭时取消，避免 SUDP/XUDP 及 SOCKS5 控制通道的关闭、重载被积压的限速等待阻塞。
- 将控制通道建立与 SOCKS5 握手分别计时，避免 XTCP 较慢的打洞或回退提前耗尽握手期限。
- 修复 frps QUIC 监听器关闭后的 UDP 端口回收，保留启动失败时的资源清理。
- Docker 全量端到端测试 264 项通过、2 项既有跳过；单元测试、相关竞态检查及静态检查通过。
  已验证真实 QUIC DATAGRAM 数据通道与直连/中继切换；公网 NAT 打洞成功率尚未实测。
- 常规协议兼容性测试覆盖最近 8 个上游稳定版本（0.68.1 至 0.72.0）及支持下限 0.61.0，
  共 58 项通过、14 项预期跳过，验证新旧 frpc/frps 组合的默认协议与 UDP 传输。

## 使用说明

启用 `socks5_udp` 需要同时升级提供端和访问端 frpc，并成对配置 TCP 控制代理与 UDP 数据代理。
SOCKS5 协商、认证和会话控制仍使用 TCP；UDP 应用须支持 `UDP ASSOCIATE`，
使用回复中的 UDP 接收地址，并保持 TCP 控制连接。原有 `socks5` 插件继续提供 TCP 功能。

完整配置见 [SOCKS5 TCP/UDP 双端示例](https://github.com/GBitCat/frp-xudp/blob/v0.72.0/doc/socks5-udp.md)。
