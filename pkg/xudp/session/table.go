// XUDP extension: session table for P2P UDP session management.

package session

import (
	"sync"
	"time"
)

type State int

const (
	StateInit      State = iota // registered, waiting for hole punch
	StatePunching               // hole punch in progress
	StateConnected              // P2P established
	StateTimeout                // session expired
)

func (s State) String() string {
	switch s {
	case StateInit:
		return "INIT"
	case StatePunching:
		return "PUNCHING"
	case StateConnected:
		return "CONNECTED"
	case StateTimeout:
		return "TIMEOUT"
	default:
		return "UNKNOWN"
	}
}

// Entry represents a single UDP session.
type Entry struct {
	SessionID  string
	ClientAddr string // frpc that registered the proxy
	PeerAddr   string // frpc visitor
	LastActive time.Time
	State      State

	mu sync.Mutex
}

func (e *Entry) IsExpired(timeout time.Duration) bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return time.Since(e.LastActive) > timeout
}

// Table is a thread-safe session table.
type Table struct {
	mu       sync.RWMutex
	sessions map[string]*Entry
}

func NewTable() *Table {
	return &Table{
		sessions: make(map[string]*Entry),
	}
}

func (t *Table) Add(sid, clientAddr string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.sessions[sid] = &Entry{
		SessionID:  sid,
		ClientAddr: clientAddr,
		LastActive: time.Now(),
		State:      StateInit,
	}
}

func (t *Table) Get(sid string) (*Entry, bool) {
	t.mu.RLock()
	defer t.mu.RUnlock()
	e, ok := t.sessions[sid]
	return e, ok
}

func (t *Table) Update(sid string, state State) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	e, ok := t.sessions[sid]
	if !ok {
		return false
	}
	e.mu.Lock()
	e.State = state
	e.LastActive = time.Now()
	e.mu.Unlock()
	return true
}

func (t *Table) Delete(sid string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.sessions, sid)
}

func (t *Table) Cleanup(timeout time.Duration) {
	t.mu.Lock()
	defer t.mu.Unlock()
	for sid, e := range t.sessions {
		if e.IsExpired(timeout) {
			delete(t.sessions, sid)
		}
	}
}

// StartCleanup runs a periodic cleanup goroutine until stopCh is closed.
func (t *Table) StartCleanup(interval, timeout time.Duration, stopCh <-chan struct{}) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			t.Cleanup(timeout)
		case <-stopCh:
			return
		}
	}
}
