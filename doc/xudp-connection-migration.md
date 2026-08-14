# XUDP Connection Migration

XUDP P2P uses QUIC Connection IDs, so a logical QUIC connection is not bound
to a single IP/port 5-tuple. In the current implementation:

- NAT Hole Punching is responsible for discovering and punching a usable UDP
  path.
- QUIC runs on the already punched UDP socket and may validate a new path if
  the underlying UDP socket keeps receiving packets from the peer.
- XUDP does not allocate an additional public QUIC port.

For a changed NAT mapping or network interface, FRP must usually perform a
new NAT-hole exchange before QUIC can validate the new path. The recovery loop
already re-runs NAT Hole Punching and QUIC handshake, then switches the active
transport under a new generation/epoch.

Full seamless Wi-Fi to 5G migration still requires a real multi-network test
matrix. It is intentionally not implemented as a blocking prerequisite for
authentication, MTU, state machine, fallback, or recovery.
