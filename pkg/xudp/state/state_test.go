package state

import (
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
)

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

	gotEpoch, ok := m.BeginTransport(gen, PhaseNATHolePrepare)
	if !ok || gotEpoch != 1 {
		t.Fatalf("BeginTransport() = (%d, %t), want (1, true)", gotEpoch, ok)
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

func TestMachineTransportEpochInvalidatesPreviousTransport(t *testing.T) {
	t.Parallel()

	m := NewMachine()
	generation := m.BeginSession()
	oldEpoch, oldOK := m.BeginTransport(generation, PhaseRelayReady)
	newEpoch, newOK := m.BeginTransport(generation, PhaseP2PReady)

	if !oldOK || !newOK {
		t.Fatalf("transport begins = (%t, %t), want true", oldOK, newOK)
	}
	if oldEpoch == newEpoch {
		t.Fatalf("transport epoch did not advance: old=%d new=%d", oldEpoch, newEpoch)
	}
	if m.IsCurrent(generation, oldEpoch) {
		t.Fatal("previous transport is still current after epoch switch")
	}
	if !m.IsCurrent(generation, newEpoch) {
		t.Fatal("new transport is not current")
	}
	if phase, gotGeneration, gotEpoch := m.Snapshot(); phase != PhaseP2PReady || gotGeneration != generation || gotEpoch != newEpoch {
		t.Fatalf("snapshot = (%s, %d, %d), want (%s, %d, %d)",
			phase, gotGeneration, gotEpoch, PhaseP2PReady, generation, newEpoch)
	}
}

func TestMachineRejectsStaleTransportGeneration(t *testing.T) {
	t.Parallel()

	m := NewMachine()
	oldGeneration := m.BeginSession()
	newGeneration := m.BeginSession()
	if oldGeneration == newGeneration {
		t.Fatal("session generation did not advance")
	}

	epoch, ok := m.BeginTransport(oldGeneration, PhaseP2PReady)
	if ok || epoch != 0 {
		t.Fatalf("stale BeginTransport() = (%d, %t), want (0, false)", epoch, ok)
	}
	phase, generation, currentEpoch := m.Snapshot()
	if phase != PhaseInit || generation != newGeneration || currentEpoch != 0 {
		t.Fatalf("snapshot after stale transport = (%s, %d, %d)", phase, generation, currentEpoch)
	}
}

func TestMachineSnapshotIsConsistentDuringConcurrentTransitions(t *testing.T) {
	m := NewMachine()
	const (
		transitionCount = 100_000
		readerCount     = 4
	)

	start := make(chan struct{})
	var wg sync.WaitGroup
	var inconsistent atomic.Bool

	wg.Add(1)
	go func() {
		defer wg.Done()
		<-start
		for i := 0; i < transitionCount; i++ {
			generation := m.BeginSession()
			phase := PhaseNATHolePrepare
			if generation%2 == 0 {
				phase = PhaseP2PReady
			}
			if _, ok := m.BeginTransport(generation, phase); !ok {
				inconsistent.Store(true)
				return
			}
			runtime.Gosched()
		}
	}()

	for i := 0; i < readerCount; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			for j := 0; j < transitionCount; j++ {
				phase, generation, transportEpoch := m.Snapshot()
				valid := (phase == PhaseInit && transportEpoch == 0) ||
					(phase == PhaseNATHolePrepare && generation%2 == 1 && transportEpoch != 0) ||
					(phase == PhaseP2PReady && generation%2 == 0 && transportEpoch != 0)
				if !valid {
					inconsistent.Store(true)
					return
				}
				runtime.Gosched()
			}
		}()
	}

	close(start)
	wg.Wait()
	if inconsistent.Load() {
		t.Fatal("Snapshot() returned an inconsistent state")
	}
}
