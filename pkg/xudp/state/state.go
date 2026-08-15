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
	generation := m.generation.Add(1)
	m.mu.Unlock()
	return generation
}

// BeginTransport starts a transport only when generation is the current
// session generation. Async dialers must provide their session generation so a
// late result from an older session cannot replace the current transport.
func (m *Machine) BeginTransport(generation uint64, phase Phase) (uint64, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if generation != m.generation.Load() {
		return 0, false
	}
	m.phase = phase
	return m.transportEpoch.Add(1), true
}

func (m *Machine) SetPhase(phase Phase) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.phase = phase
}

// SetPhaseForGeneration changes the phase only for the current session.
func (m *Machine) SetPhaseForGeneration(generation uint64, phase Phase) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if generation != m.generation.Load() {
		return false
	}
	m.phase = phase
	return true
}

// SetPhaseForTransport changes the phase only while the identified transport
// remains current. This is used when a failed recovery probe must leave the
// relay data plane authoritative.
func (m *Machine) SetPhaseForTransport(generation, transportEpoch uint64, phase Phase) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if generation != m.generation.Load() || transportEpoch != m.transportEpoch.Load() {
		return false
	}
	m.phase = phase
	return true
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
