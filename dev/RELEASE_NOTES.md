本次 0.72.0 更新同步上游开发分支，并新增 SUDP / XUDP 的 SOCKS5 UDP 插件支持。

## 同步上游更新

- 同步 `fatedier/frp` 的 `upstream/dev` 至
  [`a2c975ef`](https://github.com/fatedier/frp/commit/a2c975efb5e55102068065d61cfc17ffe34e939d)，
  纳入 48 个上游提交，并保留本仓库的 XUDP 直连、中继回退和恢复机制。
- 新增独立的 `metricsServer`，可单独提供健康检查、指标和可选的性能分析端点，
  无需暴露管理接口；frpc 支持使用系统 CA 验证 frps 证书。
- `frpc reload` 支持刷新 HTTPS 插件证书；修复重连期间配置更新丢失、
  控制连接替换后的会话回收、日志前缀并发访问和路由监听器关闭时的连接泄漏等问题。
- 更新至 Go 1.26、quic-go 0.65.0 和 yamux 0.3.0，并吸收相关依赖与构建流程更新。

这里的同步基线是上游开发分支提交；`0.72.0` 是本仓库的发布版本。

## 新增 SOCKS5 UDP 插件

- 新增 `socks5_udp`，支持标准 SOCKS5 TCP `CONNECT` 和 UDP `ASSOCIATE`。
  应用可动态指定提供端可访问的目标地址、端口，域名由提供端解析。
- 配对模式使用 STCP/XTCP 提供 TCP 控制与 TCP 数据通道，SUDP/XUDP 提供 UDP 数据通道。
  XUDP 打洞成功后通过 QUIC DATAGRAM 直连，失败时自动回退 frps 中继。
- 提供端设置 `sessionMode = "datagram"` 后，SUDP/XUDP 可自行完成认证、建立、续期和关闭会话，
  无需 STCP/XTCP 控制代理或 `udpProxyName`。
- 自主模式的 visitor 直接使用 SUDP/XUDP 的 `socks5_udp` 插件提供本地标准 SOCKS5 入口，
  内部数据端口自动分配，无需额外 visitor 块或 `udpVisitorAddr`；此模式仅支持 UDP `ASSOCIATE`。
- 支持用户名/密码认证、同 IP 多会话隔离、会话撤销与失联清理。
  自主模式跨端控制包含加密报文、应答重试、会话有效期和防重放；XUDP 直连与中继切换时保留活动会话的 UDP 出口映射。
- 支持目标从不同 UDP 端口回复，并在后续访问新端口时保持会话出口端口，
  适用于 TFTP 一类需要切换服务端端口的协议。
- Web 管理界面支持显示、编辑 STCP/XTCP/SUDP visitor 的 `socks5_udp` 插件，
  支持 SUDP 的 `bindPort = -1`，编辑其他字段时保留原插件及页面未展示的配置。
  XUDP 继续通过配置文件管理。

## 修复与改进

- 修复旧 `socks5` TCP 插件未传递目标 EOF 的问题，避免依赖连接关闭判断响应结束的客户端持续等待或超时。
- 自主 UDP 模式在本地 SOCKS5 应用断开时取消拨号、协商与认证等待，释放连接名额及 UDP socket。
- XUDP 关闭或重载时取消对中继拨号、请求读写及 QUIC 开流的等待，并回收迟到连接；
  限速等待可随连接关闭取消，避免关闭、重载被阻塞。
- XUDP P2P 双向流量遵守客户端 `transport.bandwidthLimit`，与中继共享配额，低速配置下保持数据报完整。
- 将控制通道建立与 SOCKS5 握手分别计时，避免 XTCP 较慢的打洞或回退提前耗尽握手期限。
- 修复 frps QUIC 监听器关闭后的 UDP 端口回收，保留启动失败时的资源清理。
- 修复 frpc/frps Dockerfile 的 Go 编译、运行阶段与启动入口，确保镜像包含可运行的服务程序。

## 使用说明

自主模式只需要一个 SUDP/XUDP 代理及对应 visitor；两端 frpc 均须支持此模式，并配置相同且非空的 `secretKey`。
省略 `sessionMode` 或设置 `"paired"` 保留配对模式，可同时处理 TCP 与 UDP。

UDP 应用须支持 `UDP ASSOCIATE`，使用回复中的 UDP 接收地址，并保持应用到 visitor 的 TCP 控制连接。
自主模式的跨端会话控制走 UDP；插件不对业务 UDP 额外重传，底层中继仍使用现有可靠传输。
原有 `socks5` 插件继续提供 TCP 功能。

完整配置见 [SOCKS5 TCP/UDP 双端示例](https://github.com/GBitCat/frp-xudp/blob/v0.72.0/doc/socks5-udp.md)。
