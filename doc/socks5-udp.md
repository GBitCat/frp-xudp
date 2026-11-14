# SOCKS5 TCP 与 UDP 动态目标代理

`socks5_udp` 在访问端提供标准 SOCKS5 入口；应用在请求中指定提供端可访问的地址和端口。它支持两种会话模式：

| 模式 | 提供端与访问端 | 能力 |
| --- | --- | --- |
| 自主 UDP 会话 | 单个 SUDP/XUDP 代理及 visitor | UDP `ASSOCIATE`，认证和会话管理均经 UDP 数据通道；无需 STCP/XTCP 配对 |
| 原有配对会话 | STCP/XTCP 控制代理搭配 SUDP/XUDP 数据代理 | TCP `CONNECT` 与 UDP `ASSOCIATE`，兼容首次发布的配置 |

例如，应用通过本地 `127.0.0.1:1234` 的 SOCKS5 入口，请求 TCP `127.0.0.1:6789` 或 UDP `127.0.0.1:5678`。目标地址中的 `127.0.0.1` 指提供端 frpc 所在机器。使用容器部署 frpc 时，它指该容器的网络命名空间。

原有 `socks5` 插件继续提供 TCP 功能。下文先介绍自主 UDP 会话，再给出原有 TCP+UDP 配对配置。以下示例使用 TOML。

## frps

```toml
bindPort = 7000

auth.method = "token"
auth.token = "replace-with-frp-token"
```

frps 转发通用 FRP 流量，不运行 SOCKS5 服务。示例中的 `1234`、`5678`、`6789` 不需要在 frps 上单独开放。

## 自主 UDP 会话：提供端 frpc

只需要一个 SUDP/XUDP 代理。`sessionMode = "datagram"` 显式启用自主会话；无需 `udpProxyName` 或 TCP 控制代理。

```toml
serverAddr = "frps.example.com"
serverPort = 7000
auth.method = "token"
auth.token = "replace-with-frp-token"

[[proxies]]
name = "socks-udp"
type = "sudp"
secretKey = "replace-with-a-long-random-shared-secret"

[proxies.plugin]
type = "socks5_udp"
sessionMode = "datagram"
username = "alice"
password = "replace-with-socks-password"
```

用户名、密码都省略或都为空时免 SOCKS5 认证；仅密码为空时仍需提交正确的用户名。
`secretKey` 必须非空，并与 visitor 一致，它用于保护内部会话报文，与应用填写的 SOCKS5 账号密码用途不同。

## 自主 UDP 会话：访问端 frpc

```toml
serverAddr = "frps.example.com"
serverPort = 7000
auth.method = "token"
auth.token = "replace-with-frp-token"

[[visitors]]
name = "socks-udp-visitor"
type = "sudp"
serverName = "socks-udp"
secretKey = "replace-with-a-long-random-shared-secret"
bindPort = -1

[visitors.plugin]
type = "socks5_udp"
bindAddr = "127.0.0.1"
bindPort = 1234
```

应用配置 SOCKS5 `127.0.0.1:1234`，使用 `UDP ASSOCIATE` 动态选择目标。visitor 内部数据端口自动分配，
不要配置 `udpVisitorAddr`，也不需要额外的 UDP visitor 块。外层 `bindPort = -1` 禁止公开普通 UDP 转发入口。

应用到 visitor 仍使用标准 SOCKS5 TCP 协商连接；visitor 将认证、建立、续期和关闭请求转换为数据通道内的加密控制报文。
提供端自行校验账号密码并管理 UDP 会话。两端 frpc 之间无需独立的 SOCKS5 TCP 控制连接。
此模式仅支持 UDP，TCP `CONNECT` 返回“不支持的命令”；需要 TCP 业务时可另配原有 `socks5` 插件，或使用下方配对模式。

将上面两端的 `type = "sudp"` 同时改成 `"xudp"`，即可使用现有的直连、回退与恢复机制。
逻辑会话与当前传输路径分离，短暂切换时保留目标 UDP 出口映射。认证及会话控制报文会重试，业务 UDP 数据不会因此增加重传。

## 原有配对模式：提供端 frpc

两个代理必须运行在同一个 frpc 实例中。`udpProxyName` 引用 UDP 代理的配置名称；它将 TCP 控制连接创建的会话关联到对应 UDP 插件。

