// XUDP extension: explicit P2P / relay state machine.

package state

import "sync"

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
	generation     uint64
	transportEpoch uint64
}

func NewMachine() *Machine {
	return &Machine{phase: PhaseInit}
}

func (m *Machine) BeginSession() uint64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.generation++
	m.transportEpoch = 0
	m.phase = PhaseInit
	return m.generation
}

func (m *Machine) BeginTransport(phase Phase) (uint64, uint64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.transportEpoch++
	m.phase = phase
	return m.generation, m.transportEpoch
}

func (m *Machine) SetPhase(phase Phase) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.phase = phase
}

func (m *Machine) Snapshot() (phase Phase, generation, transportEpoch uint64) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.phase, m.generation, m.transportEpoch
}

func (m *Machine) IsCurrent(generation, transportEpoch uint64) bool {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return generation == m.generation && transportEpoch == m.transportEpoch
}
