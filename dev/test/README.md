# XUDP Docker test scripts

These scripts are limited to capabilities available in the local Docker
environment. Results prove only behavior observed on Docker bridge networking
or development-container loopback. They do not cover public Internet paths,
public NAT, CGNAT, VPN, 5G, Wi-Fi, carrier mobility, or real path changes.

The standard proxy and visitor fixtures enable `transport.useCompression` on
both ends. Relay smoke tests therefore exercise the pooled compression
reader/writer lifecycle as well as multi-packet delivery; P2P tests confirm
that the same setting does not alter the QUIC DATAGRAM path.

## Persistent reports

Both scripts exclusively create a new report and refuse an existing path or
symbolic link. The default directory is `dev/test/reports/`; generated reports
are intentionally ignored by Git while `reports/.gitignore` keeps the directory
policy in the repository.

For a user-selected report path, every existing parent-directory component
must be trusted by the caller. The scripts guarantee exclusive creation of the
leaf file and keep writes bound to that opened file descriptor, but normal path
resolution still follows existing parent-directory components.

```bash
bash dev/test/run-xudp-recovery-docker.sh --existing
bash dev/test/run-xudp-pmtud-docker.sh
```

Use `--report PATH` or `FRP_XUDP_RECOVERY_REPORT=PATH` for a recovery report,
and `XUDP_PMTUD_REPORT=PATH` for a PMTUD report. A report path is never
overwritten. Each report records its mode, UTC timestamps, source/container
metadata, scope limitations, observations, and a final `RESULT=PASS` or
`RESULT=FAIL` line written exactly once by an EXIT trap. Recovery reports always
record separate `old_runtime_cleanup_*` and `current_runtime_cleanup_*` field
sets, followed by an aggregate `cleanup_status`. An old-runtime result cannot be
overwritten by current-runtime EXIT cleanup. Any actual deletion failure makes
the aggregate cleanup fail; it preserves an existing nonzero main-flow code and
changes an otherwise successful final code to `1`.

Recreated scenarios also record `runtime_dir` and
`container_start_attempted`. Immediately before the first `docker run`, current
runtime state becomes `RETAINED_AFTER_CONTAINER_START_ATTEMPT` on either later
success or failure. This name deliberately records only that startup was
attempted; it does not claim that a container successfully entered the running
state. Retention is conservative because a successful or partially successful
startup may have established bind mounts that still depend on the directory.

The PMTUD script keeps the originally created report file descriptor open for
the whole run. It never reopens the report path for output, so replacing that
directory entry cannot redirect later writes to another inode.

`--existing` and the PMTUD script do not restart, remove, or recreate a
container. Recovery `--p2p` and `--relay` require `--recreate`, and lifecycle
changes are hard-limited to containers named exactly `frpsA`, `frpcB`, and
`frpC`. Before a recreate removes those names, the script read-only inspects
their mount sources. It recognizes only a single common directory matching
exactly `/tmp/frp-xudp-smoke.` followed by six ASCII alphanumeric characters.
Only after `docker rm` succeeds may that old directory be removed. Missing,
different, multiple, malformed, or unrelated mount roots are never selected
for automatic deletion. The new runtime directory is retained until a later
recreate removes the containers that use it; failures before the first
`docker run` still clean the unused new directory.

The UDP sender has a 12-second application deadline because the first packet
may need to establish P2P or complete the bounded relay fallback. The probe
wraps it with GNU `timeout` as `timeout --foreground 15 UDP_SEND ...`, leaving
the helper time to report its own failure before the external watchdog fires.
There is deliberately no `--` between the duration and the already validated
absolute UDP sender path, because the installed GNU timeout treats an argument
in that position as the command to execute.

## Non-destructive script checks

The hardening test supplies fake `docker`, `timeout`, and `udp_send` commands.
It does not contact the real Docker daemon:

```bash
bash -n dev/test/run-xudp-recovery-docker.sh \
  dev/test/run-xudp-pmtud-docker.sh \
  dev/test/test-xudp-docker-scripts.sh
bash dev/test/test-xudp-docker-scripts.sh
```

The fake validates the argument layout exercised for `inspect`, `network
inspect`, `exec`, `cp`, `rm`, `run`, `logs`, and GNU `timeout`. It also checks
runtime retention after a container-start attempt, pre-start cleanup, separate
old/current cleanup results, and conservative cleanup of an old common
controlled runtime directory. It rejects deletion when container mount roots
are different, missing, or non-unique. Real lifecycle behavior
and Docker-engine integration remain a step-7 concern; this script-level suite
does not treat fake `cp`/`rm`/`run` behavior as a real-container result.
