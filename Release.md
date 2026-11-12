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
