# XUDP QUIC DATAGRAM Benchmark

Run the current micro-benchmarks from the repository root:

```bash
go test ./pkg/xudp/transport -run '^$' -bench . -benchmem
```

Planned comparison:

- A: original XUDP raw UDP path.
- B: current XUDP QUIC DATAGRAM path.

Packet sizes: 64, 256, 512, 1200, 1280, 1400 bytes.

Primary metrics: throughput, PPS, CPU/Gbps, CPU/100k PPS, average/P50/P95/P99
latency, packet loss, and connection establishment time.

The current micro-benchmarks cover the XUDP datagram size guard and the binary
UDP packet codec. Full QUIC transport benchmarks should be run with the same
three-container topology and an external UDP traffic generator.
