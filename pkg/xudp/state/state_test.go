package state

import "testing"

func TestMachineTransitions(t *testing.T) {
	t.Parallel()

	m := NewMachine()
	phase, generation, epoch := m.Snapshot()
	if phase != PhaseInit || generation != 0 || epoch != 0 {
		t.Fatalf("initial snapshot = (%s, %d, %d)", phase, generation, epoch)
	}

	gen := m.BeginSession()
	if gen != 1 {
		t.Fatalf("BeginSession() = %d, want 1", gen)
	}

	gotGen, gotEpoch := m.BeginTransport(PhaseNATHolePrepare)
	if gotGen != gen || gotEpoch != 1 {
		t.Fatalf("BeginTransport() = (%d, %d), want (1, 1)", gotGen, gotEpoch)
	}
	if !m.IsCurrent(gen, gotEpoch) {
		t.Fatal("IsCurrent() = false for current transport")
	}

	m.SetPhase(PhaseP2PReady)
	if phase, _, _ := m.Snapshot(); phase != PhaseP2PReady {
		t.Fatalf("phase = %s, want P2P_READY", phase)
	}

	gen2 := m.BeginSession()
	if gen2 != 2 {
		t.Fatalf("second BeginSession() = %d, want 2", gen2)
	}
	if m.IsCurrent(gen, gotEpoch) {
		t.Fatal("old transport still considered current after new session")
	}
}
