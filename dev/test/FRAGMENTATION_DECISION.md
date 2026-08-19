# XUDP Fragmentation Decision (Docker-only)

## Decision

**Do not implement application-level fragmentation for the current beta.**

The available evidence does not demonstrate that fragmentation is necessary. The
current XUDP behavior is deliberately conservative: an encoded datagram above
the configured limit is rejected as a packet-level condition, while the QUIC
transport remains usable for subsequent datagrams.

This is a scope decision for the current Docker-validated beta, not a claim that
fragmentation can never be useful on other network paths.

## Evidence currently available

The Docker-only PMTUD control script and transport tests provide the following
evidence:

- payloads at `limit-1` and `limit` are delivered successfully;
- payload `limit+1` is rejected as `ErrDatagramTooLarge`;
- the oversized packet is not delivered, but the QUIC connection remains active;
- a smaller packet sent immediately after the rejected packet is delivered;
- PMTUD OFF and experimental ON loopback variants both preserve datagram
  interoperability;
- the production default remains PMTUD OFF with the conservative XUDP limit.

The key behavior is packet-level drop, not transport failure:

```text
limit-1 / limit  -> delivered
limit+1          -> dropped, ErrDatagramTooLarge
next small packet -> delivered, same QUIC connection
```

This shows that an oversized application datagram does not currently force a
Relay fallback or a QUIC reconnect. It does **not** measure a public path MTU,
prove a fragmentation gain, or establish behavior on 5G, Wi-Fi, VPN, CGNAT,
public Internet, or other networks outside the Docker environment.

## Why the evidence is insufficient to justify fragmentation

No Docker result currently shows all of the following at the same time:

1. a meaningful rate of application datagrams exceeding the conservative limit;
2. those datagrams being useful enough that dropping them materially harms the
   XUDP workload;
3. a reproducible larger path ceiling that could be used safely for fragments;
4. an end-to-end reliability or latency improvement after fragmentation.

Without those measurements, fragmentation would add protocol state, reassembly
timeouts, memory limits, duplicate handling, ordering rules, and recovery
interactions without evidence that the added complexity solves a current beta
problem.

## Minimal Docker validation

Syntax check:

```bash
bash -n dev/test/run-xudp-pmtud-docker.sh
```

Run the Docker-only PMTUD and connection-alive checks:

```bash
bash dev/test/run-xudp-pmtud-docker.sh
```

The default report is exclusively created under `dev/test/reports/` and is
never overwritten. Set `XUDP_PMTUD_REPORT` to choose another new path. Report
output stays attached to the initially opened file descriptor, so a later path
replacement cannot redirect output to a different inode. Script-level
hardening can be checked without contacting Docker:

Existing parent-directory components of a user-selected report path must be
trusted. Exclusive creation protects the leaf and FD-bound output prevents
later leaf replacement from redirecting writes, but parent path resolution
still follows existing directory components.

```bash
bash dev/test/test-xudp-docker-scripts.sh
```

The relevant transport test is:

```bash
go test ./pkg/xudp/transport -run TestQUICOversizedDatagramKeepsConnection -v
```

In Docker, this test must be interpreted as follows: oversize is a packet-level
drop (`ErrDatagramTooLarge`); it must not close or invalidate the QUIC
connection, and the next small datagram must still be received.

## Re-evaluation criteria

Reconsider fragmentation only after Docker-reproducible tests collect at least:

- oversize ratio by payload size and workload, not only one boundary sample;
- delivered, dropped, and post-oversize delivery counts;
- P50/P95/P99 latency and recovery time;
- CPU, memory, allocation, and reassembly-buffer usage;
- duplicate, out-of-order, missing-fragment, timeout, and concurrent-session
  behavior;
- comparisons against the current packet-drop behavior using the same workload;
- results under controlled Docker network constraints such as bridge MTU,
  delay, loss, and rate limits.

Even if these criteria show a benefit, fragmentation should remain disabled by
default until bounded fragment count, maximum reassembly memory, timeout, and
failure semantics are specified and tested.

## Explicit test boundary

This decision is based only on reproducible Docker tests. It makes no claim of
coverage for 5G, Wi-Fi, public Internet, NAT, CGNAT, VPN, or any other external
network topology.
