## 实现

- 新增 `pkg/xudp/transport/quic.go`，提供 `pkg/xudp/transport` 的 QUIC DATAGRAM transport 抽象，启用 RFC 9221 datagram，关闭 stream，不新增用户配置。
- 更新 `client/proxy/xudp.go`：NAT 打洞成功后，在已打通的 UDP socket 上启动 QUIC listener，再把 datagram 与本地 UDP 服务桥接。
- 更新 `client/visitor/xudp.go`：P2P 成功后通过 QUIC DATAGRAM 收发 XUDP UDP 包，失败仍走原 relay fallback。
- 新增 `pkg/xudp/transport/quic_test.go`，覆盖默认参数和 datagram-only 配置。
- 新增 `pkg/xudp/transport/identity.go`，通过临时证书 SHA-256 fingerprint 做 QUIC peer authentication。
- 新增 `pkg/xudp/transport/mtu.go`，采用保守 1150 字节 encoded datagram 限制，给 QUIC/UDP 开销留出空间，避免 IP fragmentation。
- 新增 `pkg/xudp/state/state.go`，提供显式 P2P/Relay 状态机和 generation/transport epoch。
- Visitor 支持 P2P 断线自动 Relay、Relay 周期探测并恢复 P2P。
- SUDP 的消息格式、数据流向和安全模型未改；visitor 并发关闭与资源回收已加固。
- XUDP Relay 的池化压缩读写器现在随实际连接关闭一次性回收，不会在活动连接
  返回后提前进入全局池。
- 服务端 UDP work connection 重连会先 join 旧 reader/sender，并将旧连接写失败的
  首个报文优先交给新连接，避免新旧 sender 同时消费共享队列。