```toml
serverAddr = "frps.example.com"
serverPort = 7000

auth.method = "token"
auth.token = "replace-with-frp-token"

[[proxies]]
name = "socks-tcp"
type = "stcp"
secretKey = "replace-with-control-secret"

[proxies.plugin]
type = "socks5_udp"
username = "alice"
password = "replace-with-socks-password"
udpProxyName = "socks-udp"

[[proxies]]
name = "socks-udp"
type = "sudp"
secretKey = "replace-with-datagram-secret"

[proxies.plugin]
type = "socks5_udp"
```

无需设置 `localIP` 或 `localPort`：目标由每个 SOCKS5 请求指定。域名也在提供端解析。SOCKS5 用户名和密码配置在 TCP 控制代理上；UDP 代理依照已认证的控制会话接受数据。

如果配置 `user = "provider"`，这里的 `udpProxyName` 仍写 `"socks-udp"`。访问端使用 `serverUser = "provider"` 选择提供端命名空间。访问端使用不同 `user` 时，还应在提供端两个代理块中分别配置 `allowUsers = ["访问端的 user"]`。

## 原有配对模式：访问端 frpc

```toml
serverAddr = "frps.example.com"
serverPort = 7000

auth.method = "token"
auth.token = "replace-with-frp-token"

[[visitors]]
name = "socks-control"
type = "stcp"
serverName = "socks-tcp"
secretKey = "replace-with-control-secret"
bindPort = -1

[visitors.plugin]
type = "socks5_udp"
bindAddr = "127.0.0.1"
bindPort = 1234
udpVisitorAddr = "127.0.0.1:1234"

[[visitors]]
name = "socks-data"
type = "sudp"
serverName = "socks-udp"
secretKey = "replace-with-datagram-secret"
bindAddr = "127.0.0.1"
bindPort = 1234
```

TCP visitor 的 `bindPort = -1` 将流连接交给插件；`plugin.bindPort = 1234` 是应用配置的 SOCKS5 TCP 入口。`udpVisitorAddr` 指向同一机器上的 UDP visitor，它只允许使用 loopback IP 地址。

这里 TCP 1234 是 SOCKS5 入口，UDP 1234 是插件连接的 FRP 数据入口，两者可以使用同一个端口号。**应用应将 UDP 数据发往 `UDP ASSOCIATE` 回复中的地址和端口，而不是自行假定 UDP 端口也是 1234。** 插件为每个 association 分配独立的 UDP 接收端口，以支持同一 IP 上的多个客户端。

## 使用 XUDP 直连

自主模式和配对模式均支持 XUDP。以下代理名称对应上面的配对示例。

将提供端 `socks-udp` 和访问端 `socks-data` 两个配置块的 `type` 从 `"sudp"` 改为 `"xudp"`，其他配对配置保持一致。

- 打洞成功时，SOCKS5 UDP 数据通过 XUDP QUIC DATAGRAM 在两个 frpc 之间直连。
- 打洞失败时使用 XUDP 的 frps 中继回退；中继期间继续按现有策略探测直连。
- 会话的 UDP 目标 socket 与数据通道分离，直连/中继切换不会主动重建目标映射。切换期间 UDP 数据仍可能丢失。
- 配对模式的 visitor 每 2 秒发送一个内部会话绑定帧，用于在没有应用上行数据时刷新提供端回程通道。自主模式通过会话续期刷新回程通道。两种控制报文均不会转发给目标服务，也不刷新目标 socket 的空闲计时；通道恢复到绑定生效之间可能短暂丢包。
- 示例中的 TCP `CONNECT` 和 SOCKS5 控制连接使用 STCP。需要 TCP 也尝试直连时，可将两端控制代理的类型都改成 XTCP，并按 XTCP 的现有配置安排回退。

XUDP 业务数据直连不表示所有 FRP 控制流量都直连，也不表示 SUDP/XUDP 中继具有不重传的数据报语义。中继仍复用现有的可靠流传输。

## 应用侧协议

配对模式的 TCP 访问使用普通 SOCKS5 `CONNECT`。例如，若提供端 TCP 6789 是 HTTP 服务：

```sh
curl --socks5-hostname 127.0.0.1:1234 \
  --proxy-user 'alice:replace-with-socks-password' \
  http://127.0.0.1:6789/
```

UDP 应用需要支持 RFC 1928 的 `UDP ASSOCIATE`：

