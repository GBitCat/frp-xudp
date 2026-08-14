// XUDP extension: explicit P2P / relay state machine.

package state

import (
	"sync"
	"sync/atomic"
)

type Phase string

const (
	PhaseInit           Phase = "INIT"
	PhaseNATHolePrepare Phase = "NAT_HOLE_PREPARE"
	PhasePunching       Phase = "PUNCHING"
	PhaseQUICHandshake  Phase = "QUIC_HANDSHAKE"
	PhaseP2PReady       Phase = "P2P_READY"
	PhaseRelayConnect   Phase = "RELAY_CONNECT"
	PhaseRelayReady     Phase = "RELAY_READY"
	PhaseRecovering     Phase = "RECOVERING"
	PhaseClosed         Phase = "CLOSED"
)

type Machine struct {
	mu             sync.RWMutex
	phase          Phase
	generation     atomic.Uint64
	transportEpoch atomic.Uint64
}

func NewMachine() *Machine {
	return &Machine{phase: PhaseInit}
}

func (m *Machine) BeginSession() uint64 {
	m.mu.Lock()
	m.transportEpoch.Store(0)
	m.phase = PhaseInit
	m.mu.Unlock()
	return m.generation.Add(1)
}

func (m *Machine) BeginTransport(phase Phase) (uint64, uint64) {
	m.mu.Lock()
	m.phase = phase
	m.mu.Unlock()
	return m.generation.Load(), m.transportEpoch.Add(1)
}

func (m *Machine) SetPhase(phase Phase) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.phase = phase
}

func (m *Machine) Snapshot() (phase Phase, generation, transportEpoch uint64) {
	m.mu.RLock()
	phase = m.phase
	m.mu.RUnlock()
	return phase, m.generation.Load(), m.transportEpoch.Load()
}

func (m *Machine) IsCurrent(generation, transportEpoch uint64) bool {
	return generation == m.generation.Load() && transportEpoch == m.transportEpoch.Load()
}
