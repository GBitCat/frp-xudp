## Rebuilt v0.72.0: Lifecycle, Bandwidth and Visitor Editor Fixes

* Restored the Go build and executable runtime stages in both production Dockerfiles, including the frpc/frps entrypoints.
* Cancel autonomous SOCKS5 UDP setup when the local application disconnects, releasing pending client slots and UDP sockets while preserving valid pipelined authentication and request bytes in a bounded buffer.
* Cancel XUDP relay setup during shutdown or reload, including QUIC stream allocation and visitor handshake I/O. Legacy dial results that arrive after cancellation are closed without interrupting other streams on the shared connection.
* Apply the existing client bandwidth budget to both directions of XUDP P2P traffic as well as relay traffic. Small bursts preserve complete datagrams, and shutdown cancels pending rate waits.
* Preserve SOCKS5 plugins and unexposed configuration fields when editing visitors in the Web dashboard. STCP/XTCP/SUDP SOCKS5 options are editable, including SUDP with `bindPort = -1`. XUDP management API and Web configuration support remain outside this update.
* Validation: unit tests, affected race suites, static checks, 26 frontend tests, frontend type checking/builds, and native amd64 Docker image builds/startup passed. Full E2E: 268 passed, 2 skipped due to unstable STUN. Some upstream dial operations cannot be canceled internally; XUDP shutdown stops waiting and closes any late connection.
* The version remains `0.72.0`; use the new release checksums to identify this rebuild.

## Rebuilt v0.72.0: Autonomous SOCKS5 UDP Sessions

* Added `sessionMode = "datagram"` to the SUDP/XUDP `socks5_udp` plugin. Authentication, creation, renewal and closure now run over the datagram channel without a paired STCP/XTCP proxy or `udpProxyName`.
* SUDP/XUDP visitors can expose a standard local SOCKS5 UDP entry directly, with an automatically allocated private UDP transport socket. The application keeps its standard SOCKS5 TCP connection locally; this mode only accepts UDP ASSOCIATE.
* Session control uses encrypted authenticated frames, retries, replay protection and bounded leases. Logical sessions retain UDP target mappings across XUDP direct/relay transitions. Omitted `sessionMode` preserves the existing paired configuration and authentication policy.
* Both frpc endpoints must use this rebuilt package and a matching nonempty `secretKey`. The version remains `0.72.0`; identify the updated archives using the release checksums.

## Upstream Sync

* Synced 48 commits from `fatedier/frp`'s development branch through `a2c975efb5e55102068065d61cfc17ffe34e939d`, preserving this fork's XUDP direct transport, relay fallback and recovery. This fork release is version `0.72.0`; its upstream baseline is a development commit.
* Updated the toolchain and transport dependencies to Go 1.26, quic-go 0.65.0 and yamux 0.3.0.

## Features

* Added the `socks5_udp` plugin for standard SOCKS5 TCP `CONNECT` and UDP `ASSOCIATE`. Pair STCP/XTCP control proxies with SUDP/XUDP datagram proxies to select remote TCP and UDP targets dynamically, with DNS resolution at the provider. XUDP carries UDP traffic over direct QUIC DATAGRAM connections when traversal succeeds and falls back to frps relay otherwise.
* Added SOCKS5 username/password authentication, isolated UDP associations, control-connection-based cleanup, and preservation of active UDP mappings across XUDP direct/relay transitions. Both provider and visitor frpc must be upgraded. The original `socks5` plugin remains available for TCP. See the [paired configuration examples](https://github.com/GBitCat/frp-xudp/blob/v0.72.0/doc/socks5-udp.md).
* frpc can verify server certificates using system CAs, optionally combined with CAs from `trustedCaFile`.
* `frpc reload` now refreshes certificate files for unchanged `https2http` and `https2https` proxies without interrupting existing connections. Failed refreshes keep the previous certificate and report the error in proxy status and logs while reload still succeeds.
* Added `metricsServer` to both frps and frpc, a separate listener for health checks, metrics and optional profiling that does not expose the dashboard or the admin API. It is disabled unless `metricsServer.port` is set, defaults to `127.0.0.1`, and has its own credentials and TLS. Setting the port serves `/metrics` on both: frps exposes runtime and business metrics, so `enablePrometheus` is not needed there, and frpc exposes Go runtime metrics only, without linking an extra metrics library.

  The `/healthz`, `/metrics` and pprof endpoints on `webServer`, `webServer.pprofEnable` and `enablePrometheus` still work but are deprecated: configure `metricsServer` instead. They will continue to work until v0.80.0 is released, and may be removed in v0.80.0 or later.

## Fixes

* SOCKS5 UDP replies can arrive from a different port on a contacted target IP. Replies expose their actual source address and port, and follow-up requests retain the association's UDP source port, supporting protocols such as TFTP.
* Cancel pending bandwidth reservations when work connections close, preventing SUDP/XUDP and SOCKS5 control shutdown or reload from waiting for accumulated rate-limit delays.
* Separate tunnel establishment from the SOCKS5 handshake deadline so delayed XTCP traversal or STCP fallback does not prematurely terminate valid SOCKS5 connections.
* Explicitly release the frps QUIC UDP socket when closing its listener or cleaning up a failed startup.
* Fixed proxy and visitor configuration changes being lost when reloading frpc during reconnection.
* Updated yamux to fix a 100% CPU busy loop after a session shuts down and a session close that could hang when the underlying connection (for example WebSocket) blocks on a write, which could also delay reconnection.
* frps now closes the multiplexed session of a replaced or failed control connection immediately, releasing its streams and work connections instead of keeping them until keepalive times out.
* Fixed a data race when frpc updates log prefixes while other goroutines are logging, which could crash the process.
* Fixed HTTPS and tcpmux route listeners leaving a pending connection open when the listener is removed during connection handoff; the connection is now closed instead of leaving the client to wait for a read timeout.