1. 连接 TCP 1234，完成 SOCKS5 协商与认证。
2. 发送 `UDP ASSOCIATE`。此请求的地址字段表示客户端 UDP 来源；未确定时发送全零地址和端口。
3. 从回复中取得实际 UDP 接收地址。每个发往该地址的数据包使用 SOCKS5 UDP 头，头部目标可以是 `127.0.0.1:5678`，也可以是其他地址/端口。
4. 保持应用到 visitor 的 TCP 控制连接打开。关闭它会停止本地 UDP 服务并通知提供端回收 association。

TCP 模式的 `curl --socks5` 不能用于验证 `UDP ASSOCIATE`。仓库的 `[Feature: SOCKS5-UDP]` 端到端测试使用独立的标准 SOCKS5 客户端验证 UDP 流程。

## 边界与运行行为

- UDP 来源绑定到控制连接的客户端 IP；客户端明确提供源端口时遵守该端口，否则使用首次合法 UDP 包的源端口。其他来源不能借用 association。
- 不支持 SOCKS5 UDP 分片，`FRAG != 0` 的包会被丢弃。
- XUDP 的 MTU 限制作用于完整编码后的数据报。SOCKS5 头和内部会话封装会占用额外空间；超限数据报可能被丢弃，应用应使用较小的 UDP payload。
- 应用只能在本地 SOCKS5 控制会话存活期间使用 UDP。自主模式不依赖跨端 STCP/XTCP 连接；关闭请求会重试，完全失联时由提供端会话有效期兜底回收。默认有效期为 60 秒，visitor 每 10 秒续期；失联超过有效期后需要重新建立 SOCKS5 会话。
- 通道建立最多等待 60 秒，涵盖打洞与回退；通道就绪后的 SOCKS5 协商与认证另有 10 秒期限。应用自身的 SOCKS5 连接超时也需要覆盖预期的打洞和回退时间。
- 同一 association 的 IPv4、IPv6 流量分别共用一个 UDP 出口 socket，同地址族切换目标端口时保持出口端口。提供端接受近期已访问目标 IP 从其他端口发来的回复，并在 SOCKS5 UDP 头中返回实际来源地址与端口，以支持 TFTP 一类需要切换服务端端口的协议；未访问过的来源 IP 会被丢弃。
- 每个 UDP 代理最多保留 1024 个 association、4096 条活动目标记录；每个 association 最多保留 64 条活动目标记录，最多使用两个出口 socket。目标记录空闲 2 分钟后回收；某地址族没有活动目标时回收其 socket。TCP association 可以继续保持，后续业务数据会重新建立目标映射，因此长时间闲置后 UDP 出口端口可能变化。
- 本功能同时需要提供端和访问端的新版本 frpc。frps 不解析插件内部协议。
- 自主模式必须显式配置 `sessionMode = "datagram"`；省略该字段或填写 `"paired"` 保持原有配对语义。旧配对配置中的 UDP 代理不会自动开放免认证的自主会话。自主模式需要两端同时升级到支持它的构建；相同的 `0.72.0` 版本字符串不能区分覆盖发布前后的构建，请核对发布说明和校验和。

## 测试

在 Docker 开发容器中构建 frpc/frps 后，可运行：

```sh
go test ./test/e2e -run TestE2E -args \
  -frpc-path /tmp/frp-bin/frpc \
  -frps-path /tmp/frp-bin/frps \
  -ginkgo.focus 'Feature: SOCKS5-UDP'
```

这组端到端测试覆盖自主模式与原有配对模式的真实 SUDP、XUDP 中继路径，验证认证、免认证、空密码、UDP 动态目标、跨服务端端口回复及后续请求的出口端口保持、提供端域名解析、同 IP 多会话隔离、分片拒绝和关闭回收。同时验证配对模式接受 TCP CONNECT，自主模式返回命令不支持。XUDP 中继测试故意使用不可用的本地 STUN 地址，不能将其当作打洞成功的证据。

真实 QUIC DATAGRAM 数据通道及映射保持另有确定性测试：

```sh
go test ./client/proxy -run 'TestSOCKS5UDP(XUDPTransportSwitchKeepsTargetMapping|DatagramXUDPTransportSwitchKeepsSession)'
```

这些测试通过本机互相认证的 QUIC 连接进入生产 P2P 转发分支，验证中继→直连→中继时提供端 UDP 源端口保持。自主模式额外验证仅凭续期报文恢复接收方向、关闭后释放远端 socket，以及重放旧加密报文无法恢复已撤销的会话。它们验证数据通道集成，不验证公网 NAT 打洞成功率。
