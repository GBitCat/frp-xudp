## 实现

- 新增 `pkg/xudp/transport/quic.go`，提供 `pkg/xudp/transport` 的 QUIC DATAGRAM transport 抽象，启用 RFC 9221 datagram，关闭 stream，不新增用户配置。
- 更新 `client/proxy/xudp.go`：NAT 打洞成功后，在已打通的 UDP socket 上启动 QUIC listener，再把 datagram 与本地 UDP 服务桥接。
- 更新 `client/visitor/xudp.go`：P2P 成功后通过 QUIC DATAGRAM 收发 XUDP UDP 包，失败仍走原 relay fallback。
- 新增 `pkg/xudp/transport/quic_test.go`，覆盖默认参数和 datagram-only 配置。
- SUDP 数据路径未改。
