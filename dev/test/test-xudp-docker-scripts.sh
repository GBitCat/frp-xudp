#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

# These are internal lifecycle values, never caller-supplied configuration.
# Clear inherited state before any EXIT/signal trap can observe it.  Keep
# lock_root unset until the normal lock-test setup below has established and
# checked the exact current-UID path; do not use an early default path.
CURRENT_UID_LOCK_SNAPSHOT=
unset lock_root

# Script-level checks only. Every Docker, timeout, sleep, mktemp, rm and UDP
# operation used by the target scripts is replaced or tightly scoped here.

ISOLATED_MODE=0
if [[ ${1:-} == --isolated ]]; then
  ISOLATED_MODE=1
  shift
elif [[ -n ${1:-} ]]; then
  printf 'unknown test-suite argument: %s\n' "$1" >&2
  exit 2
fi

require_command() {
  local target=$1 name=$2 path rc
  if path=$(command -v "$name" 2>/dev/null); then
    if [[ -n "$path" ]]; then
      printf -v "$target" '%s' "$path"
      return 0
    fi
    rc=1
  else
    rc=$?
  fi
  printf 'xudp-init-missing-command command=%s\n' "$name" >&2
  return "$rc"
}

epoch_ms_from_realtime() {
  local epoch_realtime=${1-} epoch_seconds epoch_ms_digits epoch_ms
  if [[ ! $epoch_realtime =~ ^[0-9]{10,}\.[0-9]{6}$ ]]; then
    printf 'xudp-init-assertion-failed reason=epoch_realtime_invalid\n' >&2
    return 1
  fi
  epoch_seconds=${epoch_realtime%%.*}
  epoch_ms_digits=${epoch_realtime//./}
  # Take the seconds field plus its first three fractional digits. This is
  # the first 13 digits for current epochs and remains valid if the seconds
  # field gains another digit in the future.
  epoch_ms=${epoch_ms_digits:0:${#epoch_seconds}+3}
  if [[ ! $epoch_ms =~ ^[0-9]{13,}$ ]]; then
    printf 'xudp-init-assertion-failed reason=epoch_ms_invalid\n' >&2
    return 1
  fi
  printf '%s\n' "$epoch_ms"
}

epoch_ms_from_bash() {
  local epoch_realtime=${EPOCHREALTIME-}
  epoch_ms_from_realtime "$epoch_realtime"
}

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
RECOVERY="$ROOT/dev/test/run-xudp-recovery-docker.sh"
PMTUD="$ROOT/dev/test/run-xudp-pmtud-docker.sh"
SUMMARY="$ROOT/dev/test/xudp-release-summary.sh"
RECOVERY_RC_TIMEOUT=124
if require_command REAL_MKTEMP mktemp; then :; else init_rc=$?; exit "$init_rc"; fi
if require_command REAL_RM rm; then :; else init_rc=$?; exit "$init_rc"; fi
if require_command REAL_RMDIR rmdir; then :; else init_rc=$?; exit "$init_rc"; fi
if require_command REAL_STAT stat; then :; else init_rc=$?; exit "$init_rc"; fi
if require_command REAL_PS ps; then :; else init_rc=$?; exit "$init_rc"; fi
if require_command REAL_TR tr; then :; else init_rc=$?; exit "$init_rc"; fi
TEST_DIR=$("$REAL_MKTEMP" -d /tmp/frp-xudp-script-test.XXXXXX)
FAKE_BIN="$TEST_DIR/bin"
FAKE_STATE="$TEST_DIR/state"
DOCKER_LOG="$TEST_DIR/docker.log"
TIMEOUT_LOG="$TEST_DIR/timeout.log"
RM_LOG="$TEST_DIR/rm.log"
FAKE_BUILD_LOG="$TEST_DIR/build.log"
JSON_HELPER="$ROOT/dev/test/xudp-json-validate.go"
JSON_VALIDATOR="$TEST_DIR/json-validator"
mkdir -p -- "$FAKE_BIN" "$FAKE_STATE"
: >"$DOCKER_LOG"
: >"$TIMEOUT_LOG"
: >"$RM_LOG"
: >"$TEST_DIR/rmdir.log"
: >"$FAKE_BUILD_LOG"

# The process-group test below intentionally creates a real flock holder and
# descendants.  Keep ownership of every PID/PGID it creates so an interrupted
# test cannot race the EXIT trap while those processes are still creating
# fixture files.  Only PIDs and groups registered by this test are ever
# signalled; the test shell's own process group is explicitly excluded.
TEST_SHELL_PGID=$($REAL_PS -o pgid= -p "$$" | $REAL_TR -d '[:space:]')
TEST_CALLER_PGID=$($REAL_PS -o pgid= -p "$PPID" 2>/dev/null | $REAL_TR -d '[:space:]' || true)
TEST_PIDS=()
TEST_CHILD_PIDS=()
TEST_PGIDS=()
TEST_PROTECTED_PIDS=()
declare -Ag TEST_CHILD_STATUS=()
declare -Ag TEST_PID_STARTTIME=()
declare -Ag TEST_PID_PGID=()
TEST_CLEANUP_RUNNING=0
TEST_FINAL_FAILURE=0
TEST_WAIT_FIFO="$TEST_DIR/process-cleanup.fifo"
mkfifo -m 600 -- "$TEST_WAIT_FIFO"
exec {TEST_WAIT_FD}<>"$TEST_WAIT_FIFO"

# Serialize this suite independently of the production recovery lock. The
# suite lock is never used to authorize mutation of the production lock root.
SUITE_LOCK_DIR=/tmp/frp-xudp-suite-lock-uid-$(id -u)
if [[ ! -e "$SUITE_LOCK_DIR" && ! -L "$SUITE_LOCK_DIR" ]]; then
  (umask 077; mkdir -- "$SUITE_LOCK_DIR")
fi
[[ ! -L "$SUITE_LOCK_DIR" && -d "$SUITE_LOCK_DIR" ]] || {
  printf 'suite lock path is not a non-symlink directory: %s\n' "$SUITE_LOCK_DIR" >&2
  exit 75
}
if suite_stat=$(LC_ALL=C "$REAL_STAT" -Lc '%F %u %a' -- "$SUITE_LOCK_DIR"); then :; else
  suite_stat_rc=$?
  printf 'xudp-init-suite-stat-error rc=%s\n' "$suite_stat_rc" >&2
  exit "$suite_stat_rc"
fi
suite_kind= suite_owner= suite_mode= suite_extra=
if read -r suite_kind suite_owner suite_mode suite_extra <<<"$suite_stat"; then :; else
  printf 'xudp-init-suite-stat-read-error\n' >&2
  exit 75
fi
if [[ "$suite_kind" =~ ^[[:alpha:]][[:alpha:]_[:space:]]*$ &&
  "$suite_owner" =~ ^[0-9]+$ && "$suite_mode" =~ ^[0-7]{3,4}$ &&
  -z "$suite_extra" && "$suite_kind" == directory &&
  "$suite_owner" == "$(id -u)" && "$suite_mode" == 700 ]]; then :; else
  printf 'suite lock directory must be uid-owned mode 0700: %s\n' "$SUITE_LOCK_DIR" >&2
  exit 75
fi
exec {SUITE_LOCK_FD}<"$SUITE_LOCK_DIR"
if ! /usr/bin/flock -E 75 -n "$SUITE_LOCK_FD"; then
  printf 'another xudp script suite already owns: %s\n' "$SUITE_LOCK_DIR" >&2
  exit 75
fi

test_pid_protected() {
  local pid=$1 protected
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != 1 && "$pid" != "$$" && "$pid" != "$PPID" ]] || return 0
  for protected in "${TEST_PROTECTED_PIDS[@]}"; do
    [[ "$pid" == "$protected" ]] && return 0
  done
  return 1
}

protect_test_pid() {
  local pid=$1
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != 1 ]] || return 1
  TEST_PROTECTED_PIDS+=("$pid")
}

register_test_pid() {
  local pid=$1 starttime pgid state
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != 1 ]] || return 1
  test_pid_protected "$pid" && return 1
  pgid=$($REAL_PS -o pgid= -p "$pid" 2>/dev/null | $REAL_TR -d '[:space:]' || true)
  state=$($REAL_PS -o stat= -p "$pid" 2>/dev/null | $REAL_TR -d '[:space:]' || true)
  [[ "$pgid" =~ ^[1-9][0-9]*$ && "$pgid" != 1 && "$pgid" != "$TEST_SHELL_PGID" &&
    "$pgid" != "$TEST_CALLER_PGID" && "$state" != Z* ]] || return 1
  starttime=$(process_starttime "$pid" 2>/dev/null || true)
  [[ "$starttime" =~ ^[0-9]+$ ]] || return 1
  # Validate every identity field before mutating any registry.  A short-lived
  # process or a protected/reused PID must leave no partial registration.
  TEST_PIDS+=("$pid")
  TEST_PID_STARTTIME["$pid"]=$starttime
  TEST_PID_PGID["$pid"]=$pgid
}

register_test_child() {
  local pid=$1
  # A short-lived or otherwise unregistrable process must never enter the
  # direct-child wait set.  Some fixture setup intentionally runs with
  # errexit disabled, so an implicit set -e dependency here would append an
  # unregistered PID with no possible TEST_CHILD_STATUS record.
  register_test_pid "$pid" || return $?
  TEST_CHILD_PIDS+=("$pid")
}

test_child_registration_terminal() {
  local pid=$1 pgid state
  test_pid_protected "$pid" && return 0
  pgid=$($REAL_PS -o pgid= -p "$pid" 2>/dev/null | $REAL_TR -d '[:space:]' || true)
  state=$($REAL_PS -o stat= -p "$pid" 2>/dev/null | $REAL_TR -d '[:space:]' || true)
  # An absent PID, zombie, protected PID, or caller-owned group can never
  # become a safe direct-child registration target.  Treat incomplete ps
  # identity as terminal as well: this helper must fail closed.
  [[ -n "$pgid" && -n "$state" && "$state" != Z* &&
    "$pgid" != "$TEST_SHELL_PGID" && "$pgid" != "$TEST_CALLER_PGID" ]] ||
    return 0
  return 1
}

register_test_child_bounded() {
  local pid=$1 label=$2 attempt rc reason child_count pid_count existing
  local saved_starttime saved_pgid saved_starttime_present saved_pgid_present
  local -a saved_test_pids=() saved_test_child_pids=() saved_test_pgids=()

  [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != 1 && -n "$label" ]] || {
    printf 'bounded child registration failed label=%s pid=%s attempts=0 rc=1 reason=invalid-input\n' \
      "$label" "$pid" >&2
    report_test_pid_identity "$pid"
    return 1
  }

  # An already complete registration is idempotent.  Any partial or duplicate
  # state is an invariant failure, not a reason to append another kill target.
  child_count=0
  for existing in "${TEST_CHILD_PIDS[@]}"; do
    if [[ "$existing" == "$pid" ]]; then
      ((child_count += 1))
    fi
  done
  pid_count=0
  for existing in "${TEST_PIDS[@]}"; do
    if [[ "$existing" == "$pid" ]]; then
      ((pid_count += 1))
    fi
  done
  if (( child_count == 1 && pid_count == 1 )) &&
    [[ ${TEST_PID_STARTTIME[$pid]+present} == present &&
      ${TEST_PID_PGID[$pid]+present} == present ]]; then
    return 0
  fi
  if (( child_count != 0 || pid_count != 0 )) ||
    [[ ${TEST_PID_STARTTIME[$pid]+present} == present ||
      ${TEST_PID_PGID[$pid]+present} == present ]]; then
    printf 'bounded child registration failed label=%s pid=%s attempts=0 rc=2 reason=preexisting-registry-invariant\n' \
      "$label" "$pid" >&2
    report_test_pid_identity "$pid"
    return 2
  fi

  for ((attempt = 1; attempt <= 300; attempt++)); do
    saved_test_pids=("${TEST_PIDS[@]}")
    saved_test_child_pids=("${TEST_CHILD_PIDS[@]}")
    saved_test_pgids=("${TEST_PGIDS[@]}")
    saved_starttime=${TEST_PID_STARTTIME[$pid]-}
    saved_pgid=${TEST_PID_PGID[$pid]-}
    saved_starttime_present=0
    saved_pgid_present=0
    [[ ${TEST_PID_STARTTIME[$pid]+present} == present ]] && saved_starttime_present=1
    [[ ${TEST_PID_PGID[$pid]+present} == present ]] && saved_pgid_present=1

    if register_test_child "$pid"; then
      child_count=0
      for existing in "${TEST_CHILD_PIDS[@]}"; do
        if [[ "$existing" == "$pid" ]]; then
          ((child_count += 1))
        fi
      done
      pid_count=0
      for existing in "${TEST_PIDS[@]}"; do
        if [[ "$existing" == "$pid" ]]; then
          ((pid_count += 1))
        fi
      done
      if (( child_count == 1 && pid_count == 1 )) &&
        [[ ${TEST_PID_STARTTIME[$pid]+present} == present &&
          ${TEST_PID_PGID[$pid]+present} == present ]]; then
        return 0
      fi
      reason=post-success-registry-invariant
      rc=2
      TEST_PIDS=("${saved_test_pids[@]}")
      TEST_CHILD_PIDS=("${saved_test_child_pids[@]}")
      TEST_PGIDS=("${saved_test_pgids[@]}")
      if (( saved_starttime_present )); then
        TEST_PID_STARTTIME["$pid"]=$saved_starttime
      else
        unset 'TEST_PID_STARTTIME[$pid]'
      fi
      if (( saved_pgid_present )); then
        TEST_PID_PGID["$pid"]=$saved_pgid
      else
        unset 'TEST_PID_PGID[$pid]'
      fi
      printf 'bounded child registration failed label=%s pid=%s attempts=%s rc=%s reason=%s\n' \
        "$label" "$pid" "$attempt" "$rc" "$reason" >&2
      report_test_pid_identity "$pid"
      return 2
    else
      rc=$?
      reason=registration-not-ready
    fi

    # register_test_child is required to be atomic.  Keep this rollback as a
    # second boundary so a hostile/test double cannot leave any kill registry
    # polluted while a retry is pending.
    TEST_PIDS=("${saved_test_pids[@]}")
    TEST_CHILD_PIDS=("${saved_test_child_pids[@]}")
    TEST_PGIDS=("${saved_test_pgids[@]}")
    if (( saved_starttime_present )); then
      TEST_PID_STARTTIME["$pid"]=$saved_starttime
    else
      unset 'TEST_PID_STARTTIME[$pid]'
    fi
    if (( saved_pgid_present )); then
      TEST_PID_PGID["$pid"]=$saved_pgid
    else
      unset 'TEST_PID_PGID[$pid]'
    fi

    if test_child_registration_terminal "$pid"; then
      printf 'bounded child registration failed label=%s pid=%s attempts=%s rc=%s reason=%s\n' \
        "$label" "$pid" "$attempt" "$rc" terminal-identity >&2
      report_test_pid_identity "$pid"
      return 1
    fi
    test_cleanup_tick
  done

  printf 'bounded child registration failed label=%s pid=%s attempts=300 rc=%s reason=retry-limit\n' \
    "$label" "$pid" "${rc:-1}" >&2
  report_test_pid_identity "$pid"
  return 1
}

register_test_process_bounded() {
  local pid=$1 label=$2 attempt rc reason child_count pid_count pgid_count existing
  local expected_pgid saved_starttime saved_pgid saved_starttime_present saved_pgid_present
  local -a saved_test_pids=() saved_test_child_pids=() saved_test_pgids=()

  [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != 1 && -n "$label" ]] || {
    printf 'bounded process registration failed label=%s pid=%s attempts=0 rc=1 reason=invalid-input\n' \
      "$label" "$pid" >&2
    report_test_pid_identity "$pid"
    return 1
  }

  child_count=0
  for existing in "${TEST_CHILD_PIDS[@]}"; do
    if [[ "$existing" == "$pid" ]]; then
      ((child_count += 1))
    fi
  done
  pid_count=0
  for existing in "${TEST_PIDS[@]}"; do
    if [[ "$existing" == "$pid" ]]; then
      ((pid_count += 1))
    fi
  done
  expected_pgid=${TEST_PID_PGID[$pid]-}
  pgid_count=0
  if [[ "$expected_pgid" =~ ^[1-9][0-9]*$ && "$expected_pgid" != 1 ]]; then
    for existing in "${TEST_PGIDS[@]}"; do
      if [[ "$existing" == "$expected_pgid" ]]; then
        ((pgid_count += 1))
      fi
    done
  fi
  if (( child_count == 1 && pid_count == 1 && pgid_count == 1 )) &&
    [[ ${TEST_PID_STARTTIME[$pid]+present} == present &&
      ${TEST_PID_PGID[$pid]+present} == present ]]; then
    return 0
  fi
  if (( child_count != 0 || pid_count != 0 || pgid_count != 0 )) ||
    [[ ${TEST_PID_STARTTIME[$pid]+present} == present ||
      ${TEST_PID_PGID[$pid]+present} == present ]]; then
    printf 'bounded process registration failed label=%s pid=%s attempts=0 rc=2 reason=preexisting-registry-invariant\n' \
      "$label" "$pid" >&2
    report_test_pid_identity "$pid"
    return 2
  fi

  for ((attempt = 1; attempt <= 300; attempt++)); do
    saved_test_pids=("${TEST_PIDS[@]}")
    saved_test_child_pids=("${TEST_CHILD_PIDS[@]}")
    saved_test_pgids=("${TEST_PGIDS[@]}")
    saved_starttime=${TEST_PID_STARTTIME[$pid]-}
    saved_pgid=${TEST_PID_PGID[$pid]-}
    saved_starttime_present=0
    saved_pgid_present=0
    [[ ${TEST_PID_STARTTIME[$pid]+present} == present ]] && saved_starttime_present=1
    [[ ${TEST_PID_PGID[$pid]+present} == present ]] && saved_pgid_present=1

    if register_test_process "$pid"; then
      TEST_CHILD_PIDS+=("$pid")
      child_count=0
      for existing in "${TEST_CHILD_PIDS[@]}"; do
        if [[ "$existing" == "$pid" ]]; then
          ((child_count += 1))
        fi
      done
      pid_count=0
      for existing in "${TEST_PIDS[@]}"; do
        if [[ "$existing" == "$pid" ]]; then
          ((pid_count += 1))
        fi
      done
      expected_pgid=${TEST_PID_PGID[$pid]-}
      pgid_count=0
      for existing in "${TEST_PGIDS[@]}"; do
        if [[ "$existing" == "$expected_pgid" ]]; then
          ((pgid_count += 1))
        fi
      done
      if (( child_count == 1 && pid_count == 1 && pgid_count == 1 )) &&
        [[ ${TEST_PID_STARTTIME[$pid]+present} == present &&
          ${TEST_PID_PGID[$pid]+present} == present ]]; then
        return 0
      fi
      rc=2
      reason=post-success-registry-invariant
    else
      rc=$?
      reason=registration-not-ready
    fi

    TEST_PIDS=("${saved_test_pids[@]}")
    TEST_CHILD_PIDS=("${saved_test_child_pids[@]}")
    TEST_PGIDS=("${saved_test_pgids[@]}")
    if (( saved_starttime_present )); then
      TEST_PID_STARTTIME["$pid"]=$saved_starttime
    else
      unset 'TEST_PID_STARTTIME[$pid]'
    fi
    if (( saved_pgid_present )); then
      TEST_PID_PGID["$pid"]=$saved_pgid
    else
      unset 'TEST_PID_PGID[$pid]'
    fi

    if (( rc == 2 )); then
      printf 'bounded process registration failed label=%s pid=%s attempts=%s rc=%s reason=%s\n' \
        "$label" "$pid" "$attempt" "$rc" "$reason" >&2
      report_test_pid_identity "$pid"
      return 2
    fi
    if test_child_registration_terminal "$pid"; then
      printf 'bounded process registration failed label=%s pid=%s attempts=%s rc=%s reason=terminal-identity\n' \
        "$label" "$pid" "$attempt" "$rc" >&2
      report_test_pid_identity "$pid"
      return 1
    fi
    test_cleanup_tick
  done

  printf 'bounded process registration failed label=%s pid=%s attempts=300 rc=%s reason=retry-limit\n' \
    "$label" "$pid" "${rc:-1}" >&2
  report_test_pid_identity "$pid"
  return 1
}

register_test_pgid_for_pid() {
  local pid=$1 pgid existing_pgid
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  pgid=$($REAL_PS -o pgid= -p "$pid" 2>/dev/null | $REAL_TR -d '[:space:]' || true)
  [[ "$pgid" =~ ^[1-9][0-9]*$ && "$pgid" != 1 && "$pgid" != "$TEST_SHELL_PGID" &&
    "$pgid" != "$TEST_CALLER_PGID" ]] || return 1
  for existing_pgid in "${TEST_PGIDS[@]}"; do
    [[ "$existing_pgid" == "$pgid" ]] && return 0
  done
  TEST_PGIDS+=("$pgid")
}

register_test_process() {
  local pid=$1 old_pid_count old_pgid_count
  old_pid_count=${#TEST_PIDS[@]}
  old_pgid_count=${#TEST_PGIDS[@]}
  register_test_pid "$pid" || return $?
  if register_test_pgid_for_pid "$pid"; then
    return 0
  fi
  # Roll back both registries if PGID identity cannot be established.  This
  # keeps a failed registration from becoming a half-registered kill target.
  TEST_PIDS=("${TEST_PIDS[@]:0:old_pid_count}")
  unset 'TEST_PID_STARTTIME[$pid]' 'TEST_PID_PGID[$pid]'
  TEST_PGIDS=("${TEST_PGIDS[@]:0:old_pgid_count}")
  return 1
}

report_test_pid_identity() {
  local pid=$1 expected current expected_pgid current_pgid state
  expected=${TEST_PID_STARTTIME[$pid]-<missing>}
  current=$(process_starttime "$pid" 2>/dev/null || true)
  expected_pgid=${TEST_PID_PGID[$pid]-<missing>}
  current_pgid=$($REAL_PS -o pgid= -p "$pid" 2>/dev/null |
    $REAL_TR -d '[:space:]' || true)
  state=$($REAL_PS -o stat= -p "$pid" 2>/dev/null |
    $REAL_TR -d '[:space:]' || true)
  printf 'pid_identity pid=%s expected_starttime=%s current_starttime=%s expected_pgid=%s current_pgid=%s state=%s\n' \
    "$pid" "$expected" "${current:-<missing>}" "$expected_pgid" \
    "${current_pgid:-<missing>}" "${state:-<missing>}" >&2
}

int_fixture_diagnostics() {
  local pid file
  printf 'INT fixture diagnostics:\n' >&2
  for pid in "${int_sentinel-}" "${int_outer-}" "${int_sender-}" \
    "${int_watchdog_pid-}"; do
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != 1 ]] || continue
    report_test_pid_identity "$pid"
  done
  for file in "${int_sentinel_ready-}" "${int_outer_pid_file-}" \
    "${int_outer_pgid_file-}" "${int_outer_starttime_file-}" \
    "${int_signaler_marker-}" "${int_signaler_failed-}" \
    "${int_signaler_stage-}" \
    "${int_signaler_diagnostic-}" "${int_watchdog_timeout_marker-}" \
    "${int_watchdog_term_sent-}" "${int_watchdog_kill_sent-}" \
    "${int_watchdog_stage-}" \
    "${int_supervisor_ready-}" "${int_signaler_pid_file-}" \
    "${int_signaler_pgid_file-}" "${int_signaler_starttime_file-}" \
    "${int_watchdog_pid_file-}" "${int_watchdog_pgid_file-}" \
    "${int_watchdog_starttime_file-}"; do
    [[ -n "$file" ]] || continue
    printf 'file=%s: ' "$file" >&2
    if [[ -e "$file" ]]; then
      sed -n '1,80p' -- "$file" >&2 || true
    else
      printf 'missing\n' >&2
    fi
  done
  if [[ -n "${int_outer_log-}" && -e "$int_outer_log" ]]; then
    sed -n '1,240p' -- "$int_outer_log" >&2 || true
  fi
}

int_checked() {
  local label=$1 rc
  shift
  if "$@"; then
    return 0
  else
    rc=$?
  fi
  printf 'INT fixture command failed label=%s rc=%s\n' "$label" "$rc" >&2
  int_fixture_diagnostics
  return "$rc"
}

int_marker_phase_allows_signal() {
  local phase=${1-}
  case "$phase" in
    # These are the non-terminal states in which A still owns the same
    # authenticated supervisor and can safely queue/forward INT.  The
    # business-starting state is included deliberately: A queues the signal
    # until the inner supervisor can process it, and the marker already binds
    # that supervisor to the held recovery lock.
    supervisor-ready|business-starting|business-ready|body-running) return 0 ;;
    *) return 1 ;;
  esac
}

int_release_phase_rank() {
  case "${1-}" in
    # These are the only phases in which the same authenticated run may
    # release the signaler.  Terminal phases are deliberately not ranked:
    # they must never become release candidates, even if their identities
    # happen to remain in the marker for a short time.
    supervisor-ready) printf '1\n' ;;
    business-starting) printf '2\n' ;;
    business-ready) printf '3\n' ;;
    body-running) printf '4\n' ;;
    *) return 1 ;;
  esac
}

# Release is permitted only after a monotonic, same-run marker transition has
# exposed a live business process group.  Early phases are wait-only; failure
# terminal phases are never release-safe.
int_release_marker_transition_valid() {
  local previous_rank=$1 phase=$2 lock_inode=$3 current_lock_inode=$4
  local supervisor_pid=$5 supervisor_pgid=$6 supervisor_starttime=$7
  local expected_supervisor_pid=$8 expected_supervisor_pgid=$9
  local expected_supervisor_starttime=${10} business_pid=${11}
  local business_pgid=${12} business_starttime=${13}
  local expected_business_pid=${14:-0} expected_business_pgid=${15:-0}
  local expected_business_starttime=${16:-0} rank
  rank=$(int_release_phase_rank "$phase") || return 1
  (( rank >= previous_rank )) || return 1
  [[ "$lock_inode" == "$current_lock_inode" &&
    "$supervisor_pid" == "$expected_supervisor_pid" &&
    "$supervisor_pgid" == "$expected_supervisor_pgid" &&
    "$supervisor_starttime" == "$expected_supervisor_starttime" ]] || return 1
  case "$phase" in
    supervisor-ready)
      [[ "$business_pid" == 0 && "$business_pgid" == 0 &&
        "$business_starttime" == 0 ]] ;;
    business-starting)
      [[ "$business_pid" =~ ^[1-9][0-9]*$ && "$business_pgid" == 0 &&
        "$business_starttime" =~ ^[1-9][0-9]*$ ]] ;;
    business-ready|body-running)
      [[ "$business_pid" =~ ^[1-9][0-9]*$ &&
        "$business_pgid" =~ ^[1-9][0-9]*$ &&
        "$business_starttime" =~ ^[1-9][0-9]*$ ]] || return 1
      if [[ "$expected_business_pid" != 0 ]]; then
        # business-starting has no PGID yet.  Bind PID/starttime there and
        # bind PGID when the first stable business phase publishes it.
        [[ "$business_pid" == "$expected_business_pid" &&
          "$business_starttime" == "$expected_business_starttime" ]] || return 1
        if [[ "$expected_business_pgid" != 0 ]]; then
          [[ "$business_pgid" == "$expected_business_pgid" ]] || return 1
        fi
      fi
      ;;
    *) return 1 ;;
  esac
}

int_release_business_identity_stable() {
  local pid=$1 expected_pgid=$2 expected_starttime=$3 first second
  local current_pgid current_starttime
  current_starttime=$(process_starttime "$pid" 2>/dev/null || true)
  current_pgid=$($REAL_PS -o pgid= -p "$pid" 2>/dev/null |
    $REAL_TR -d '[:space:]' || true)
  [[ "$current_starttime" == "$expected_starttime" &&
    "$current_pgid" == "$expected_pgid" ]] || return 1
  first="$pid:$current_pgid:$current_starttime"
  /bin/sleep 0.01
  current_starttime=$(process_starttime "$pid" 2>/dev/null || true)
  current_pgid=$($REAL_PS -o pgid= -p "$pid" 2>/dev/null |
    $REAL_TR -d '[:space:]' || true)
  second="$pid:$current_pgid:$current_starttime"
  [[ "$first" == "$second" &&
    "$current_starttime" == "$expected_starttime" &&
    "$current_pgid" == "$expected_pgid" ]]
}

wait_for_int_release_barrier() {
  local i marker=$int_supervisor_ready marker_serial marker_serial_after
  local phase lock_inode current_lock_inode supervisor_pid supervisor_pgid
  local supervisor_starttime business_pid business_pgid business_starttime
  local rank expected_business_pid=${int_release_business_pid:-0}
  local expected_business_pgid=${int_release_business_pgid:-0}
  local expected_business_starttime=${int_release_business_starttime:-0}
  local previous_rank=${int_release_initial_phase_rank:-1}
  for ((i = 0; i < 1500; i++)); do
    if [[ ! -s "$marker" || -L "$marker" ]]; then
      int_release_barrier_reason=marker-missing
      /bin/sleep 0.01
      continue
    fi
    marker_serial=$(<"$marker") || {
      int_release_barrier_reason=marker-read
      /bin/sleep 0.01
      continue
    }
    parse_authority_marker_file "$marker" || {
      int_release_barrier_reason=marker-invalid
      printf 'INT release barrier failed reason=%s\n' "$int_release_barrier_reason" >&2
      return 1
    }
    phase=$(awk -F= '$1 == "phase" { print $2; exit }' "$marker")
    lock_inode=$(awk -F= '$1 == "lock_inode" { print $2; exit }' "$marker")
    supervisor_pid=$(awk -F= '$1 == "supervisor_pid" { print $2; exit }' "$marker")
    supervisor_pgid=$(awk -F= '$1 == "supervisor_pgid" { print $2; exit }' "$marker")
    supervisor_starttime=$(awk -F= '$1 == "supervisor_starttime" { print $2; exit }' "$marker")
    business_pid=$(awk -F= '$1 == "business_pid" { print $2; exit }' "$marker")
    business_pgid=$(awk -F= '$1 == "business_pgid" { print $2; exit }' "$marker")
    business_starttime=$(awk -F= '$1 == "business_starttime" { print $2; exit }' "$marker")
    current_lock_inode=$($REAL_STAT -Lc '%d:%i' -- "$lock_root" 2>/dev/null || true)
    rank=$(int_release_phase_rank "$phase" 2>/dev/null || true)
    if [[ "$phase" == business-exited || "$phase" == body-failed ||
      "$phase" == timeout ]]; then
      int_release_barrier_reason="failed-phase:$phase"
      printf 'INT release barrier failed reason=%s\n' "$int_release_barrier_reason" >&2
      return 1
    fi
    if ! int_release_marker_transition_valid "$previous_rank" "$phase" \
      "$lock_inode" "$current_lock_inode" "$supervisor_pid" \
      "$supervisor_pgid" "$supervisor_starttime" \
      "$int_release_supervisor_pid" "$int_release_supervisor_pgid" \
      "$int_release_supervisor_starttime" "$business_pid" "$business_pgid" \
      "$business_starttime" "$expected_business_pid" "$expected_business_pgid" \
      "$expected_business_starttime"; then
      int_release_barrier_reason="identity-or-transition:$phase"
      printf 'INT release barrier failed reason=%s\n' "$int_release_barrier_reason" >&2
      return 1
    fi
    [[ "$rank" =~ ^[1-9][0-9]*$ ]] || {
      int_release_barrier_reason=phase-invalid
      printf 'INT release barrier failed reason=%s\n' "$int_release_barrier_reason" >&2
      return 1
    }
    (( rank > previous_rank )) && previous_rank=$rank
    int_marker_process_identity_valid "$supervisor_pid" \
      "$supervisor_pgid" "$supervisor_starttime" || {
      int_release_barrier_reason=supervisor-identity
      printf 'INT release barrier failed reason=%s phase=%s\n' \
        "$int_release_barrier_reason" "$phase" >&2
      return 1
    }
    case "$phase" in
      business-starting)
        if [[ "$expected_business_pid" == 0 ]]; then
          expected_business_pid=$business_pid
          expected_business_starttime=$business_starttime
        fi
        ;;
      business-ready|body-running)
        if [[ "$expected_business_pid" == 0 ]]; then
          expected_business_pid=$business_pid
          expected_business_pgid=$business_pgid
          expected_business_starttime=$business_starttime
        fi
        int_release_business_identity_stable "$business_pid" \
          "$business_pgid" "$business_starttime" || {
          int_release_barrier_reason=business-identity-unstable
          printf 'INT release barrier failed reason=%s phase=%s pid=%s pgid=%s starttime=%s\n' \
            "$int_release_barrier_reason" "$phase" "$business_pid" \
            "$business_pgid" "$business_starttime" >&2
          return 1
        }
        marker_serial_after=$(<"$marker") || {
          int_release_barrier_reason=marker-reread
          printf 'INT release barrier failed reason=%s\n' "$int_release_barrier_reason" >&2
          return 1
        }
        [[ "$marker_serial" == "$marker_serial_after" ]] || {
          int_release_barrier_reason=marker-changed
          /bin/sleep 0.01
          continue
        }
        current_lock_inode=$($REAL_STAT -Lc '%d:%i' -- "$lock_root" 2>/dev/null || true)
        [[ "$lock_inode" == "$current_lock_inode" ]] || {
          int_release_barrier_reason=lock-changed
          /bin/sleep 0.01
          continue
        }
        int_release_business_pid=$expected_business_pid
        int_release_business_pgid=$expected_business_pgid
        int_release_business_starttime=$expected_business_starttime
        int_release_observed_safe=1
        if ! int_handshake_atomic "$int_signaler_release" \
          "token=$int_signaler_token role=signaler"; then
          int_release_barrier_reason=release-write
          printf 'INT release barrier failed reason=%s\n' \
            "$int_release_barrier_reason" >&2
          return 1
        fi
        int_release_released=1
        printf 'INT release barrier observed phase=%s supervisor=%s/%s/%s business=%s/%s/%s\n' \
          "$phase" "$supervisor_pid" "$supervisor_pgid" "$supervisor_starttime" \
          "$business_pid" "$business_pgid" "$business_starttime" >&2
        return 0
        ;;
      *) : ;;
    esac
    marker_serial_after=$(<"$marker") || continue
    [[ "$marker_serial" == "$marker_serial_after" ]] || continue
    /bin/sleep 0.01
  done
  int_release_barrier_reason=${int_release_barrier_reason:-timeout}
  printf 'INT release barrier timed out reason=%s phase=%s expected_supervisor=%s/%s/%s expected_business=%s/%s/%s\n' \
    "$int_release_barrier_reason" "${phase:-missing}" \
    "$int_release_supervisor_pid" "$int_release_supervisor_pgid" \
    "$int_release_supervisor_starttime" "$expected_business_pid" \
    "$expected_business_pgid" "$expected_business_starttime" >&2
  return 1
}

int_marker_contract_fields_valid() {
  local phase=$1 lock_inode=$2 current_lock_inode=$3
  local supervisor_pid=$4 supervisor_pgid=$5 supervisor_starttime=$6
  local expected_pid=$7 expected_pgid=$8 expected_starttime=$9 lock_fd_bound=${10}
  int_marker_phase_allows_signal "$phase" || return 1
  [[ "$lock_inode" =~ ^[1-9][0-9]*:[1-9][0-9]*$ &&
    "$lock_inode" == "$current_lock_inode" &&
    "$supervisor_pid" =~ ^[1-9][0-9]*$ && "$supervisor_pid" != 1 &&
    "$supervisor_pgid" =~ ^[1-9][0-9]*$ && "$supervisor_pgid" != 1 &&
    "$supervisor_starttime" =~ ^[1-9][0-9]*$ &&
    "$supervisor_pid" == "$expected_pid" &&
    "$supervisor_pgid" == "$expected_pgid" &&
    "$supervisor_starttime" == "$expected_starttime" &&
    "$lock_fd_bound" == 1 ]]
}

int_marker_has_lock_fd() {
  local supervisor_pid=$1 fd target
  for fd in "/proc/$supervisor_pid/fd"/*; do
    target=$(readlink -- "$fd" 2>/dev/null || true)
    [[ "$target" == "$lock_root" ]] && return 0
  done
  return 1
}

int_marker_process_identity_valid() {
  local pid=$1 expected_pgid=$2 expected_starttime=$3 current_pgid state current_starttime
  current_starttime=$(process_starttime "$pid" 2>/dev/null || true)
  current_pgid=$($REAL_PS -o pgid= -p "$pid" 2>/dev/null | $REAL_TR -d '[:space:]' || true)
  state=$($REAL_PS -o stat= -p "$pid" 2>/dev/null | $REAL_TR -d '[:space:]' || true)
  [[ "$current_starttime" == "$expected_starttime" &&
    "$current_pgid" == "$expected_pgid" && "$state" != Z* ]]
}

int_foreground_identity_stable() {
  local expected_starttime=${TEST_PID_STARTTIME[$int_outer]-}
  local expected_pgid=${TEST_PID_PGID[$int_outer]-} first second
  local current_starttime current_pgid
  [[ "$int_outer" =~ ^[1-9][0-9]*$ && "$int_outer" != 1 &&
    "$expected_starttime" =~ ^[1-9][0-9]*$ &&
    "$expected_pgid" =~ ^[1-9][0-9]*$ && "$expected_pgid" != 1 ]] || return 1
  test_process_state "$int_outer" || return 1
  current_starttime=$(process_starttime "$int_outer" 2>/dev/null || true)
  current_pgid=$($REAL_PS -o pgid= -p "$int_outer" 2>/dev/null | $REAL_TR -d '[:space:]' || true)
  first="$int_outer:$current_starttime:$current_pgid"
  /bin/sleep 0.01
  test_process_state "$int_outer" || return 1
  current_starttime=$(process_starttime "$int_outer" 2>/dev/null || true)
  current_pgid=$($REAL_PS -o pgid= -p "$int_outer" 2>/dev/null | $REAL_TR -d '[:space:]' || true)
  second="$int_outer:$current_starttime:$current_pgid"
  [[ "$first" == "$second" &&
    "$current_starttime" == "$expected_starttime" &&
    "$current_pgid" == "$expected_pgid" ]]
}

wait_for_int_supervisor_ready() {
  local i marker_dir ready marker_stat dir_stat phase lock_inode current_lock_inode
  local supervisor_pid supervisor_pgid supervisor_starttime state_rc
  local marker_serial marker_serial_after
  for ((i = 0; i < 1500; i++)); do
    for marker_dir in /tmp/frp-xudp-recovery-marker.*; do
      [[ -d "$marker_dir" && ! -L "$marker_dir" ]] || continue
      [[ ${INT_MARKER_DIRS_BEFORE[$marker_dir]+present} != present ]] || continue
      dir_stat=$($REAL_STAT -Lc '%F|%u|%a' -- "$marker_dir" 2>/dev/null || true)
      [[ "$dir_stat" == "directory|$(id -u)|700" ]] || continue
      ready="$marker_dir/ready"
      [[ -s "$ready" && ! -L "$ready" ]] || continue
      marker_stat=$($REAL_STAT -Lc '%F|%u|%h|%a' -- "$ready" 2>/dev/null || true)
      [[ "$marker_stat" == "regular file|$(id -u)|1|600" ]] || continue
      if ! parse_authority_marker_file "$ready"; then
        continue
      fi
      # The marker is atomically replaced by A as phases advance.  Require a
      # stable serialized snapshot before extracting identity fields, then
      # repeat the comparison immediately before accepting it.
      marker_serial=$(<"$ready") || continue
      marker_serial_after=$(<"$ready") || continue
      [[ "$marker_serial" == "$marker_serial_after" ]] || continue
      phase=$(awk -F= '$1 == "phase" { print $2; exit }' "$ready")
      lock_inode=$(awk -F= '$1 == "lock_inode" { print $2; exit }' "$ready")
      supervisor_pid=$(awk -F= '$1 == "supervisor_pid" { print $2; exit }' "$ready")
      supervisor_pgid=$(awk -F= '$1 == "supervisor_pgid" { print $2; exit }' "$ready")
      supervisor_starttime=$(awk -F= '$1 == "supervisor_starttime" { print $2; exit }' "$ready")
      current_lock_inode=$($REAL_STAT -Lc '%d:%i' -- "$lock_root" 2>/dev/null || true)
      marker_expected_pid=$supervisor_pid
      marker_expected_pgid=$supervisor_pgid
      marker_expected_starttime=$supervisor_starttime
      if int_marker_phase_allows_signal "$phase" &&
        [[ "$supervisor_pgid" != "$TEST_SHELL_PGID" &&
          "$supervisor_pgid" != "$TEST_CALLER_PGID" ]] &&
        int_marker_process_identity_valid "$supervisor_pid" \
          "$supervisor_pgid" "$supervisor_starttime" &&
        int_marker_contract_fields_valid "$phase" "$lock_inode" \
          "$current_lock_inode" "$supervisor_pid" "$supervisor_pgid" \
          "$supervisor_starttime" "$marker_expected_pid" \
          "$marker_expected_pgid" "$marker_expected_starttime" \
          "$(if int_marker_has_lock_fd "$supervisor_pid"; then printf 1; else printf 0; fi)" &&
        int_foreground_identity_stable; then
        marker_serial_after=$(<"$ready") || continue
        [[ "$marker_serial" == "$marker_serial_after" ]] || continue
        parse_authority_marker_file "$ready" || continue
        int_supervisor_ready="$ready"
        int_release_supervisor_pid="$supervisor_pid"
        int_release_supervisor_pgid="$supervisor_pgid"
        int_release_supervisor_starttime="$supervisor_starttime"
        int_release_initial_phase_rank=$(int_release_phase_rank "$phase")
        int_release_business_pid=0
        int_release_business_pgid=0
        int_release_business_starttime=0
        return 0
      fi
    done
    state_rc=0
    test_process_state "$int_outer" || state_rc=$?
    case "$state_rc" in
      0) : ;;
      1)
        printf 'INT supervisor readiness failed: foreground process exited before marker\n' >&2
        int_fixture_diagnostics
        return 1
        ;;
      *)
        printf 'INT supervisor readiness failed: foreground identity unknown rc=%s\n' \
          "$state_rc" >&2
        int_fixture_diagnostics
        return 1
        ;;
    esac
    test_cleanup_tick
  done
  printf 'INT supervisor readiness timed out after 15 seconds\n' >&2
  int_fixture_diagnostics
  return 1
}

dump_hold_diagnostics() {
  local file
  printf 'recovery process-group readiness failed; diagnostics follow\n' >&2
  for file in \
    "${hold_output_file:-$TEST_DIR/recovery-process-group.out}" \
    "${hold_pid_file-}" "${hold_fd_file-}" "${hold_descendant_file-}" \
    "${hold_child_file-}" "${hold_grandchild_file-}" \
    "${hold_child_fd_file-}" "${hold_grandchild_fd_file-}"; do
    [[ -n "$file" ]] || continue
    printf '%s: ' "$file" >&2
    if [[ -e "$file" ]]; then
      ls -l -- "$file" >&2 || true
      sed -n '1,160p' -- "$file" >&2 || true
    else
      printf 'missing\n' >&2
    fi
  done
}

wait_for_hold_ready() {
  local i
  # 1500 * 0.01s is a bounded fifteen-second readiness window. The sleep is
  # conditional polling, not a blind delay, and covers container startup and
  # the two setsid layers used by the signal tests.
  for ((i = 0; i < 1500; i++)); do
    if ! kill -0 "$hold_outer" 2>/dev/null; then
      printf 'hold_outer exited before readiness (pid=%s)\n' "$hold_outer" >&2
      printf 'hold_outer job status before reap:\n' >&2
      jobs -l >&2 || true
      dump_hold_diagnostics
      return 1
    fi
    if [[ -s "$hold_pid_file" && -s "$hold_fd_file" &&
      -s "$hold_descendant_file" && -s "$hold_child_file" &&
      -s "$hold_grandchild_file" && -s "$hold_child_fd_file" &&
      -s "$hold_grandchild_fd_file" ]] &&
      [[ $(<"$hold_fd_file") == 0 && $(<"$hold_child_fd_file") == 0 &&
        $(<"$hold_grandchild_fd_file") == 0 ]]; then
      return 0
    fi
    /bin/sleep 0.01
  done
  printf 'hold process-group readiness timed out after 15 seconds\n' >&2
  dump_hold_diagnostics
  return 1
}

wait_for_process_exit() {
  local pid=$1 i state
  for ((i = 0; i < 300; i++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    state=$($REAL_PS -o stat= -p "$pid" 2>/dev/null | $REAL_TR -d '[:space:]' || true)
    if [[ $state == Z* ]]; then
      return 0
    fi
    test_cleanup_tick
  done
  printf 'process did not exit within 3 seconds: pid=%s state=%s\n' "$pid" "$state" >&2
  return 1
}

wait_for_int_outer_bounded() {
  local pid=$1 i state_rc outer_rc
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 2
  for ((i = 0; i < 3000; i++)); do
    state_rc=0
    test_process_state "$pid" || state_rc=$?
    case "$state_rc" in
      0) test_cleanup_tick ;;
      1)
        if wait "$pid"; then
          outer_rc=0
        else
          outer_rc=$?
        fi
        TEST_CHILD_STATUS["$pid"]=$outer_rc
        return "$outer_rc"
        ;;
      *) return 125 ;;
    esac
  done
  printf 'INT foreground bounded wait timed out pid=%s expected_starttime=%s expected_pgid=%s\n' \
    "$pid" "${TEST_PID_STARTTIME[$pid]-<missing>}" \
    "${TEST_PID_PGID[$pid]-<missing>}" >&2
  int_fixture_diagnostics
  return 124
}

test_process_alive() {
  local pid=$1 expected current state
  [[ "$pid" =~ ^[0-9]+$ && "$pid" != 0 ]] || return 1
  expected=${TEST_PID_STARTTIME[$pid]-}
  [[ "$expected" =~ ^[0-9]+$ ]] || return 1
  current=$(process_starttime "$pid" 2>/dev/null || true)
  [[ "$current" == "$expected" ]] || return 1
  state=$($REAL_PS -o stat= -p "$pid" 2>/dev/null | $REAL_TR -d '[:space:]' || true)
  [[ -n "$state" && "$state" != Z* ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

test_process_state() {
  local pid=$1 expected current line rest state
  local -a fields=()
  [[ "$pid" =~ ^[0-9]+$ && "$pid" != 0 ]] || return 2
  expected=${TEST_PID_STARTTIME[$pid]-}
  [[ "$expected" =~ ^[0-9]+$ ]] || return 2
  if [[ ! -e "/proc/$pid" ]]; then
    return 1
  fi
  if [[ ! -r "/proc/$pid/stat" ]]; then
    [[ ! -e "/proc/$pid/stat" ]] && return 1
    return 2
  fi
  if ! line=$(<"/proc/$pid/stat"); then
    # The identity was registered before this read.  A vanished proc entry is
    # a known exit; a still-present unreadable entry remains unknown.
    [[ ! -e "/proc/$pid/stat" ]] && return 1
    return 2
  fi
  rest=${line#*') '}
  [[ "$rest" != "$line" ]] || return 2
  read -r -a fields <<<"$rest"
  state=${fields[0]-}
  current=${fields[19]-}
  [[ "$state" =~ ^[A-Za-z]$ && "$current" =~ ^[0-9]+$ ]] || return 2
  [[ "$current" == "$expected" ]] || return 2
  [[ "$state" == Z* ]] && return 1
  kill -0 "$pid" 2>/dev/null || {
    [[ -e "/proc/$pid" ]] && return 2
    return 1
  }
  return 0
}

test_group_alive() {
  local wanted=$1 pid pgid state
  [[ "$wanted" =~ ^[0-9]+$ && "$wanted" != 0 ]] || return 1
  while read -r pid pgid state; do
    [[ "$pgid" == "$wanted" && "$state" != Z* ]] && return 0
  done < <($REAL_PS -eo pid=,pgid=,stat= 2>/dev/null)
  return 1
}

test_group_state() {
  local wanted=$1 entry pid line rest state pgid snapshot_rc live=0 zombie=0
  local -a fields=()
  [[ "$wanted" =~ ^[1-9][0-9]*$ && "$wanted" != 1 && "$wanted" != "$TEST_SHELL_PGID" &&
    "$wanted" != "$TEST_CALLER_PGID" ]] || return 2
  [[ -r /proc ]] || return 2
  for entry in /proc/[0-9]*; do
    if [[ ! -d "$entry" ]]; then
      [[ ! -e "$entry" ]] && continue
      return 2
    fi
    pid=${entry##*/}
    if [[ ! -r "$entry/stat" ]]; then
      [[ ! -e "$entry/stat" ]] && continue
      return 2
    fi
    if ! line=$(<"$entry/stat") 2>/dev/null; then
      [[ ! -e "$entry/stat" ]] && continue
      return 2
    fi
    rest=${line#*') '}
    [[ "$rest" != "$line" ]] || return 2
    read -r -a fields <<<"$rest"
    state=${fields[0]-}
    pgid=${fields[2]-}
    [[ "$state" =~ ^[A-Za-z]$ && "$pgid" =~ ^[0-9]+$ ]] || return 2
    [[ "$pgid" == "$wanted" ]] || continue
    if [[ "$state" == Z* ]]; then zombie=1; else live=1; fi
  done
  (( live )) && return 0
  (( zombie )) && return 1
  return 1
}

registered_pid_kill() {
  local signal=$1 pid=$2 expected current pgid state state_rc=0
  [[ "$signal" =~ ^(INT|TERM|HUP|KILL)$ ]] || return 2
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != 1 ]] || return 2
  test_pid_protected "$pid" && return 2
  expected=${TEST_PID_STARTTIME[$pid]-}
  pgid=${TEST_PID_PGID[$pid]-}
  [[ "$expected" =~ ^[0-9]+$ && "$pgid" =~ ^[1-9][0-9]*$ && "$pgid" != 1 ]] || return 2
  test_process_state "$pid" || state_rc=$?
  case "$state_rc" in
    1) return 1 ;;
    2) return 2 ;;
    *) ;;
  esac
  current=$(process_starttime "$pid" 2>/dev/null || true)
  state=$($REAL_PS -o stat= -p "$pid" 2>/dev/null | $REAL_TR -d '[:space:]' || true)
  [[ "$current" == "$expected" && "$state" != Z* ]] || return 2
  current=$($REAL_PS -o pgid= -p "$pid" 2>/dev/null | $REAL_TR -d '[:space:]' || true)
  [[ "$current" == "$pgid" && "$current" != "$TEST_SHELL_PGID" &&
    "$current" != "$TEST_CALLER_PGID" ]] || return 2
  test_group_state "$pgid" || return 2
  kill -"$signal" "$pid" 2>/dev/null || return 2
}

test_group_owned_by_registered_process() {
  local wanted=$1 entry pid pgid state line rest expected current
  local -a fields=()
  local live=0 registered_live=0 unknown=0
  [[ "$wanted" =~ ^[1-9][0-9]*$ && "$wanted" != 1 && "$wanted" != "$TEST_SHELL_PGID" &&
    "$wanted" != "$TEST_CALLER_PGID" ]] || return 2
  for entry in /proc/[0-9]*; do
    [[ -d "$entry" ]] || {
      [[ ! -e "$entry" ]] && continue
      unknown=1
      continue
    }
    pid=${entry##*/}
    if [[ ! -r "$entry/stat" ]]; then
      [[ ! -e "$entry/stat" ]] && continue
      unknown=1
      continue
    fi
    if ! line=$(<"$entry/stat") 2>/dev/null; then
      # A registered worker can disappear after the directory snapshot.  Do
      # not turn that known exit into unknown; a present unreadable entry is
      # still fail-closed.
      [[ ! -e "$entry/stat" ]] && continue
      unknown=1
      continue
    fi
    rest=${line#*') '}
    [[ "$rest" != "$line" ]] || { unknown=1; continue; }
    read -r -a fields <<<"$rest"
    state=${fields[0]-}; pgid=${fields[2]-}
    [[ "$state" =~ ^[A-Za-z]$ && "$pgid" =~ ^[0-9]+$ ]] || {
      unknown=1
      continue
    }
    [[ "$pgid" == "$wanted" ]] || continue
    [[ "$state" == Z* ]] || live=1
    expected=${TEST_PID_STARTTIME[$pid]-}
    if [[ "$state" != Z* && "$expected" =~ ^[0-9]+$ ]]; then
      current=${fields[19]-}
      [[ "$current" == "$expected" ]] && registered_live=1 || unknown=1
    elif [[ "$state" != Z* ]]; then
      unknown=1
    fi
  done
  (( unknown )) && return 2
  (( live && registered_live )) && return 0
  (( live )) && return 2
  return 1
}

test_cleanup_tick() {
  # A timed read on a FIFO gives the process a bounded yield without starting
  # a sleeper or adding another untracked background process.
  read -r -t 0.01 _ <&"$TEST_WAIT_FD" || true
}

test_processes_alive() {
  local pid pgid state_rc unknown=0
  for pid in "${TEST_PIDS[@]}"; do
    test_process_state "$pid" || state_rc=$?
    case "${state_rc:-0}" in
      0) return 0 ;;
      1) : ;;
      *) unknown=1 ;;
    esac
    state_rc=0
  done
  for pgid in "${TEST_PGIDS[@]}"; do
    state_rc=0
    test_group_owned_by_registered_process "$pgid" || state_rc=$?
    case "$state_rc" in
      0) ;;
      1) continue ;;
      *) unknown=1; continue ;;
    esac
    test_group_state "$pgid" || state_rc=$?
    case "${state_rc:-0}" in
      0) return 0 ;;
      1) : ;;
      *) unknown=1 ;;
    esac
    state_rc=0
  done
  (( unknown )) && return 2
  return 1
}

final_cleanup_proof() {
  local pid pgid state_rc owner_rc group_rc
  local -A seen_pgids=()
  for pid in "${TEST_PIDS[@]}"; do
    state_rc=0
    test_process_state "$pid" || state_rc=$?
    (( state_rc == 1 )) || return 2
  done
  for pid in "${TEST_CHILD_PIDS[@]}"; do
    [[ ${TEST_PID_STARTTIME[$pid]+present} == present &&
      ${TEST_PID_PGID[$pid]+present} == present ]] || return 2
    [[ ${TEST_CHILD_STATUS[$pid]+present} == present ]] || return 2
  done
  for pgid in "${TEST_PGIDS[@]}"; do
    [[ ${seen_pgids[$pgid]+present} == present ]] && continue
    seen_pgids["$pgid"]=1
    owner_rc=0
    test_group_owned_by_registered_process "$pgid" || owner_rc=$?
    (( owner_rc == 1 )) || return 2
    group_rc=0
    test_group_state "$pgid" || group_rc=$?
    (( group_rc == 1 )) || return 2
  done
  return 0
}

dump_process_cleanup_diagnostics() {
  local pid pgid expected current current_pgid state state_rc recorded
  local owner_rc group_rc
  printf 'process cleanup identity diagnostics (unknown_reason=%s):\n' \
    "${unknown_reason-<unset>}" >&2
  for pid in "${TEST_PIDS[@]}"; do
    state_rc=0
    test_process_state "$pid" || state_rc=$?
    expected=${TEST_PID_STARTTIME[$pid]-<missing>}
    current=$(process_starttime "$pid" 2>/dev/null || true)
    current_pgid=$($REAL_PS -o pgid= -p "$pid" 2>/dev/null |
      $REAL_TR -d '[:space:]' || true)
    state=$($REAL_PS -o stat= -p "$pid" 2>/dev/null |
      $REAL_TR -d '[:space:]' || true)
    recorded=no
    [[ ${TEST_CHILD_STATUS[$pid]+present} == present ]] && recorded=yes
    printf ' pid=%s expected_starttime=%s current_starttime=%s expected_pgid=%s current_pgid=%s state=%s state_rc=%s child_status_recorded=%s child_status=%s\n' \
      "$pid" "$expected" "${current:-<missing>}" "${TEST_PID_PGID[$pid]-<missing>}" \
      "${current_pgid:-<missing>}" "${state:-<missing>}" "$state_rc" "$recorded" \
      "${TEST_CHILD_STATUS[$pid]-<missing>}" >&2
  done
  for pgid in "${TEST_PGIDS[@]}"; do
    owner_rc=0
    test_group_owned_by_registered_process "$pgid" || owner_rc=$?
    group_rc=0
    test_group_state "$pgid" || group_rc=$?
    printf ' pgid=%s owner_rc=%s group_rc=%s\n' "$pgid" "$owner_rc" "$group_rc" >&2
  done
  printf ' direct_child_registry:\n' >&2
  for pid in "${TEST_CHILD_PIDS[@]}"; do
    printf '  pid=%s registered=%s child_status=%s\n' "$pid" \
      "$(if [[ ${TEST_PID_STARTTIME[$pid]+present} == present &&
        ${TEST_PID_PGID[$pid]+present} == present ]]; then printf yes; else printf no; fi)" \
      "$(if [[ ${TEST_CHILD_STATUS[$pid]+present} == present ]]; then printf yes; else printf no; fi)" >&2
  done
  printf ' child_status_registry:\n' >&2
  for pid in "${!TEST_CHILD_STATUS[@]}"; do
    printf '  pid=%s status=%s registered=%s\n' "$pid" "${TEST_CHILD_STATUS[$pid]}" \
      "$(if [[ ${TEST_PID_STARTTIME[$pid]+present} == present &&
        ${TEST_PID_PGID[$pid]+present} == present ]]; then printf yes; else printf no; fi)" >&2
  done
}

registered_group_kill() {
  local signal=$1 wanted=$2 pid expected current pgid state owner_rc state_rc
  [[ "$signal" =~ ^(INT|TERM|HUP|KILL)$ ]] || return 2
  [[ "$wanted" =~ ^[1-9][0-9]*$ && "$wanted" != 1 && "$wanted" != "$TEST_SHELL_PGID" &&
    "$wanted" != "$TEST_CALLER_PGID" ]] || return 1
  test_group_owned_by_registered_process "$wanted" || owner_rc=$?
  case "${owner_rc:-0}" in
    0) ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
  for pid in "${TEST_PIDS[@]}"; do
    expected=${TEST_PID_STARTTIME[$pid]-}
    [[ "$expected" =~ ^[0-9]+$ ]] || continue
    test_pid_protected "$pid" && continue
    current=$(process_starttime "$pid" 2>/dev/null || true)
    [[ "$current" == "$expected" ]] || continue
    read -r pgid state < <($REAL_PS -o pgid=,stat= -p "$pid" 2>/dev/null |
      $REAL_TR -s '[:space:]' ' ' || true)
    [[ "$pgid" == "$wanted" && "$state" != Z* ]] || continue
    test_group_state "$wanted" || state_rc=$?
    case "${state_rc:-0}" in
      0) ;;
      1) return 1 ;;
      *) return 2 ;;
    esac
    # Keep all identity and protected-group checks adjacent to the signal.
    # The caller must not split this validation from the negative-PGID kill.
    kill -"$signal" -- "-$wanted" 2>/dev/null || return 2
    return 0
  done
  return 1
}

stop_test_processes() {
  local pid pgid i proof_attempt still_alive=0 current expected state_rc=0 unknown=0 proof_rc=0
  local unknown_reason=
  # Signal groups first so the fake UDP worker and its descendants receive the
  # same bounded shutdown request as the real flock wrapper.
  for pgid in "${TEST_PGIDS[@]}"; do
    state_rc=0
    registered_group_kill TERM "$pgid" || state_rc=$?
    if (( state_rc == 2 )); then
      unknown=1
      [[ -n "$unknown_reason" ]] || unknown_reason="TERM group pgid=$pgid"
    fi
  done
  for pid in "${TEST_PIDS[@]}"; do
    if test_process_state "$pid" && ! test_pid_protected "$pid"; then
      if ! registered_pid_kill TERM "$pid"; then
        unknown=1
        [[ -n "$unknown_reason" ]] || unknown_reason="TERM pid=$pid"
      fi
    fi
  done

  for ((i = 0; i < 200; i++)); do
    state_rc=0
    test_processes_alive || state_rc=$?
    if (( state_rc == 1 )); then
      break
    fi
    if (( state_rc == 2 )); then
      unknown=1
      [[ -n "$unknown_reason" ]] || unknown_reason="TERM poll"
    fi
    test_cleanup_tick
  done

  state_rc=0
  test_processes_alive || state_rc=$?
  if (( state_rc == 0 )); then
    for pgid in "${TEST_PGIDS[@]}"; do
      state_rc=0
      registered_group_kill KILL "$pgid" || state_rc=$?
      if (( state_rc == 2 )); then
        unknown=1
        [[ -n "$unknown_reason" ]] || unknown_reason="KILL group/pid poll"
      fi
    done
    for pid in "${TEST_PIDS[@]}"; do
      if test_process_state "$pid" && ! test_pid_protected "$pid"; then
        registered_pid_kill KILL "$pid" || unknown=1
      fi
    done
    for ((i = 0; i < 100; i++)); do
      state_rc=0
      test_processes_alive || state_rc=$?
      if (( state_rc == 1 )); then
        break
      fi
      (( state_rc == 2 )) && unknown=1
      test_cleanup_tick
    done
  fi

  # Reap only direct children registered by this test.  Descendants are
  # verified by PID/PGID above and are not waitable from this shell.
  for pid in "${TEST_CHILD_PIDS[@]}"; do
    state_rc=0
    test_process_state "$pid" || state_rc=$?
    case "$state_rc" in
      1)
        if wait "$pid"; then
          TEST_CHILD_STATUS["$pid"]=0
        else
          TEST_CHILD_STATUS["$pid"]=$?
        fi
        ;;
      0|2)
        unknown=1
        [[ -n "$unknown_reason" ]] || unknown_reason="direct child pid=$pid state_rc=$state_rc"
        ;;
    esac
  done

  state_rc=0
  test_processes_alive || state_rc=$?
  if (( state_rc == 0 || state_rc == 2 || unknown )); then
    still_alive=1
  fi
  if (( state_rc == 2 )); then
    [[ -n "$unknown_reason" ]] || unknown_reason='final process/group state'
  fi
  proof_rc=2
  for ((proof_attempt = 0; proof_attempt < 100; proof_attempt++)); do
    if final_cleanup_proof; then
      proof_rc=0
      break
    fi
    test_cleanup_tick
  done
  if (( proof_rc == 0 )); then
    # A prior scan can observe a proc entry disappearing between enumeration
    # and stat read.  Clear only that transient unknown after every registered
    # PID, PGID, and direct-child wait has an independent known-final proof.
    unknown=0
    still_alive=0
  else
    still_alive=1
    [[ -n "$unknown_reason" ]] || unknown_reason="final proof rc=$proof_rc"
  fi
  if (( unknown )); then
    printf 'cleanup diagnostics: process identity or /proc state remained unknown\n' >&2
    dump_process_cleanup_diagnostics
    dump_hold_diagnostics
  fi
  (( still_alive == 0 ))
}

cleanup_test_fixture() {
  local rc=0
  if (( TEST_CLEANUP_RUNNING )); then
    return 0
  fi
  TEST_CLEANUP_RUNNING=1
  stop_test_processes || rc=1
  if (( rc == 0 )); then
    if ! "$REAL_RM" -rf -- "$TEST_DIR"; then
      rc=1
    fi
  fi
  if (( rc == 0 )); then
    exec {TEST_WAIT_FD}>&-
    exec {SUITE_LOCK_FD}>&- 2>/dev/null || true
  else
    printf 'test cleanup failed closed; fixture retained for diagnosis: %s\n' \
      "$TEST_DIR" >&2
    printf 'suite lock will be released only by shell/process exit; use a one-shot\n' >&2
    printf 'docker-init container to provide final PID-namespace isolation.\n' >&2
    return 1
  fi
}

ISOLATED_HOSTILE_ROOTS=()
ISOLATED_HOSTILE_IDS=()
ISOLATED_HOSTILE_CASE_DIRS=()
ISOLATED_HOSTILE_UIDS=()
ISOLATED_HOSTILE_CLEANUP_FAILED=0
HOSTILE_CASE_DIR=

isolated_hostile_cleanup() {
  local i current rc=0 root expected case_record case_dir case_id expected_lock_root
  if [[ -n ${CURRENT_UID_LOCK_SNAPSHOT-} ]]; then
    expected_lock_root="/tmp/frp-xudp-recovery-uid-$(id -u)"
    if [[ ${lock_root+x} != x ]]; then
      printf 'isolated cleanup refused current-UID lock check before lock-root initialization\n' >&2
      rc=1
    elif [[ -z "$lock_root" || "$lock_root" != "$expected_lock_root" ]]; then
      printf 'isolated cleanup refused unexpected current-UID lock path: %s\n' \
        "$lock_root" >&2
      rc=1
    else
      current=$(current_uid_lock_snapshot "$lock_root" 2>/dev/null || true)
      if [[ "$current" != "$CURRENT_UID_LOCK_SNAPSHOT" ]]; then
        printf 'isolated cleanup detected current-UID lock identity drift\n' >&2
        rc=1
      fi
    fi
  fi
  for ((i = 0; i < ${#ISOLATED_HOSTILE_ROOTS[@]}; i++)); do
    root=${ISOLATED_HOSTILE_ROOTS[i]}
    expected=${ISOLATED_HOSTILE_IDS[i]}
    [[ -n "$root" && -n "$expected" ]] || continue
    if [[ -e "$root" || -L "$root" ]]; then
      current=$($REAL_STAT -c '%d:%i %F %u %a' -- "$root" 2>/dev/null || true)
      if [[ "$current" == "$expected" ]]; then
        "$REAL_RM" -rf -- "$root" || rc=1
      else
        printf 'isolated cleanup refused changed or replaced lock object: %s\n' \
          "$root" >&2
        rc=1
      fi
    fi
  done
  for case_record in "${ISOLATED_HOSTILE_CASE_DIRS[@]}"; do
    case_dir=${case_record%%|*}
    case_id=${case_record#*|}
    if [[ -z "$case_dir" || -z "$case_id" || "$case_dir" != "$TEST_DIR/"* ||
      "$case_dir" == "$TEST_DIR" || -L "$case_dir" || ! -d "$case_dir" ]]; then
      printf 'isolated cleanup rejected unsafe or missing case directory: %s\n' \
        "$case_dir" >&2
      rc=1
      continue
    fi
    current=$($REAL_STAT -c '%d:%i' -- "$case_dir" 2>/dev/null || true)
    if [[ "$current" != "$case_id" ]]; then
      printf 'isolated cleanup refused changed case directory: %s\n' "$case_dir" >&2
      rc=1
      continue
    fi
    "$REAL_RM" -rf -- "$case_dir" || rc=1
  done
  ISOLATED_HOSTILE_ROOTS=()
  ISOLATED_HOSTILE_IDS=()
  ISOLATED_HOSTILE_CASE_DIRS=()
  ISOLATED_HOSTILE_UIDS=()
  (( rc == 0 )) || ISOLATED_HOSTILE_CLEANUP_FAILED=1
  return "$rc"
}

finish_test() {
  local rc=$?
  isolated_hostile_cleanup || rc=1
  cleanup_test_fixture || rc=1
  (( ISOLATED_HOSTILE_CLEANUP_FAILED )) && rc=1
  (( TEST_FINAL_FAILURE )) && rc=1
  trap - EXIT
  exit "$rc"
}

trap 'finish_test' EXIT
trap 'isolated_hostile_cleanup || TEST_FINAL_FAILURE=1; cleanup_test_fixture || TEST_FINAL_FAILURE=1; trap - TERM; exit 143' TERM
trap 'isolated_hostile_cleanup || TEST_FINAL_FAILURE=1; cleanup_test_fixture || TEST_FINAL_FAILURE=1; trap - INT; exit 130' INT
trap 'isolated_hostile_cleanup || TEST_FINAL_FAILURE=1; cleanup_test_fixture || TEST_FINAL_FAILURE=1; trap - HUP; exit 129' HUP

# Byte-level probe for the strict Docker-inspect wire contract.  It uses only
# Bash printf plus POSIX/coreutils od/tr: no Docker, Go, or temporary file.
strict_inspect_hex_valid() {
  local inspect_hex=$1 payload_hex
  [[ -n "$inspect_hex" && "$inspect_hex" =~ ^([0-9a-f]{2})+$ ]] || return 1
  [[ "$inspect_hex" == *0a && "${inspect_hex%0a}" != *0a ]] || return 1
  payload_hex=${inspect_hex%0a}
  [[ -n "$payload_hex" &&
    "$payload_hex" =~ ^(([2-6][0-9a-f])|(7[0-9a-e]))+$ ]]
}

strict_inspect_byte_probe() {
  local label=$1 expected=$2 printf_format=$3 actual
  if ! actual=$(printf '%b' "$printf_format" |
    od -An -v -tx1 | tr -d '[:space:]'); then
    printf 'byte probe encoder failed: %s\n' "$label" >&2
    return 1
  fi
  [[ "$actual" == "$expected" ]] || {
    printf 'byte probe encoding mismatch: %s (%s != %s)\n' \
      "$label" "$actual" "$expected" >&2
    return 1
  }
  return 0
}

strict_inspect_byte_probe normal 6f6e650a 'one\n'
strict_inspect_byte_probe one-nul-no-final-lf 6f6e650a0030 'one\n\x000'
strict_inspect_byte_probe nul-middle 6f6e650074776f0a 'one\000two\n'
strict_inspect_byte_probe nul-end 6f6e650a00 'one\n\000'
strict_inspect_byte_probe cr 6f6e650d0a 'one\r\n'
strict_inspect_byte_probe multiline 6f6e650a65787472610a 'one\nextra\n'
strict_inspect_byte_probe no-final-lf 6f6e65 'one'
strict_inspect_hex_valid 6f6e650a
for strict_rejected_hex in \
  6f6e650a0030 6f6e65000074776f6e 6f6e650a00 \
  6f6e650d0a 6f6e650a65787472610a 6f6e65; do
  if strict_inspect_hex_valid "$strict_rejected_hex"; then
    printf 'byte probe unexpectedly accepted: %s\n' "$strict_rejected_hex" >&2
    exit 1
  fi
done

if GOCACHE="$TEST_DIR/go-cache" go build -o "$JSON_VALIDATOR" -- "$JSON_HELPER"; then
  :
else
  rc=$?
  printf 'xudp-init-build-error rc=%s stage=go-build source=%s output=%s\n' \
    "$rc" "$JSON_HELPER" "$JSON_VALIDATOR" >&2
  exit "$rc"
fi

validate_json() {
  "$JSON_VALIDATOR" "$@"
}

cat >"$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
{
  printf 'docker'
  printf ' %q' "$@"
  printf '\n'
} >>"${FAKE_DOCKER_LOG:?}"

layout_error() {
  printf 'invalid fake-docker argument layout:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  exit 64
}

valid_name() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

fake_runtime_root() {
  local candidate newest=
  if [[ -f ${FAKE_STATE_DIR:?}/current-runtime ]]; then
    candidate=$(<"${FAKE_STATE_DIR}/current-runtime")
    if [[ "$candidate" =~ ^/tmp/frp-xudp-smoke\.[A-Za-z0-9]{6}$ &&
      -d "$candidate" && ! -L "$candidate" &&
      -f "$candidate/bin/frps" && -f "$candidate/bin/frpc" &&
      -f "$candidate/config/frps.toml" &&
      -f "$candidate/config/frpc.toml" &&
      -f "$candidate/config/frpc-visitor.toml" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  for candidate in /tmp/frp-xudp-smoke.*; do
    [[ -d "$candidate" && ! -L "$candidate" &&
      -f "$candidate/bin/frps" && -f "$candidate/bin/frpc" &&
      -f "$candidate/config/frps.toml" &&
      -f "$candidate/config/frpc.toml" &&
      -f "$candidate/config/frpc-visitor.toml" ]] || continue
    if [[ -z "$newest" || "$candidate" -nt "$newest" ]]; then
      newest=$candidate
    fi
  done
  [[ -n "$newest" ]] || return 74
  printf '%s\n' "$newest"
}

fake_runtime_write_in_place() {
  local path=$1 content=$2 original_mode
  original_mode=$(stat -Lc '%a' -- "$path") || return 74
  chmod u+w -- "$path" || return 74
  printf '%s\n' "$content" >"$path" || return 74
  chmod "$original_mode" -- "$path" || return 74
}

fake_runtime_mutate() {
  local stage=$1 mode=${FAKE_RUNTIME_MUTATION:-} root path tmp marker run_count old_log_dir
  [[ -n "$mode" ]] || return 0
  root=$(fake_runtime_root) || return 74
  marker="${FAKE_STATE_DIR:?}/runtime-mutation-${FAKE_RUNTIME_MUTATION_ID:?}-$stage"
  [[ ! -e "$marker" ]] || return 0
  run_count=0
  if [[ -e ${FAKE_STATE_DIR:?}/runtime-run-count-${FAKE_RUNTIME_MUTATION_ID:?} ]]; then
    run_count=$(<"${FAKE_STATE_DIR}/runtime-run-count-${FAKE_RUNTIME_MUTATION_ID}")
  fi
  case "$stage:$mode:$run_count" in
    before-first:before-first:0) path="$root/bin/frpc" ;;
    before-first:before-first-frps:0) path="$root/bin/frps" ;;
    before-first:before-first-frpc:0) path="$root/bin/frpc" ;;
    before-first:before-first-frps-config:0) path="$root/config/frps.toml" ;;
    before-first:before-first-frpc-config:0) path="$root/config/frpc.toml" ;;
    before-first:before-first-visitor-config:0) path="$root/config/frpc-visitor.toml" ;;
    before-first:before-first-mode:0) path="$root/bin/frpc" ;;
    before-first:same-content-new-inode:0) path="$root/bin/frpc" ;;
    before-first:content-in-place:0) path="$root/bin/frpc" ;;
    before-first:symlink:0) path="$root/bin/frpc" ;;
    before-first:nlink2:0) path="$root/bin/frpc" ;;
    before-first:owner:0) path="$root/bin/frpc" ;;
    before-first:type:0) path="$root/bin/frpc" ;;
    before-first:missing:0) path="$root/bin/frpc" ;;
    after-run:after-first-frpc:1) path="$root/bin/frpc" ;;
    after-run:after-second-visitor:2) path="$root/config/frpc-visitor.toml" ;;
    after-run:config-directory:1) path="$root/config" ;;
    after-run:log-directory:1) path="$root/log" ;;
    after-run:log-content:1) path="$root/log/frps.log" ;;
    *) return 0 ;;
  esac
  case "$mode" in
    before-first|before-first-frps|before-first-frpc|before-first-frps-config|before-first-frpc-config|before-first-visitor-config)
      fake_runtime_write_in_place "$path" changed-before-first-run
      ;;
    before-first-mode)
      chmod 644 -- "$path"
      ;;
    same-content-new-inode)
      tmp="$path.tmp.$$"
      cp -- "$path" "$tmp"
      mv -- "$tmp" "$path"
      ;;
    content-in-place)
      fake_runtime_write_in_place "$path" changed-in-place
      ;;
    symlink)
      "$REAL_RM" -f -- "$path"
      ln -s -- /dev/null "$path"
      ;;
    nlink2)
      "$REAL_RM" -f -- "/tmp/xudp-static-hardlink-${FAKE_RUNTIME_MUTATION_ID}"
      ln -- "$path" "/tmp/xudp-static-hardlink-${FAKE_RUNTIME_MUTATION_ID}"
      ;;
    owner)
      printf '%s\n' "$path" >"${FAKE_STATE_DIR}/runtime-owner-path-${FAKE_RUNTIME_MUTATION_ID}"
      ;;
    type)
      "$REAL_RM" -f -- "$path"
      mkdir -- "$path"
      ;;
    missing)
      "$REAL_RM" -f -- "$path"
      ;;
    after-first-frpc)
      tmp="$path.tmp.$$"
      cp -- "$path" "$tmp"
      mv -- "$tmp" "$path"
      ;;
    after-second-visitor)
      fake_runtime_write_in_place "$path" visitor-config-replaced
      ;;
    config-directory)
      "$REAL_RM" -f -- "$root/config/frps.toml" "$root/config/frpc.toml" \
        "$root/config/frpc-visitor.toml"
      "$REAL_RMDIR" -- "$root/config"
      mkdir -m 700 -- "$root/config"
      ;;
    log-directory)
      old_log_dir="/tmp/xudp-static-old-log-${FAKE_RUNTIME_MUTATION_ID}"
      "$REAL_RMDIR" -- "$old_log_dir" 2>/dev/null || true
      mv -- "$root/log" "$old_log_dir"
      mkdir -m 700 -- "$root/log"
      ;;
    log-content)
      printf 'dynamic-log-content\n' >"$path"
      ;;
  esac
  : >"$marker"
}

emit_strict_inspect_fixture() {
  case ${1:-} in
    one-nul-no-final-lf)
      printf 'one\n'
      printf '\0'
      printf '0'
      ;;
    nul-middle)
      printf 'one'
      printf '\0'
      printf 'two\n'
      ;;
    nul-end)
      printf 'one\n'
      printf '\0'
      ;;
    no-final-lf) printf 'one' ;;
    *) return 1 ;;
  esac
}

case "${1:-}" in
  network)
    [[ $# == 4 && $2 == inspect && $3 == -- ]] || layout_error "$@"
    valid_name "$4" || layout_error "$@"
    ;;
  inspect)
    format=
    if [[ $# == 3 && $2 == -- ]]; then
      valid_name "$3" || layout_error "$@"
    elif [[ $# == 5 && $2 == --format && $4 == -- ]]; then
      format=$3
      valid_name "$5" || layout_error "$@"
    else
      layout_error "$@"
    fi
    if [[ "$format" == '{{range .Mounts}}'* ]]; then
      printf '%s\n' "${FAKE_STAGED_TAMPER-unset}" >"${FAKE_STATE_DIR:?}/inspect-mounts-tamper-value"
      if [[ ${FAKE_STAGED_TAMPER:-0} == 1 ]]; then
        [[ -f ${FAKE_STATE_DIR}/current-runtime ]] || exit 74
        staged_root=$(<"${FAKE_STATE_DIR}/current-runtime")
        if [[ ! "$staged_root" =~ ^/tmp/frp-xudp-smoke\.[A-Za-z0-9]{6}$ ||
          ! -d "$staged_root" || -L "$staged_root" ||
          ! -f "$staged_root/bin/frpc" || -L "$staged_root/bin/frpc" ]]; then
          printf 'root=%q regex=%s dir=%s root_symlink=%s frpc_file=%s frpc_symlink=%s\n' \
            "$staged_root" \
            "$([[ "$staged_root" =~ ^/tmp/frp-xudp-smoke\.[A-Za-z0-9]{6}$ ]] && echo yes || echo no)" \
            "$([[ -d "$staged_root" ]] && echo yes || echo no)" \
            "$([[ -L "$staged_root" ]] && echo yes || echo no)" \
            "$([[ -f "$staged_root/bin/frpc" ]] && echo yes || echo no)" \
            "$([[ -L "$staged_root/bin/frpc" ]] && echo yes || echo no)" \
            >"${FAKE_STATE_DIR}/staged-tamper-validation-failed"
          exit 74
        fi
        staged_tmp="$staged_root/bin/.frpc.staged-tamper.$$"
        printf 'staged-tamper\n' >"$staged_tmp"
        chmod 0555 -- "$staged_tmp"
        mv -f -- "$staged_tmp" "$staged_root/bin/frpc"
        : >"${FAKE_STATE_DIR}/staged-tampered"
      fi
    fi
    case "$format" in
      '{{.State.Status}}') printf 'running\n' ;;
      *'.Config.Image'*) printf 'image=fake/frp:test started=2026-01-01T00:00:00Z\n' ;;
      '{{range .Mounts}}'*)
        if [[ -n ${FAKE_OLD_RUNTIME_DIR:-} && ${FAKE_MOUNT_SCENARIO:-} == one-nul-no-final-lf &&
          $5 == frpsA ]]; then
          emit_strict_inspect_fixture one-nul-no-final-lf
        elif [[ -n ${FAKE_OLD_RUNTIME_DIR:-} && ${FAKE_MOUNT_SCENARIO:-} == nul-middle &&
          $5 == frpsA ]]; then
          emit_strict_inspect_fixture nul-middle
        elif [[ -n ${FAKE_OLD_RUNTIME_DIR:-} && ${FAKE_MOUNT_SCENARIO:-} == nul-end &&
          $5 == frpsA ]]; then
          emit_strict_inspect_fixture nul-end
        elif [[ -n ${FAKE_OLD_RUNTIME_DIR:-} && ${FAKE_MOUNT_SCENARIO:-} == no-final-lf &&
          $5 == frpsA ]]; then
          emit_strict_inspect_fixture no-final-lf
        elif [[ -n ${FAKE_OLD_RUNTIME_DIR:-} ]]; then
          scenario=${FAKE_MOUNT_SCENARIO:-common}
          # Match Docker's real framing for the mount template: each record is
          # LF-prefixed and Docker contributes the one final LF.
          printf '\n'
          case "$scenario:$5" in
            common:frpsA|normal:frpsA|mismatch:frpsA|missing:frpsA|multiple:frpsA)
              printf '%s|/usr/local/bin/frps\n' "$FAKE_OLD_RUNTIME_DIR"
              printf '%s|/run/uncontrolled\n' "${FAKE_UNCONTROLLED_RUNTIME_DIR:-/tmp/not-frp-runtime}"
              [[ $scenario != multiple ]] || printf '%s|/other/frps\n' "${FAKE_OLD_RUNTIME_DIR_2:?}"
              ;;
            multiline:frpsA)
              printf '%s|/usr/local/bin/frps\n\n' "$FAKE_OLD_RUNTIME_DIR"
              ;;
            cr:frpsA)
              printf '%s\r|/usr/local/bin/frps\n' "$FAKE_OLD_RUNTIME_DIR"
              ;;
            common:frpcB|normal:frpcB|missing:frpcB|multiple:frpcB)
              printf '%s/bin/frpc|/usr/local/bin/frpc\n%s/config/frpc.toml|/etc/frp/frpc.toml\n' \
                "$FAKE_OLD_RUNTIME_DIR" "$FAKE_OLD_RUNTIME_DIR"
              ;;
            mismatch:frpcB)
              printf '%s/bin/frpc|/usr/local/bin/frpc\n' "${FAKE_OLD_RUNTIME_DIR_2:?}"
              ;;
            common:frpC|normal:frpC|mismatch:frpC|multiple:frpC)
              printf '%s/config/frpc-visitor.toml|/etc/frp/frpc.toml\n' "$FAKE_OLD_RUNTIME_DIR"
              ;;
            missing:frpC)
              printf '%s|/run/uncontrolled\n' "${FAKE_UNCONTROLLED_RUNTIME_DIR:-/tmp/not-frp-runtime}"
              ;;
          esac
        else
          # docker inspect --format terminates even an empty template result
          # with one LF; the strict capture contract depends on that framing.
          printf '\n'
        fi
        ;;
      '{{index .Config.Labels "frp.xudp.runtime.path"}}')
        path_label=${FAKE_OLD_RUNTIME_PATH_LABEL:-}
        if [[ ${FAKE_LABEL_SCENARIO:-} == mismatch && $5 == frpC ]]; then
          path_label=${FAKE_OLD_RUNTIME_PATH_LABEL_MISMATCH:-$path_label}
        elif [[ ${FAKE_LABEL_SCENARIO:-} == missing ]]; then
          path_label=
        fi
        if [[ ${FAKE_LABEL_SCENARIO:-} == one-nul-no-final-lf && $5 == frpsA ]]; then
          emit_strict_inspect_fixture one-nul-no-final-lf
        elif [[ ${FAKE_LABEL_SCENARIO:-} == nul-middle && $5 == frpsA ]]; then
          emit_strict_inspect_fixture nul-middle
        elif [[ ${FAKE_LABEL_SCENARIO:-} == nul-end && $5 == frpsA ]]; then
          emit_strict_inspect_fixture nul-end
        elif [[ ${FAKE_LABEL_SCENARIO:-} == no-final-lf && $5 == frpsA ]]; then
          emit_strict_inspect_fixture no-final-lf
        elif [[ ${FAKE_LABEL_SCENARIO:-} == multiline && $5 == frpsA ]]; then
          printf '%s\nextra\n' "$path_label"
        elif [[ ${FAKE_LABEL_SCENARIO:-} == cr && $5 == frpsA ]]; then
          printf '%s\r\n' "$path_label"
        else
          printf '%s\n' "$path_label"
        fi
        ;;
      '{{index .Config.Labels "frp.xudp.runtime.identity"}}')
        identity_label=${FAKE_OLD_RUNTIME_IDENTITY:-}
        if [[ ${FAKE_LABEL_SCENARIO:-} == mismatch && $5 == frpC ]]; then
          identity_label=${FAKE_OLD_RUNTIME_IDENTITY_MISMATCH:-$identity_label}
        elif [[ ${FAKE_LABEL_SCENARIO:-} == bad ]]; then
          identity_label=v1-invalid
        elif [[ ${FAKE_LABEL_SCENARIO:-} == missing ]]; then
          identity_label=
        fi
        if [[ ${FAKE_LABEL_SCENARIO:-} == one-nul-no-final-lf && $5 == frpsA ]]; then
          emit_strict_inspect_fixture one-nul-no-final-lf
        elif [[ ${FAKE_LABEL_SCENARIO:-} == nul-middle && $5 == frpsA ]]; then
          emit_strict_inspect_fixture nul-middle
        elif [[ ${FAKE_LABEL_SCENARIO:-} == nul-end && $5 == frpsA ]]; then
          emit_strict_inspect_fixture nul-end
        elif [[ ${FAKE_LABEL_SCENARIO:-} == no-final-lf && $5 == frpsA ]]; then
          emit_strict_inspect_fixture no-final-lf
        elif [[ ${FAKE_LABEL_SCENARIO:-} == multiline && $5 == frpsA ]]; then
          printf '%s\nextra\n' "$identity_label"
        elif [[ ${FAKE_LABEL_SCENARIO:-} == cr && $5 == frpsA ]]; then
          printf '%s\r\n' "$identity_label"
        else
          printf '%s\n' "$identity_label"
        fi
        ;;
      *'.Mounts'*) printf 'mounts=[]\n' ;;
      *'.IPAddress'*) printf '127.0.0.1\n' ;;
    esac
    ;;
  exec)
    if [[ ${2:-} == --user ]]; then
      [[ $# -ge 9 && $3 =~ ^[0-9]+:[0-9]+$ && $4 == -- &&
        $6 == /bin/sh && $7 == -c ]] || layout_error "$@"
      valid_name "$5" || layout_error "$@"
      [[ ${FAKE_DOCKER_FAIL_EXEC:-0} != 1 ]]
      script=$8
      if [[ "$script" == *'mktemp -d /tmp/xudp-build.XXXXXX'* ]]; then
        if [[ ${FAKE_BUILD_SYMLINK:-0} == 1 ]]; then
          build_path=/tmp/xudp-build.ABCDEF
          target=${FAKE_BUILD_SYMLINK_TARGET:?}
          "${REAL_RM:?}" -f -- "$build_path"
          ln -s -- "$target" "$build_path"
        else
          build_path=$(${REAL_MKTEMP:?} -d /tmp/xudp-build.XXXXXX)
          chmod 700 -- "$build_path"
        fi
        printf '%s\n' "$build_path" >>"${FAKE_BUILD_LOG:?}"
        [[ ! -L "$build_path" && -d "$build_path" ]] || exit 1
        build_real=$(realpath -- "$build_path")
        build_stat=$(stat -Lc '%d:%i|%F|%u|%a' -- "$build_path")
        printf '%s|%s|%s\n' "$build_path" "$build_real" "$build_stat"
      else
        printf 'fake-recovery-docker-exec-output\n'
      fi
      exit 0
    fi
    [[ $# -ge 5 && $2 == -- ]] || layout_error "$@"
    valid_name "$3" || layout_error "$@"
    if [[ ${FAKE_REPLACE_PMTUD_REPORT:-0} == 1 && ! -e ${FAKE_STATE_DIR:?}/pmtud-replaced ]]; then
      mv -- "${XUDP_PMTUD_REPORT:?}" "${XUDP_PMTUD_REPORT}.opened"
      printf 'replacement-path-content\n' >"${XUDP_PMTUD_REPORT}"
      : >"${FAKE_STATE_DIR}/pmtud-replaced"
    fi
    [[ ${FAKE_DOCKER_FAIL_EXEC:-0} != 1 ]]
    script=${6:-}
    if [[ "$script" == *'mktemp -d /tmp/xudp-build.XXXXXX'* ]]; then
      if [[ ${FAKE_BUILD_SYMLINK:-0} == 1 ]]; then
        build_path=/tmp/xudp-build.ABCDEF
        target=${FAKE_BUILD_SYMLINK_TARGET:?}
        rm -f -- "$build_path"
        ln -s -- "$target" "$build_path"
      else
        build_path=$(${REAL_MKTEMP:?} -d /tmp/xudp-build.XXXXXX)
        chmod 700 -- "$build_path"
      fi
      printf '%s\n' "$build_path" >>"${FAKE_BUILD_LOG:?}"
      printf '%s\n' "$build_path"
      [[ ! -L "$build_path" && -d "$build_path" ]]
    elif [[ "$script" == *'go build'* ]]; then
      build_path=${!#}
      mkdir -p -- "$build_path"
      printf 'fake-frps-%s\n' "$BASHPID" >"$build_path/frps"
      printf 'fake-frpc-%s\n' "$BASHPID" >"$build_path/frpc"
    elif [[ "$script" == *'sha256sum'* ]]; then
      build_path=${!#}
      sha256sum -- "$build_path/frps" "$build_path/frpc"
    elif [[ "$script" == *'rm -rf -- "$1"'* ]]; then
      build_path=${!#}
      [[ "$build_path" =~ ^/tmp/xudp-build\.[A-Za-z0-9]{6}$ ]] || exit 91
      [[ ! -L "$build_path" && -d "$build_path" ]] || exit 92
      "$REAL_RM" -rf -- "$build_path"
    else
      printf 'fake-docker-exec-output\n'
    fi
    ;;
  cp)
    [[ $# == 4 && $2 == -- && $3 == *:* && $4 == /* ]] || layout_error "$@"
    : >"$4"
    ;;
  rm)
    [[ $# == 6 && $2 == -f && $3 == -- && $4 == frpsA && $5 == frpcB && $6 == frpC ]] || layout_error "$@"
    if [[ -n ${FAKE_ORDER_REPORT:-} ]]; then
      grep -Fqx 'staged_runtime_preflight=PASS' -- "$FAKE_ORDER_REPORT" || exit 93
      printf 'docker-rm\n' >>"${FAKE_ORDER_EVENTS:?}"
    fi
    [[ ${FAKE_DOCKER_FAIL_RM:-0} != 1 ]]
    fake_runtime_mutate before-first
    ;;
  run)
    [[ $# -ge 10 && $2 == -d ]] || layout_error "$@"
    found_name=0
    found_network=0
    found_separator=0
    identity_label_count=0
    path_label_count=0
    for ((i=3; i<=$#; i++)); do
      value=${!i}
      if [[ $value == --name ]]; then
        next=$((i + 1)); valid_name "${!next}" || layout_error "$@"; run_name=${!next}; found_name=1
      elif [[ $value == --network ]]; then
        next=$((i + 1)); valid_name "${!next}" || layout_error "$@"; found_network=1
      elif [[ $value == --label ]]; then
        next=$((i + 1))
        case "${!next:-}" in
          frp.xudp.runtime.identity=*) identity_label_count=$((identity_label_count + 1)) ;;
          frp.xudp.runtime.path=*) path_label_count=$((path_label_count + 1)) ;;
          *) layout_error "$@" ;;
        esac
      elif [[ $value == -- ]]; then
        next=$((i + 1)); [[ ${!next:-} == ubuntu:26.04 ]] || layout_error "$@"; found_separator=1
        break
      fi
    done
    [[ $found_name == 1 && $found_network == 1 && $found_separator == 1 &&
      $identity_label_count == 1 && $path_label_count == 1 ]] || layout_error "$@"
    if [[ -n ${FAKE_ORDER_REPORT:-} ]]; then
      case $run_name in
        frpsA) expected_previous=docker-rm ;;
        frpcB) expected_previous=docker-run:frpsA ;;
        frpC) expected_previous=docker-run:frpcB ;;
        *) exit 95 ;;
      esac
      grep -Fqx "live_runtime_preflight=PASS container=$run_name" -- "$FAKE_ORDER_REPORT" || exit 94
      [[ -s ${FAKE_ORDER_EVENTS:?} &&
        $(tail -n 1 -- "$FAKE_ORDER_EVENTS") == "$expected_previous" ]] || exit 95
      printf 'docker-run:%s\n' "$run_name" >>"${FAKE_ORDER_EVENTS:?}"
    fi
    if [[ ${FAKE_DOCKER_FAIL_RUN:-0} == 1 ]]; then
      exit 1
    fi
    if [[ -n ${FAKE_DOCKER_FAIL_RUN_RC:-} ]]; then
      [[ ${FAKE_DOCKER_FAIL_RUN_RC} =~ ^[1-9][0-9]*$ ]] || exit 64
      exit "${FAKE_DOCKER_FAIL_RUN_RC}"
    fi
    if [[ -n ${FAKE_RUNTIME_MUTATION:-} ]]; then
      run_count_file="${FAKE_STATE_DIR}/runtime-run-count-${FAKE_RUNTIME_MUTATION_ID:?}"
      run_count=0
      [[ ! -e "$run_count_file" ]] || run_count=$(<"$run_count_file")
      run_count=$((run_count + 1))
      printf '%s\n' "$run_count" >"$run_count_file"
      fake_runtime_mutate after-run
    fi
    ;;
  logs)
    [[ $# == 3 && $2 == -- ]] || layout_error "$@"
    valid_name "$3" || layout_error "$@"
    printf 'tunnel established via p2p\n'
    ;;
  *) layout_error "$@" ;;
esac
EOF

cat >"$FAKE_BIN/timeout" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
timeout_error() {
  printf 'invalid fake-timeout argument layout:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  exit 64
}
[[ $# == 5 && $1 == --foreground && $2 == 15 ]] || timeout_error "$@"
case $5 in
  existing-[123])
    [[ $3 == "${FRP_XUDP_UDP_SEND:?}" && $3 == /* && $3 != -- ]] || timeout_error "$@"
    ;;
  p2p-[123]|relay-[123])
    [[ $3 =~ ^/tmp/frp-xudp-smoke\.[A-Za-z0-9]{6}/bin/udp_send$ &&
      -f $3 && ! -L $3 && -x $3 ]] || timeout_error "$@"
    ;;
  *) timeout_error "$@" ;;
esac
[[ $4 =~ ^[^[:space:]]+:9000$ ]] || timeout_error "$@"
{
  printf 'timeout'
  printf ' %q' "$@"
  printf '\n'
} >>"${FAKE_TIMEOUT_LOG:?}"
if [[ ${FAKE_REPLACE_RECOVERY_REPORT:-0} == 1 && ! -e ${FAKE_STATE_DIR:?}/recovery-replaced ]]; then
  mv -- "${FRP_XUDP_RECOVERY_REPORT:?}" "${FRP_XUDP_RECOVERY_REPORT}.opened"
  printf 'replacement-path-content\n' >"${FRP_XUDP_RECOVERY_REPORT}"
  : >"${FAKE_STATE_DIR}/recovery-replaced"
fi
exec "$3" "$4" "$5"
EOF

cat >"$FAKE_BIN/udp_send" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
diagnostic_process() {
  local phase=${1:-unknown} pid=${2:-$$} line rest state ppid pgid sid starttime ign cgt cmd exe
  [[ -n ${FAKE_UDP_PROCESS_DIAGNOSTIC_FILE:-} ]] || return 0
  if [[ -r "/proc/$pid/stat" ]]; then
    line=$(<"/proc/$pid/stat") || line=
    rest=${line##*') '}
    read -r -a fields <<<"$rest"
    state=${fields[0]-missing}; ppid=${fields[1]-missing}; pgid=${fields[2]-missing}
    sid=${fields[3]-missing}; starttime=${fields[19]-missing}
    read -r state ppid pgid sid _ _ _ _ _ _ _ _ _ _ _ _ _ _ starttime _ <<<"$rest" || true
    state=${fields[0]-missing}; ppid=${fields[1]-missing}; pgid=${fields[2]-missing}
    sid=${fields[3]-missing}; starttime=${fields[19]-missing}
  else
    state=missing; ppid=missing; pgid=missing; sid=missing; starttime=missing
  fi
  ign=$(awk '/^SigIgn:/ { print $2; found=1 } END { if (!found) print "missing" }' "/proc/$pid/status" 2>/dev/null || printf '%s' missing)
  cgt=$(awk '/^SigCgt:/ { print $2; found=1 } END { if (!found) print "missing" }' "/proc/$pid/status" 2>/dev/null || printf '%s' missing)
  cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || printf '%s' missing)
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null || printf '%s' missing)
  {
    printf 'process phase=%s pid=%s ppid=%s pgid=%s sid=%s starttime=%s state=%s SigIgn=%s SigCgt=%s exe=%s cmdline=%s\n' \
      "$phase" "$pid" "$ppid" "$pgid" "$sid" "$starttime" "$state" "$ign" "$cgt" "$exe" "$cmd"
  } >>"${FAKE_UDP_PROCESS_DIAGNOSTIC_FILE}"
}
if [[ ${FAKE_UDP_FAIL:-0} == 1 ]]; then
  printf 'simulated UDP failure\n' >&2
  exit 9
fi
if [[ -n ${FAKE_UDP_HOLD_PID_FILE:-} ]]; then
  fd_count=0
  for fd in /proc/$$/fd/*; do
    target=$(readlink -- "$fd" 2>/dev/null || true)
    [[ "$target" == "${FAKE_LOCK_PATH:-}" ]] && fd_count=$((fd_count + 1))
  done
  printf '%s\n' "$fd_count" >"${FAKE_UDP_FD_FILE:?}"
  printf '%s\n' "$$" >"${FAKE_UDP_HOLD_PID_FILE}"
  if [[ -n ${FAKE_UDP_HOLD_STARTTIME_FILE:-} ]]; then
    stat_line=$(<"/proc/$$/stat")
    stat_rest=${stat_line#*') '}
    read -r -a stat_fields <<<"$stat_rest"
    printf '%s\n' "${stat_fields[19]:-}" >"${FAKE_UDP_HOLD_STARTTIME_FILE}"
  fi
  record_signal() {
    trap '' INT TERM HUP
    diagnostic_process "worker-signal-$1" "$$"
    [[ -z ${FAKE_UDP_SIGNAL_DELIVERED_FILE:-} ]] || printf '%s:%s\n' "$1" "$$" >>"$FAKE_UDP_SIGNAL_DELIVERED_FILE"
    case "$1" in
      INT) exit "${FAKE_UDP_INT_EXIT:-130}" ;;
      TERM) exit "${FAKE_UDP_TERM_EXIT:-143}" ;;
      HUP) exit "${FAKE_UDP_HUP_EXIT:-129}" ;;
    esac
  }
  trap 'record_signal INT' INT
  trap 'record_signal TERM' TERM
  trap 'record_signal HUP' HUP
  /usr/bin/env --default-signal=INT --default-signal=TERM --default-signal=HUP /bin/bash -c 'record_signal() { trap "" INT TERM HUP; [[ -z ${FAKE_UDP_SIGNAL_DELIVERED_FILE:-} ]] || printf "%s:%s\n" "$1" "$BASHPID" >>"$FAKE_UDP_SIGNAL_DELIVERED_FILE"; case "$1" in INT) exit "${FAKE_UDP_INT_EXIT:-130}";; TERM) exit "${FAKE_UDP_TERM_EXIT:-143}";; HUP) exit "${FAKE_UDP_HUP_EXIT:-129}";; esac; }; trap "record_signal INT" INT; trap "record_signal TERM" TERM; trap "record_signal HUP" HUP; count=0; for fd in /proc/$$/fd/*; do target=$(readlink -- "$fd" 2>/dev/null || true); [[ "$target" == "${FAKE_LOCK_PATH:-}" ]] && count=$((count + 1)); done; printf "%s\n" "$count" >"$FAKE_UDP_CHILD_FD_FILE"; printf "%s\n" "$BASHPID" >>"$FAKE_UDP_CHILD_PID_FILE"; for ((i = 0; i < 6000; i++)); do if [[ -n ${FAKE_UDP_CHILD_WAIT_FD:-} ]]; then read -r -t 0.05 _ <&"$FAKE_UDP_CHILD_WAIT_FD" || :; else /bin/sleep 0.05; fi; done' &
  child_pid=$!
  /usr/bin/env --default-signal=INT --default-signal=TERM --default-signal=HUP /bin/bash -c 'record_signal() { trap "" INT TERM HUP; [[ -z ${FAKE_UDP_SIGNAL_DELIVERED_FILE:-} ]] || printf "%s:%s\n" "$1" "$BASHPID" >>"$FAKE_UDP_SIGNAL_DELIVERED_FILE"; case "$1" in INT) exit "${FAKE_UDP_INT_EXIT:-130}";; TERM) exit "${FAKE_UDP_TERM_EXIT:-143}";; HUP) exit "${FAKE_UDP_HUP_EXIT:-129}";; esac; }; trap "record_signal INT" INT; trap "record_signal TERM" TERM; trap "record_signal HUP" HUP; count=0; for fd in /proc/$$/fd/*; do target=$(readlink -- "$fd" 2>/dev/null || true); [[ "$target" == "${FAKE_LOCK_PATH:-}" ]] && count=$((count + 1)); done; printf "%s\n" "$count" >"$FAKE_UDP_GRANDCHILD_FD_FILE"; printf "%s\n" "$BASHPID" >>"$FAKE_UDP_GRANDCHILD_PID_FILE"; for ((i = 0; i < 6000; i++)); do if [[ -n ${FAKE_UDP_GRANDCHILD_WAIT_FD:-} ]]; then read -r -t 0.05 _ <&"$FAKE_UDP_GRANDCHILD_WAIT_FD" || :; else /bin/sleep 0.05; fi; done' &
  grandchild_pid=$!
  printf '%s\n%s\n' "$child_pid" "$grandchild_pid" >"${FAKE_UDP_DESCENDANT_PID_FILE:?}"
  diagnostic_process worker-start "$$"
  diagnostic_process child-start "$child_pid"
  diagnostic_process grandchild-start "$grandchild_pid"
  for ((i = 0; i < 6000; i++)); do if [[ -n ${FAKE_UDP_WAIT_FD:-} ]]; then read -r -t 0.05 _ <&"$FAKE_UDP_WAIT_FD" || :; else /bin/sleep 0.05; fi; done
fi
printf 'echo: %s\n' "${2:?message required}"
EOF

cat >"$FAKE_BIN/mktemp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 2 && $1 == -d ]] || {
  printf 'fake mktemp refused unsafe argument layout\n' >&2
  exit 64
}
case "$2" in
  /tmp/frp-xudp-smoke.XXXXXX) prefix=/tmp/frp-xudp-smoke.; record_current=1 ;;
  /tmp/frp-xudp-recovery-marker.XXXXXX) prefix=/tmp/frp-xudp-recovery-marker. ;;
  *)
    printf 'fake mktemp refused unsafe template: %q\n' "$2" >&2
    exit 64
    ;;
esac
path=$("${REAL_MKTEMP:?}" "$@") || exit $?
[[ "$path" =~ ^${prefix//./\.}[A-Za-z0-9]{6}$ ]] || {
  printf 'fake mktemp produced unsafe path: %q\n' "$path" >&2
  exit 65
}
[[ -d "$path" && ! -L "$path" ]] || exit 66
[[ "$(${REAL_STAT:?} -c '%u %a' -- "$path")" == "$(id -u) 700" ]] || exit 67
if [[ ${record_current:-0} == 1 ]]; then
  printf '%s\n' "$path" >"${FAKE_STATE_DIR:?}/current-runtime"
fi
printf '%s\n' "$path"
EOF

cat >"$FAKE_BIN/rm" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 3 && ( $1 == -rf || $1 == -f ) && $2 == -- ]] || {
  printf 'fake rm refused unsafe argument layout\n' >&2
  exit 96
}
path=$3
if [[ $1 == -rf ]]; then
  [[ $path =~ ^/tmp/(frp-xudp-smoke|frp-xudp-recovery-marker)\.[A-Za-z0-9]{6}$ ]] || {
    printf 'fake rm refused unsafe path: %q\n' "$path" >&2
    exit 96
  }
  [[ -d "$path" && ! -L "$path" ]] || {
    printf 'fake rm refused non-directory or symlink: %q\n' "$path" >&2
    exit 97
  }
  [[ "$(${REAL_STAT:?} -c '%u' -- "$path")" == "$(id -u)" ]] || {
    printf 'fake rm refused unexpected owner: %q\n' "$path" >&2
    exit 98
  }
else
  if [[ $path =~ ^/tmp/frp-xudp-smoke\.[A-Za-z0-9]{6}/(bin/(frps|frpc|udp_send|udp_echo)|config/(frps\.toml|frpc\.toml|frpc-visitor\.toml)|log/(frps\.log|frpc\.log|frpc-visitor\.log|frpsA\.log|frpcB\.log|frpC\.log))$ ]]; then
    if [[ -e "$path" || -L "$path" ]]; then
      [[ -f "$path" && ! -L "$path" ]] || exit 97
      [[ "$("${REAL_STAT:?}" -c '%u %h' -- "$path")" == "$(id -u) 1" ]] || exit 98
    fi
  else
  [[ $path =~ ^/tmp/frp-xudp-recovery-marker\.[A-Za-z0-9]{6}/(ready|ready\.tmp\.[1-9][0-9]*|ready\.body\.[1-9][0-9]*)$ ]] || {
    printf 'fake rm refused unsafe marker leaf: %q\n' "$path" >&2
    exit 96
  }
  [[ -f "$path" && ! -L "$path" ]] || {
    printf 'fake rm refused non-regular marker leaf: %q\n' "$path" >&2
    exit 97
  }
  [[ "$(${REAL_STAT:?} -c '%u %h' -- "$path")" == "$(id -u) 1" ]] || {
    printf 'fake rm refused unexpected marker owner/link count: %q\n' "$path" >&2
    exit 98
  }
  fi
fi
printf '%s\n' "$path" >>"${FAKE_RM_LOG:?}"
count_file="${FAKE_STATE_DIR:?}/rm-call-count"
rm_call_count=0
[[ ! -e "$count_file" ]] || rm_call_count=$(<"$count_file")
rm_call_count=$((rm_call_count + 1))
printf '%d\n' "$rm_call_count" >"$count_file"
if [[ ${FAKE_RM_FAIL:-0} == 1 || ${FAKE_RM_FAIL_ON_CALL:-0} == "$rm_call_count" ]]; then
  retained="${FAKE_STATE_DIR:?}/retained-${BASHPID}"
  mv -- "$path" "$retained"
  printf '%s\n' "$retained" >"${FAKE_STATE_DIR}/last-retained"
  exit 77
fi
if [[ $1 == -rf ]]; then
  "${REAL_RM:?}" -rf -- "$path"
else
  "${REAL_RM:?}" -f -- "$path"
fi
[[ ! -e "$path" && ! -L "$path" ]] || exit 99
EOF

cat >"$FAKE_BIN/rmdir" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 2 && $1 == -- ]] || {
  printf 'fake rmdir refused unsafe argument layout\n' >&2
  exit 96
}
path=$2
[[ $path =~ ^/tmp/(frp-xudp-recovery-marker|frp-xudp-smoke)\.[A-Za-z0-9]{6}(/(bin|config|log))?$ ]] || {
  printf 'fake rmdir refused unsafe path: %q\n' "$path" >&2
  exit 96
}
[[ -d "$path" && ! -L "$path" ]] || exit 97
[[ "$(${REAL_STAT:?} -c '%u %a' -- "$path")" == "$(id -u) 700" ]] || exit 98
rmdir_log=${FAKE_RMDIR_LOG:-/dev/null}
real_rmdir=${REAL_RMDIR:-/usr/bin/rmdir}
printf '%s\n' "$path" >>"$rmdir_log"
if [[ ${FAKE_RMDIR_FAIL:-0} == 1 ]]; then
  exit 77
fi
"$real_rmdir" -- "$path"
[[ ! -e "$path" && ! -L "$path" ]]
EOF

cat >"$FAKE_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 1 && $1 == 3 ]]
EOF

printf 'fake-udp-echo\n' >"$FAKE_BIN/udp_echo"
chmod 0755 -- "$FAKE_BIN/docker" "$FAKE_BIN/timeout" "$FAKE_BIN/udp_send" \
  "$FAKE_BIN/mktemp" "$FAKE_BIN/rm" "$FAKE_BIN/rmdir" "$FAKE_BIN/sleep" "$FAKE_BIN/udp_echo"

cat >"$FAKE_BIN/flock" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 2 && $1 == -n ]] || exit 64
[[ $2 =~ ^[0-9]+$ && -d "/proc/$$/fd/$2" ]] || exit 65
[[ ${FAKE_FLOCK_BUSY:-0} != 1 ]]
EOF
cat >"$FAKE_BIN/stat" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 4 && ( $1 == -Lc || $1 == -c ) && $3 == -- ]] || exec "${REAL_STAT:?}" "$@"
path=$4
value=$("${REAL_STAT:?}" "$@")
owner_path="${FAKE_STATE_DIR:-}/runtime-owner-path-${FAKE_RUNTIME_MUTATION_ID:-}"
if [[ -n ${FAKE_RUNTIME_MUTATION_ID:-} && -f "$owner_path" &&
  "$path" == "$(<"$owner_path")" ]]; then
  case "$2" in
    '%d:%i|%F|%u|%h')
      IFS='|' read -r dev_inode kind owner links <<<"$value"
      printf '%s|%s|65534|%s\n' "$dev_inode" "$kind" "$links"
      exit 0
      ;;
    '%F|%u|%h')
      IFS='|' read -r kind owner links <<<"$value"
      printf '%s|65534|%s\n' "$kind" "$links"
      exit 0
      ;;
    '%u %h')
      read -r owner links <<<"$value"
      printf '65534 %s\n' "$links"
      exit 0
      ;;
  esac
fi
if [[ "$path" == "${FAKE_LOCK_PATH:-}" && "$1" == -Lc &&
  "$2" == '%d:%i %F %u %a' ]]; then
  read -r dev_inode kind owner mode <<<"$value"
  owner=${FAKE_LOCK_STAT_OWNER:-$owner}
  mode=${FAKE_LOCK_STAT_MODE:-$mode}
  printf '%s %s %s %s\n' "$dev_inode" "$kind" "$owner" "$mode"
  exit 0
fi
printf '%s\n' "$value"
EOF
chmod 0755 -- "$FAKE_BIN/flock" "$FAKE_BIN/stat"

FAKE_TMP_CONTRACT_HARNESS="$TEST_DIR/fake-tmp-contract-harness.sh"
FAKE_TMP_CONTRACT_RC_FILE="$TEST_DIR/fake-tmp-contract.rc"
FAKE_TMP_CONTRACT_DURATION_FILE="$TEST_DIR/fake-tmp-contract.duration_ms"
FAKE_TMP_CONTRACT_STATE="$FAKE_STATE/fake-tmp-contract-state"
mkdir -- "$FAKE_TMP_CONTRACT_STATE"
chmod 700 -- "$FAKE_TMP_CONTRACT_STATE"
cat >"$FAKE_TMP_CONTRACT_HARNESS" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

fake_mktemp=${FAKE_MKTEMP:?}
fake_rm=${FAKE_RM:?}
fake_rmdir=${FAKE_RMDIR:?}
real_mktemp=${REAL_MKTEMP:?}
real_rm=${REAL_RM:?}
real_rmdir=${REAL_RMDIR:?}
state=${FAKE_TMP_CONTRACT_STATE:?}
stage_file=${FAKE_TMP_CONTRACT_STAGE_FILE:?}

contract_fail() {
  printf 'fake_tmp_contract failure reason=%s\n' "$1" >&2
  exit 1
}

stage() {
  local value
  case ${1:-} in
    mktemp-smoke) value=mktemp-smoke ;;
    mktemp-marker) value=mktemp-marker ;;
    marker-files) value=marker-files ;;
    marker-rm) value=marker-rm ;;
    marker-rmdir) value=marker-rmdir ;;
    smoke-rm) value=smoke-rm ;;
    failed-marker-rm) value=failed-marker-rm ;;
    symlink) value=symlink ;;
    hardlink) value=hardlink ;;
    invalid-shapes) value=invalid-shapes ;;
    complete) value=complete ;;
    *) contract_fail invalid-stage ;;
  esac
  printf '%s\n' "$value" >"$stage_file"
}

require_private_dir() {
  local path=$1
  [[ "$path" =~ ^/tmp/(frp-xudp-smoke|frp-xudp-recovery-marker)\.[A-Za-z0-9]{6}$ ]] ||
    contract_fail invalid-private-dir-shape
  [[ -d "$path" && ! -L "$path" ]] || contract_fail invalid-private-dir-object
  [[ "$("${REAL_STAT:?}" -c '%u %a' -- "$path")" == "$(id -u) 700" ]] ||
    contract_fail invalid-private-dir-owner-mode
}

require_absent() {
  [[ ! -e "$1" && ! -L "$1" ]] || contract_fail path-not-removed
}

require_failed_marker_retained() {
  [[ ! -e "$1" && -f "$2" ]] || contract_fail failed-marker-not-retained
}

assert_rejected() {
  if "$@" >/dev/null 2>&1; then
    contract_fail rejected-shape-accepted
  fi
}

stage mktemp-smoke
smoke=$("$fake_mktemp" -d /tmp/frp-xudp-smoke.XXXXXX)
require_private_dir "$smoke"
stage mktemp-marker
marker=$("$fake_mktemp" -d /tmp/frp-xudp-recovery-marker.XXXXXX)
require_private_dir "$marker"
stage marker-files
printf 'ready\n' >"$marker/ready"
printf 'tmp\n' >"$marker/ready.tmp.17"
printf 'body\n' >"$marker/ready.body.23"

assert_rejected "$fake_mktemp" -d /tmp/frp-xudp-smoke.ABCDE
assert_rejected "$fake_mktemp" -d /tmp/frp-xudp-smoke.ABCDEFG
assert_rejected "$fake_mktemp" -d /tmp/frp-xudp-smoke.ABCDEF/child
assert_rejected "$fake_mktemp" -- -d /tmp/frp-xudp-smoke.XXXXXX
assert_rejected "$fake_mktemp" -d /tmp/frp-xudp-smoke.XXXXXX extra
assert_rejected "$fake_mktemp" -p /tmp/frp-xudp-smoke.XXXXXX

stage marker-rm
"$fake_rm" -f -- "$marker/ready"
"$fake_rm" -f -- "$marker/ready.tmp.17"
"$fake_rm" -f -- "$marker/ready.body.23"
printf '%s\n' "$marker" >"$state/rmdir.expected"
stage marker-rmdir
"$fake_rmdir" -- "$marker"
require_absent "$marker"
: >"$state/marker-removed"
stage smoke-rm
"$fake_rm" -rf -- "$smoke"
require_absent "$smoke"
: >"$state/smoke-removed"

failed_marker=$("$fake_mktemp" -d /tmp/frp-xudp-recovery-marker.XXXXXX)
printf 'failure\n' >"$failed_marker/ready"
{
  printf '%s\n' "$marker/ready"
  printf '%s\n' "$marker/ready.tmp.17"
  printf '%s\n' "$marker/ready.body.23"
  printf '%s\n' "$smoke"
  printf '%s\n' "$failed_marker/ready"
} >"$state/rm.expected"
stage failed-marker-rm
if FAKE_RM_FAIL=1 "$fake_rm" -f -- "$failed_marker/ready" >/dev/null 2>&1; then
  contract_fail failed-marker-rm-accepted
fi
failed_retained=$(<"${FAKE_STATE_DIR:?}/last-retained")
require_failed_marker_retained "$failed_marker/ready" "$failed_retained"
: >"$state/failure-visible"
"$real_rm" -f -- "$failed_retained"
"$real_rmdir" -- "$failed_marker"

invalid_base=$("$real_mktemp" -d /tmp/frp-xudp-fake-rm.XXXXXX)
invalid_marker=$("$fake_mktemp" -d /tmp/frp-xudp-recovery-marker.XXXXXX)
symlink_path=
hardlink_path=
extra_path=
trap '"$real_rm" -rf -- "$invalid_base" "$invalid_marker" 2>/dev/null || true' EXIT
symlink_path=$invalid_marker/ready
hardlink_path=$invalid_marker/ready.tmp.31
extra_path=$invalid_marker/unknown
ln -s -- "$invalid_base" "$symlink_path"
printf 'hardlink-source\n' >"$invalid_base/source"
ln -- "$invalid_base/source" "$hardlink_path"
printf 'unknown\n' >"$extra_path"
stage symlink
assert_rejected "$fake_rm" -f -- "$symlink_path"
: >"$state/symlink-rejected"
stage hardlink
assert_rejected "$fake_rm" -f -- "$hardlink_path"
: >"$state/hardlink-rejected"
stage invalid-shapes
assert_rejected "$fake_rm" -f -- "$extra_path"
assert_rejected "$fake_rm" -f -- "$invalid_marker/ready.tmp.0"
assert_rejected "$fake_rm" -f -- /tmp/frp-xudp-recovery-marker.ABCDE/ready
assert_rejected "$fake_rm" -f -- /tmp/frp-xudp-recovery-marker.ABCDEFG/ready
assert_rejected "$fake_rm" -f -- '/tmp/frp-xudp-recovery-marker.*'/ready
: >"$state/invalid-rejected"
stage complete
EOF
chmod 0700 -- "$FAKE_TMP_CONTRACT_HARNESS"

FAKE_TMP_CONTRACT_STAGE_FILE="$FAKE_TMP_CONTRACT_STATE/stage"
FAKE_TMP_CONTRACT_STDOUT_FILE="$FAKE_TMP_CONTRACT_STATE/stdout"
FAKE_TMP_CONTRACT_STDERR_FILE="$FAKE_TMP_CONTRACT_STATE/stderr"
if ! fake_tmp_contract_start_ms=$(epoch_ms_from_bash); then
  exit 1
fi
set +e
/usr/bin/timeout --foreground 10s env \
  "FAKE_MKTEMP=$FAKE_BIN/mktemp" "FAKE_RM=$FAKE_BIN/rm" \
  "FAKE_RMDIR=$FAKE_BIN/rmdir" "REAL_MKTEMP=$REAL_MKTEMP" "REAL_RM=$REAL_RM" \
  "REAL_RMDIR=$REAL_RMDIR" "REAL_STAT=$REAL_STAT" "FAKE_RMDIR_LOG=$FAKE_TMP_CONTRACT_STATE/rmdir.log" \
  "FAKE_RM_LOG=$FAKE_TMP_CONTRACT_STATE/rm.log" "FAKE_STATE_DIR=$FAKE_STATE" \
  "FAKE_TMP_CONTRACT_STATE=$FAKE_TMP_CONTRACT_STATE" \
  "FAKE_TMP_CONTRACT_STAGE_FILE=$FAKE_TMP_CONTRACT_STAGE_FILE" \
  bash "$FAKE_TMP_CONTRACT_HARNESS" >"$FAKE_TMP_CONTRACT_STDOUT_FILE" \
  2>"$FAKE_TMP_CONTRACT_STDERR_FILE"
fake_tmp_contract_rc=$?
set -e
if ! fake_tmp_contract_end_ms=$(epoch_ms_from_bash); then
  exit 1
fi
if (( fake_tmp_contract_end_ms < fake_tmp_contract_start_ms )); then
  printf 'xudp-init-assertion-failed reason=fake_tmp_contract_clock_reversed\n' >&2
  exit 1
fi
fake_tmp_contract_duration_ms=$((fake_tmp_contract_end_ms - fake_tmp_contract_start_ms))
printf '%s\n' "$fake_tmp_contract_rc" >"$FAKE_TMP_CONTRACT_RC_FILE"
printf '%s\n' "$fake_tmp_contract_duration_ms" >"$FAKE_TMP_CONTRACT_DURATION_FILE"
if ! [[ $fake_tmp_contract_rc == 0 && $fake_tmp_contract_duration_ms -le 10000 ]]; then
  fake_tmp_contract_last_stage=none
  if [[ -s "$FAKE_TMP_CONTRACT_STAGE_FILE" ]]; then
    fake_tmp_contract_last_stage=$(sed -n '1p' -- "$FAKE_TMP_CONTRACT_STAGE_FILE")
  fi
  printf 'xudp-init-assertion-failed reason=fake_tmp_contract_result rc=%s duration_ms=%s last_stage=%s\n' \
    "$fake_tmp_contract_rc" "$fake_tmp_contract_duration_ms" "$fake_tmp_contract_last_stage" >&2
  for fake_tmp_contract_output in stdout stderr; do
    fake_tmp_contract_output_file="$FAKE_TMP_CONTRACT_STATE/$fake_tmp_contract_output"
    printf 'fake_tmp_contract_%s_begin\n' "$fake_tmp_contract_output" >&2
    if [[ -f "$fake_tmp_contract_output_file" ]]; then
      LC_ALL=C head -c 8192 -- "$fake_tmp_contract_output_file" |
        tr -c '[:print:]\n\t' '?' | sed -n '1,64p' >&2 || true
    fi
    printf 'fake_tmp_contract_%s_end\n' "$fake_tmp_contract_output" >&2
  done
  exit 1
fi
if ! [[ $(<"$FAKE_TMP_CONTRACT_STAGE_FILE") == complete ]]; then
  printf 'xudp-init-assertion-failed reason=fake_tmp_contract_stage\n' >&2
  exit 1
fi
if ! [[ $(<"$FAKE_TMP_CONTRACT_STATE/marker-removed") == '' ]]; then
  printf 'xudp-init-assertion-failed reason=marker_removed\n' >&2
  exit 1
fi
if ! [[ $(<"$FAKE_TMP_CONTRACT_STATE/smoke-removed") == '' ]]; then
  printf 'xudp-init-assertion-failed reason=smoke_removed\n' >&2
  exit 1
fi
if ! [[ $(<"$FAKE_TMP_CONTRACT_STATE/symlink-rejected") == '' ]]; then
  printf 'xudp-init-assertion-failed reason=symlink_rejected\n' >&2
  exit 1
fi
if ! [[ $(<"$FAKE_TMP_CONTRACT_STATE/hardlink-rejected") == '' ]]; then
  printf 'xudp-init-assertion-failed reason=hardlink_rejected\n' >&2
  exit 1
fi
if ! [[ $(<"$FAKE_TMP_CONTRACT_STATE/invalid-rejected") == '' ]]; then
  printf 'xudp-init-assertion-failed reason=invalid_rejected\n' >&2
  exit 1
fi

PASS_COUNT=0
# Ordinary mode has 103 executed pass() calls.  --isolated adds four
# hostile-root assertions, including the current-UID lock identity check,
# and therefore has 107; neither value is derived from PASS_COUNT at runtime.
EXPECTED_ORDINARY_PASS_COUNT=103
EXPECTED_ISOLATED_PASS_COUNT=107

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'ok %d - %s\n' "$PASS_COUNT" "$1"
}

require_contains() {
  local file=$1 pattern=$2
  grep -Eq -- "$pattern" "$file" || {
    printf 'missing pattern %q in %s\n' "$pattern" "$file" >&2
    sed -n '1,240p' "$file" >&2
    exit 1
  }
}

require_not_contains() {
  local file=$1 pattern=$2
  if grep -Eq -- "$pattern" "$file"; then
    printf 'unexpected pattern %q in %s\n' "$pattern" "$file" >&2
    sed -n '1,240p' "$file" >&2
    exit 1
  fi
}

rm_log_runtime_count() {
  grep -Ec -- '^/tmp/frp-xudp-smoke\.[A-Za-z0-9]{6}(/|$)' "$RM_LOG" || true
}

require_build_guard_docker_calls() {
  local calls=() expected_user expected_prefix
  expected_user="$(id -u):$(id -g)"
  expected_prefix="docker exec --user $expected_user -- frp-dev /bin/sh -c "
  mapfile -t calls <"$DOCKER_LOG"
  [[ ${#calls[@]} == 3 ]] || {
    printf 'expected exactly the build-guard Docker call set, got %d calls:\n' \
      "${#calls[@]}" >&2
    sed -n '1,240p' "$DOCKER_LOG" >&2
    exit 1
  }
  [[ ${calls[0]} == 'docker network inspect -- frp-test-net' ]] || {
    printf 'unexpected first build-guard Docker call: %s\n' "${calls[0]}" >&2
    exit 1
  }
  [[ ${calls[1]} == 'docker inspect -- frp-dev' ]] || {
    printf 'unexpected second build-guard Docker call: %s\n' "${calls[1]}" >&2
    exit 1
  }
  [[ ${calls[2]} == "$expected_prefix"* ]] || {
    printf 'unexpected third build-guard Docker call: %s\n' "${calls[2]}" >&2
    exit 1
  }
  [[ ${calls[2]} == *'mktemp -d /tmp/xudp-build.XXXXXX'* ]] || {
    printf 'build-guard Docker call did not request the private build directory: %s\n' \
      "${calls[2]}" >&2
    exit 1
  }
  [[ ${calls[2]} != *'go build'* && ${calls[2]} != *'docker cp'* &&
    ${calls[2]} != *'docker rm'* && ${calls[2]} != *'docker run'* &&
    ${calls[2]} != *'docker logs'* && ${calls[2]} != *'sha256sum'* &&
    ${calls[2]} != *'rm -rf'* ]] || {
    printf 'build-guard Docker call contains a forbidden post-guard operation: %s\n' \
      "${calls[2]}" >&2
    exit 1
  }
}

require_result_once() {
  local file=$1 status=$2 code=$3 count
  count=$(grep -c -- '^RESULT=' "$file" || true)
  [[ $count == 1 ]] || {
    printf 'expected exactly one RESULT line in %s, got %s\n' "$file" "$count" >&2
    sed -n '1,240p' "$file" >&2
    exit 1
  }
  require_contains "$file" "^RESULT=$status exit_code=$code( |$)"
}

recreate_prebuilt_static_contract() {
  local recovery=$RECOVERY rm_line provenance_line staged_line count=0 line
  grep -Eq 'PREBUILT_FRPS=\$\{FRP_XUDP_FRPS-' "$recovery"
  grep -Eq 'PREBUILT_FRPC=\$\{FRP_XUDP_FRPC-' "$recovery"
  grep -Eq 'count != 0 && count != 4' "$recovery"
  grep -Eq 'PREBUILT_ARTIFACT_MODE=1' "$recovery"
  grep -Eq 'copy_prebuilt_artifacts "\$bin_dir"' "$recovery"
  grep -Eq 'xudp_prebuilt_source_snapshot "\$source"' "$recovery"
  grep -Eq 'after=\$PREBUILT_SOURCE_SNAPSHOT' "$recovery"
  grep -Eq 'PREBUILT_SOURCE_HASH.*source_hash' "$recovery"
  grep -Eq 'mv -n -- "\$tmp" "\$final"' "$recovery"
  grep -Eq '\[\[ "\$parent" == /tmp \]\]' "$recovery"
  grep -Eq '\[\[ "\$real_parent" == /tmp && "\$mode" == 1777' "$recovery"
  grep -Eq 'staged_runtime_validate_file' "$recovery"
  grep -Eq 'staged_runtime_preflight.*refusing to remove old containers' "$recovery" ||
    grep -Eq 'staged runtime preflight failed; refusing to remove old containers' "$recovery"
  grep -Eq 'current_runtime_snapshot_static_files "\$bin_dir" "\$cfg_dir"' "$recovery"
  grep -Eq '^staged_runtime_preflight\(\)' "$recovery"
  grep -Eq 'staged_runtime_preflight "\$ACTIVE_TMP_DIR" "\$bin_dir" "\$cfg_dir" "\$log_dir"' "$recovery"
  grep -Fq 'current_runtime_verify_before_run || {' "$recovery"
  while IFS= read -r line; do
    [[ "$line" == *'docker exec --user "$HOST_UID:$HOST_GID" --'* ]] || {
      printf 'fallback docker exec lacks host UID/GID: %s\n' "$line" >&2
      return 1
    }
    count=$((count + 1))
  done < <(grep -F 'docker exec' "$recovery")
  [[ $count == 7 ]]
  rm_line=$(grep -n -m1 'docker rm -f -- "\$SERVER" "\$PROXY" "\$VISITOR"' "$recovery" | cut -d: -f1)
  provenance_line=$(grep -n -m1 'record_recreated_provenance "\$bin_dir" "\$cfg_dir"' "$recovery" | cut -d: -f1)
  staged_line=$(grep -n -m1 'staged_runtime_preflight "\$ACTIVE_TMP_DIR"' "$recovery" | cut -d: -f1)
  [[ "$rm_line" =~ ^[0-9]+$ && "$provenance_line" =~ ^[0-9]+$ &&
    "$staged_line" =~ ^[0-9]+$ && "$provenance_line" -lt "$staged_line" &&
    "$staged_line" -lt "$rm_line" ]]
  grep -Eq 'validate_recovery_marker_phase' "$recovery"
  grep -Fq 'local phase=$1 result_rc=$2 business_pid=$3 business_pgid=$4 business_starttime=$5' "$recovery"
  early_gate=$(grep -n -m1 'validate_prebuilt_artifact_selection_early' "$recovery" | cut -d: -f1)
  trap_line=$(grep -n -m1 '^trap on_exit EXIT$' "$recovery" | cut -d: -f1)
  [[ "$early_gate" =~ ^[0-9]+$ && "$trap_line" =~ ^[0-9]+$ && "$early_gate" -lt "$trap_line" ]]
}

recreate_prebuilt_static_contract

grep -Fq -- "! -name 'cache.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]'" \
  "$RECOVERY"
grep -Fq -- "printf '%s' \"\$create_info\" | awk -F'|'" "$RECOVERY"
grep -Fq -- "printf '%s' \"\$build_info\" | awk -F'|'" "$RECOVERY"
grep -Fq -- "read -r record_type artifact_name artifact_devino artifact_kind artifact_uid" "$RECOVERY"
for sh_cleanup_tag in FRP_XUDP_BUILD_CLEANUP FRP_XUDP_HELPER_CLEANUP; do
  sh_cleanup_payload=$(awk -v tag="$sh_cleanup_tag" '
    index($0, "<<\047" tag "\047") { capture=1; next }
    capture && $0 == tag { exit }
    capture { print }
  ' "$RECOVERY")
  [[ -n "$sh_cleanup_payload" && "$sh_cleanup_payload" != *'[['* ]]
done

assert_marker_entry_stat_parser_contract() {
  local marker_entry_function
  marker_entry_function=$(awk '
    /^  marker_entry_is_safe\(\)/ { capture=1 }
    capture { print }
    capture && /^  }$/ { exit }
  ' "$RECOVERY")
  [[ -n "$marker_entry_function" ]] || return 1
  grep -Fq "stat -Lc '%F|%u|%h'" <<<"$marker_entry_function"
  grep -Fq "IFS='|' read -r entry_kind entry_uid entry_links" <<<"$marker_entry_function"
  ! grep -Fq "stat -Lc '%F %u %h'" <<<"$marker_entry_function"
}

assert_marker_entry_stat_parser_contract

assert_process_classifier_preserves_disappearance_rc() {
  local classifier probe rc
  classifier=$(awk '
    /^classify_process\(\)/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "$RECOVERY")
  [[ -n "$classifier" ]] || return 1
  probe=$($REAL_MKTEMP /tmp/frp-process-classifier.XXXXXX)
  {
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'proc_snapshot() { return 2; }'
    printf '%s\n' "$classifier"
    printf '%s\n' 'set +e'
    printf '%s\n' 'classify_process "$$"'
    printf '%s\n' 'rc=$?'
    printf '%s\n' 'set -e'
    printf '%s\n' 'printf "%s\\n" "$rc"'
  } >"$probe"
  rc=$(bash "$probe")
  "$REAL_RM" -f -- "$probe"
  [[ "$rc" == 2 ]]
}

assert_process_classifier_preserves_disappearance_rc
pass 'process classifier preserves known disappearance during teardown'

assert_wait_for_process_exit_survives_set_e_poll() {
  local waiter probe fake_ps rc
  waiter=$(awk '
    /^wait_for_process_exit\(\)/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${BASH_SOURCE[0]}")
  [[ -n "$waiter" ]] || return 1
  probe=$($REAL_MKTEMP /tmp/frp-wait-for-process-exit.XXXXXX)
  fake_ps=$($REAL_MKTEMP /tmp/frp-wait-for-process-exit-ps.XXXXXX)
  printf '#!/usr/bin/env bash\nprintf "S\\n"\n' >"$fake_ps"
  chmod 700 -- "$fake_ps"
  {
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'REAL_PS=$1 REAL_TR=/usr/bin/tr TEST_WAIT_FD=0'
    printf '%s\n' 'calls=0'
    printf '%s\n' 'kill() { if [[ $1 == -0 ]]; then if (( calls < 2 )); then calls=$((calls + 1)); return 0; fi; return 1; fi; return 2; }'
    printf '%s\n' 'test_cleanup_tick() { :; }'
    printf '%s\n' "$waiter"
    printf '%s\n' 'wait_for_process_exit 9001'
    printf '%s\n' 'printf "wait_rc=0 calls=%s\\n" "$calls"'
  } >"$probe"
  rc=$(bash "$probe" "$fake_ps")
  "$REAL_RM" -f -- "$probe" "$fake_ps"
  [[ "$rc" == 'wait_rc=0 calls=2' ]]
}

assert_wait_for_process_exit_survives_set_e_poll
pass 'worker exit polling remains bounded under set -e'

assert_proc_disappearance_is_known_exit_contract() {
  local process_state group_state group_owner
  process_state=$(awk '
    /^test_process_state\(\)/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${BASH_SOURCE[0]}")
  group_state=$(awk '
    /^test_group_state\(\)/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${BASH_SOURCE[0]}")
  group_owner=$(awk '
    /^test_group_owned_by_registered_process\(\)/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${BASH_SOURCE[0]}")
  grep -Fq '[[ ! -e "/proc/$pid/stat" ]] && return 1' <<<"$process_state"
  grep -Fq '[[ ! -e "$entry/stat" ]] && continue' <<<"$group_state"
  grep -Fq '[[ ! -e "$entry/stat" ]] && continue' <<<"$group_owner"
  grep -Fq 'return 2' <<<"$process_state"
  grep -Fq 'return 2' <<<"$group_state"
  grep -Fq 'unknown=1' <<<"$group_owner"
}

assert_proc_disappearance_is_known_exit_contract
pass 'registered worker proc disappearance is known exit, unreadable proc remains fail-closed'

assert_outer_proc_snapshot_and_group_race_contract() {
  local outer_snapshot outer_group inner_group probe fixture_root group_block inner_block output
  outer_snapshot=$(awk '
    /^proc_snapshot\(\)/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "$RECOVERY")
  outer_group=$(awk '
    /^outer_group_state\(\)/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "$RECOVERY")
  inner_group=$(awk '
    /^    classify_group\(\)/ { capture=1 }
    capture {
      if ($0 ~ /^    }$/) { sub(/^    /, ""); print; exit }
      sub(/^    /, ""); print
    }
  ' "$RECOVERY")
  [[ -n "$outer_snapshot" && -n "$outer_group" && -n "$inner_group" ]] || return 1
  grep -Fq 'exec {proc_stat_fd}<"/proc/$pid/stat"' <<<"$outer_snapshot"
  grep -Fq '[[ ! -e "/proc/$pid/stat" ]] && return 2' <<<"$outer_snapshot"
  grep -Fq '[[ $snapshot_rc == 2 ]] && continue' <<<"$outer_group"
  grep -Fq '[[ $snapshot_rc == 2 ]] && continue' <<<"$inner_group"
  fixture_root=$($REAL_MKTEMP -d /tmp/frp-outer-proc-race.XXXXXX)
  mkdir -p -- "$fixture_root/100" "$fixture_root/200"
  : >"$fixture_root/100/stat"
  : >"$fixture_root/200/stat"
  group_block=$(sed "s#/proc/\\[0-9\\]\\*#${fixture_root}/[0-9]*#" <<<"$outer_group")
  inner_block=$(sed "s#/proc/\\[0-9\\]\\*#${fixture_root}/[0-9]*#" <<<"$inner_group")
  probe=$($REAL_MKTEMP /tmp/frp-outer-proc-race-probe.XXXXXX)
  {
    printf '%s\n' 'set -Eeuo pipefail'
    printf 'fixture_root=%q\n' "$fixture_root"
    printf '%s\n' 'mode=disappeared'
    printf '%s\n' 'proc_snapshot() {'
    printf '%s\n' '  case "$mode:$1" in'
    printf '%s\n' '    disappeared:100) PROC_PGID=100; PROC_STATE=S; PROC_STARTTIME=111; return 0 ;;'
    printf '%s\n' '    disappeared:200) rm -f -- "$fixture_root/200/stat"; return 2 ;;'
    printf '%s\n' '    unknown:100) PROC_PGID=100; PROC_STATE=S; PROC_STARTTIME=111; return 0 ;;'
    printf '%s\n' '    unknown:200) return 3 ;;'
    printf '%s\n' '    *) return 3 ;;'
    printf '%s\n' '  esac'
    printf '%s\n' '}'
    printf '%s\n' "$group_block"
    printf '%s\n' "$inner_block"
    printf '%s\n' 'outer_group_state 100; disappeared_outer_rc=$?'
    printf '%s\n' 'classify_group 100; disappeared_inner_rc=$?'
    printf '%s\n' 'printf "disappeared_outer_rc=%s disappeared_inner_rc=%s\n" "$disappeared_outer_rc" "$disappeared_inner_rc"'
    printf '%s\n' ': >"$fixture_root/200/stat"'
    printf '%s\n' 'mode=unknown'
    printf '%s\n' 'if outer_group_state 100; then unknown_outer_rc=0; else unknown_outer_rc=$?; fi'
    printf '%s\n' 'if classify_group 100; then unknown_inner_rc=0; else unknown_inner_rc=$?; fi'
    printf '%s\n' 'printf "unknown_outer_rc=%s unknown_inner_rc=%s\n" "$unknown_outer_rc" "$unknown_inner_rc"'
  } >"$probe"
  set +e
  output=$(bash "$probe" 2>&1)
  local rc=$?
  set -e
  "$REAL_RM" -f -- "$probe"
  "$REAL_RM" -rf -- "$fixture_root"
  (( rc == 0 )) || { printf '%s\n' "$output" >&2; return 1; }
  [[ "$output" == *'disappeared_outer_rc=0 disappeared_inner_rc=0'* &&
    "$output" == *'unknown_outer_rc=3 unknown_inner_rc=3'* ]]
}

assert_outer_proc_snapshot_and_group_race_contract
pass 'A ignores only disappeared unrelated proc entries and keeps unknown group state fail-closed'

assert_outer_proc_snapshot_failure_classes() {
  local snapshot probe fixture_root valid_line output rc snapshot_block
  snapshot_block=$(awk '
    /^proc_snapshot\(\)/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "$RECOVERY")
  [[ -n "$snapshot_block" ]] || return 1
  fixture_root=$($REAL_MKTEMP -d /tmp/frp-proc-snapshot-classes.XXXXXX)
  valid_line=$(<"/proc/$$/stat")
  snapshot_block=$(sed "s#/proc/#${fixture_root}/#g" <<<"$snapshot_block")
  probe=$($REAL_MKTEMP /tmp/frp-proc-snapshot-classes-probe.XXXXXX)
  {
    printf '%s\n' 'set -Eeuo pipefail'
    printf 'fixture_root=%q\nvalid_line=%q\n' "$fixture_root" "$valid_line"
    printf '%s\n' "$snapshot_block"
    printf '%s\n' 'mkdir -p "$fixture_root/100"'
    printf '%s\n' 'printf "%s\n" "$valid_line" >"$fixture_root/100/stat"'
    printf '%s\n' 'if proc_snapshot 100; then valid_rc=0; else valid_rc=$?; fi'
    printf '%s\n' 'rm -f -- "$fixture_root/100/stat"'
    printf '%s\n' 'if proc_snapshot 100; then missing_rc=0; else missing_rc=$?; fi'
    printf '%s\n' 'printf "bad\n" >"$fixture_root/100/stat"'
    printf '%s\n' 'if proc_snapshot 100; then malformed_rc=0; else malformed_rc=$?; fi'
    printf '%s\n' 'rm -f -- "$fixture_root/100/stat"; mkdir -- "$fixture_root/100/stat"'
    printf '%s\n' 'kill() { return 0; }'
    printf '%s\n' 'if proc_snapshot 100; then unreadable_rc=0; else unreadable_rc=$?; fi'
    printf '%s\n' 'printf "valid=%s missing=%s malformed=%s unreadable=%s\n" "$valid_rc" "$missing_rc" "$malformed_rc" "$unreadable_rc"'
  } >"$probe"
  set +e
  output=$(bash "$probe" 2>&1)
  rc=$?
  set -e
  "$REAL_RM" -f -- "$probe"
  "$REAL_RM" -rf -- "$fixture_root"
  (( rc == 0 )) || { printf '%s\n' "$output" >&2; return 1; }
  [[ "$output" == *'valid=0 missing=2 malformed=3 unreadable=3'* ]]
}

assert_outer_proc_snapshot_failure_classes
pass 'A proc snapshot keeps missing, malformed and unreadable return codes distinct'

assert_outer_leader_revalidation_before_signal() {
  local flush probe fixture_root output rc
  flush=$(awk '
    /^outer_flush_pending_signals\(\)/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "$RECOVERY")
  [[ -n "$flush" ]] || return 1
  fixture_root=$($REAL_MKTEMP -d /tmp/frp-leader-revalidation.XXXXXX)
  probe=$($REAL_MKTEMP /tmp/frp-leader-revalidation-probe.XXXXXX)
  {
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'INNER_PID=100 INNER_PGID=100 INNER_STARTTIME=111 OUTER_PENDING_SIGNALS=(INT)'
    printf '%s\n' 'outer_group_state() { return 0; }'
    printf '%s\n' 'kill_called=0 calls=0 mode=gone'
    printf '%s\n' 'proc_snapshot() { calls=$((calls + 1)); if (( calls == 1 )); then PROC_PGID=100; PROC_STARTTIME=111; PROC_STATE=S; return 0; fi; if [[ "$mode" == gone ]]; then return 2; fi; PROC_PGID=100; PROC_STARTTIME=222; PROC_STATE=S; return 0; }'
    printf '%s\n' 'kill() { kill_called=1; return 0; }'
    printf '%s\n' "$flush"
    printf '%s\n' 'if outer_flush_pending_signals; then gone_rc=0; else gone_rc=$?; fi'
    printf '%s\n' 'printf "gone_rc=%s gone_kill=%s\n" "$gone_rc" "$kill_called"'
    printf '%s\n' 'OUTER_PENDING_SIGNALS=(INT); calls=0; kill_called=0; mode=reused'
    printf '%s\n' 'if outer_flush_pending_signals; then reused_rc=0; else reused_rc=$?; fi'
    printf '%s\n' 'printf "reused_rc=%s reused_kill=%s\n" "$reused_rc" "$kill_called"'
  } >"$probe"
  set +e
  output=$(bash "$probe" 2>&1)
  rc=$?
  set -e
  "$REAL_RM" -f -- "$probe"
  "$REAL_RM" -rf -- "$fixture_root"
  (( rc == 0 )) || { printf '%s\n' "$output" >&2; return 1; }
  [[ "$output" == *'gone_rc=1 gone_kill=0'* &&
    "$output" == *'reused_rc=1 reused_kill=0'* ]]
}

assert_outer_leader_revalidation_before_signal
pass 'A revalidates leader identity after the group scan before INT/TERM/HUP delivery'

assert_wrapper_identity_ignores_transient_state() {
  local wrapper probe fixture_root output rc source=${RECOVERY_TEST_SOURCE:-${BASH_SOURCE[0]}}
  wrapper=$(awk '
    /^stable_wrapper_identity\(\)/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "$source")
  [[ -n "$wrapper" ]] || return 1
  grep -Fq 'first="$target:$PROC_PGID:$PROC_STARTTIME"' <<<"$wrapper"
  grep -Fq 'second="$target:$PROC_PGID:$PROC_STARTTIME"' <<<"$wrapper"
  ! grep -Fq 'first="$target:$PROC_PGID:$PROC_STARTTIME:$PROC_STATE"' <<<"$wrapper"
  fixture_root=$($REAL_MKTEMP -d /tmp/frp-wrapper-identity.XXXXXX)
  printf '1000\n' >"$fixture_root/pid"
  printf '1000\n' >"$fixture_root/pgid"
  printf '12345\n' >"$fixture_root/starttime"
  probe=$($REAL_MKTEMP /tmp/frp-wrapper-identity-probe.XXXXXX)
  {
    printf '%s\n' 'set -Eeuo pipefail'
    printf 'pid_file=%q pgid_file=%q starttime_file=%q\n' \
      "$fixture_root/pid" "$fixture_root/pgid" "$fixture_root/starttime"
    printf '%s\n' 'caller_pid=2000 suite_pid=3000'
    printf '%s\n' 'authority_fail() { return 1; }'
    printf '%s\n' 'protected_pgid() { return 0; }'
    printf '%s\n' 'snapshot_calls=0'
    printf '%s\n' 'proc_snapshot() { snapshot_calls=$((snapshot_calls + 1)); PROC_PGID=1000; PROC_STARTTIME=12345; if (( snapshot_calls == 1 )); then PROC_STATE=S; else PROC_STATE="S<"; fi; }'
    printf '%s\n' "$wrapper"
    printf '%s\n' 'stable_wrapper_identity test-wrapper'
    printf 'printf "wrapper_rc=0 pid=%%s pgid=%%s start=%%s calls=%%s\\n" "$WRAPPER_PID" "$WRAPPER_PGID" "$WRAPPER_STARTTIME" "$snapshot_calls"\n'
  } >"$probe"
  set +e
  output=$(bash "$probe" 2>&1)
  rc=$?
  set -e
  "$REAL_RM" -f -- "$probe"
  "$REAL_RM" -rf -- "$fixture_root"
  (( rc == 0 )) || { printf '%s\n' "$output" >&2; return 1; }
  [[ "$output" == *'wrapper_rc=0 pid=1000 pgid=1000 start=12345 calls=2'* ]]
}

assert_wrapper_identity_ignores_transient_state
pass 'wrapper identity ignores transient proc state while binding PID/PGID/starttime'

assert_register_test_child_requires_registered_pid() {
  local child_block probe rc
  child_block=$(awk '
    /^register_test_child\(\)/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${BASH_SOURCE[0]}")
  [[ "$child_block" == *'register_test_pid "$pid" || return'* ]] || return 1
  probe=$($REAL_MKTEMP /tmp/frp-register-test-child.XXXXXX)
  {
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'TEST_CHILD_PIDS=()'
    printf '%s\n' 'register_test_pid() { return 1; }'
    printf '%s\n' "$child_block"
    printf '%s\n' 'set +e; register_test_child 9001; rc=$?; set -e'
    printf '%s\n' '[[ $rc == 1 && ${#TEST_CHILD_PIDS[@]} == 0 ]]'
    printf '%s\n' 'register_test_pid() { return 0; }'
    printf '%s\n' 'register_test_child 9002'
    printf '%s\n' '[[ ${#TEST_CHILD_PIDS[@]} == 1 && ${TEST_CHILD_PIDS[0]} == 9002 ]]'
  } >"$probe"
  if bash "$probe"; then rc=0; else rc=$?; fi
  "$REAL_RM" -f -- "$probe"
  return "$rc"
}

assert_register_test_child_requires_registered_pid
pass 'direct-child registry appends only after PID identity registration succeeds'

assert_bounded_child_registration_contract() {
  local helper_block terminal_block probe rc
  helper_block=$(awk '
    /^register_test_child_bounded\(\)/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${BASH_SOURCE[0]}")
  terminal_block=$(awk '
    /^test_child_registration_terminal\(\)/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${BASH_SOURCE[0]}")
  [[ -n "$helper_block" && -n "$terminal_block" &&
    "$helper_block" == *'attempt <= 300'* &&
    "$helper_block" == *'test_cleanup_tick'* &&
    "$helper_block" == *'TEST_CHILD_PIDS'* &&
    "$helper_block" == *'TEST_PID_STARTTIME'* &&
    "$helper_block" == *'TEST_PID_PGID'* ]] || return 1
  probe=$($REAL_MKTEMP /tmp/frp-register-test-child-bounded.XXXXXX)
  {
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'REAL_PS=/bin/ps REAL_TR=/usr/bin/tr TEST_SHELL_PGID=999999 TEST_CALLER_PGID=999998'
    printf '%s\n' 'declare -a TEST_PIDS=() TEST_CHILD_PIDS=() TEST_PGIDS=() TEST_PROTECTED_PIDS=()'
    printf '%s\n' 'declare -A TEST_PID_STARTTIME=() TEST_PID_PGID=()'
    printf '%s\n' 'test_pid_protected() { return 1; }'
    printf '%s\n' 'test_cleanup_tick() { ((ticks += 1)); }'
    printf '%s\n' 'report_test_pid_identity() { :; }'
    printf '%s\n' "$terminal_block"
    printf '%s\n' 'test_child_registration_terminal() { return 1; }'
    printf '%s\n' "$helper_block"
    printf '%s\n' 'ticks=0 calls=0 mode=retry'
    printf '%s\n' 'register_test_child() { calls=$((calls + 1)); if [[ $mode == retry && $calls == 1 ]]; then return 1; fi; TEST_PIDS+=(9002); TEST_CHILD_PIDS+=(9002); TEST_PGIDS+=(9002); TEST_PID_STARTTIME[9002]=12; TEST_PID_PGID[9002]=9002; return 0; }'
    printf '%s\n' 'register_test_child_bounded 9002 first-retry'
    printf '%s\n' '[[ $calls == 2 && $ticks == 1 && ${#TEST_PIDS[@]} == 1 && ${#TEST_CHILD_PIDS[@]} == 1 && ${#TEST_PGIDS[@]} == 1 && ${TEST_CHILD_PIDS[0]} == 9002 && ${TEST_PID_STARTTIME[9002]} == 12 && ${TEST_PID_PGID[9002]} == 9002 ]]'
    printf '%s\n' 'TEST_PIDS=() TEST_CHILD_PIDS=() TEST_PGIDS=(); TEST_PID_STARTTIME=(); TEST_PID_PGID=(); ticks=0; calls=0; mode=always-fail'
    printf '%s\n' 'register_test_child() { calls=$((calls + 1)); TEST_PIDS+=(9002); TEST_CHILD_PIDS+=(9002); TEST_PGIDS+=(9002); TEST_PID_STARTTIME[9002]=12; TEST_PID_PGID[9002]=9002; return 1; }'
    printf '%s\n' 'set +e; register_test_child_bounded 9002 always-fail; rc=$?; set -e'
    printf '%s\n' '[[ $rc == 1 && $calls == 300 && $ticks == 300 && ${#TEST_PIDS[@]} == 0 && ${#TEST_CHILD_PIDS[@]} == 0 && ${#TEST_PGIDS[@]} == 0 && ${TEST_PID_STARTTIME[9002]+present} != present && ${TEST_PID_PGID[9002]+present} != present ]]'
    printf '%s\n' 'TEST_PIDS=(9002) TEST_CHILD_PIDS=(9002) TEST_PGIDS=(9002); TEST_PID_STARTTIME=([9002]=12); TEST_PID_PGID=([9002]=9002); ticks=0; calls=0; mode=duplicate'
    printf '%s\n' 'register_test_child_bounded 9002 already-registered'
    printf '%s\n' '[[ $calls == 0 && $ticks == 0 && ${#TEST_CHILD_PIDS[@]} == 1 && ${TEST_CHILD_PIDS[0]} == 9002 ]]'
  } >"$probe"
  if bash "$probe" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  "$REAL_RM" -f -- "$probe"
  return "$rc"
}

assert_bounded_child_registration_contract
pass 'bounded direct-child registration retries atomically, fails closed, and stays idempotent'

assert_bounded_child_registration_call_sites() {
  local source=${BASH_SOURCE[0]}
  grep -Fq 'register_test_process_bounded "$term_sentinel"' "$source"
  grep -Fq 'register_test_process_bounded "$hold_outer"' "$source"
  grep -Fq 'register_test_process_bounded "$hup_sentinel"' "$source"
  grep -Fq 'register_test_process_bounded "$hup_outer"' "$source"
  grep -Fq 'register_test_process_bounded "$int_sentinel"' "$source"
  grep -Fq 'register_test_process_bounded "$int_outer"' "$source"
  grep -Fq 'register_test_process_bounded "$int_sender"' "$source"
  grep -Fq 'register_test_process_bounded "$int_watchdog_pid"' "$source"
  grep -Fq 'wait_for_int_supervisor_ready' "$source"
  grep -Fq 'INT_MARKER_DIRS_BEFORE' "$source"
  grep -Fq '/usr/bin/setsid "$int_signaler"' "$source"
  grep -Fq '/usr/bin/setsid "$int_watchdog"' "$source"
}

assert_bounded_child_registration_call_sites
pass 'TERM/HUP recovery and sentinel direct-child call sites use checked bounded registration'

assert_int_checked_preserves_failure_rc() {
  local checked_block probe rc
  checked_block=$(awk '
    /^int_checked\(\)/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${BASH_SOURCE[0]}")
  [[ "$checked_block" == *'else'* && "$checked_block" == *'rc=$?'* ]] || return 1
  probe=$($REAL_MKTEMP /tmp/frp-int-checked-rc.XXXXXX)
  {
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'int_fixture_diagnostics() { :; }'
    printf '%s\n' "$checked_block"
    printf '%s\n' 'set +e; int_checked preserves-rc bash -c "exit 37"; rc=$?; set -e'
    printf '%s\n' '[[ $rc == 37 ]]'
  } >"$probe"
  if bash "$probe" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  "$REAL_RM" -f -- "$probe"
  return "$rc"
}

assert_int_checked_preserves_failure_rc
pass 'INT checked wrapper preserves non-zero command status'

assert_wait_for_int_outer_preserves_errexit_and_reaps_status() {
  local wait_block probe rc
  wait_block=$(awk '/^wait_for_int_outer_bounded\(\)/ { capture=1 } capture { print } capture && /^}$/ { exit }' "${BASH_SOURCE[0]}")
  [[ "$wait_block" == *'if wait "$pid"; then'* &&
    "$wait_block" == *'outer_rc=$?'* &&
    "$wait_block" != *'set +e'* && "$wait_block" != *'set -e'* ]] || return 1
  probe=$($REAL_MKTEMP /tmp/frp-int-outer-errexit.XXXXXX)
  {
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'declare -A TEST_CHILD_STATUS=() TEST_PID_STARTTIME=() TEST_PID_PGID=()'
    printf '%s\n' 'test_process_state() { return 1; }'
    printf '%s\n' 'test_cleanup_tick() { :; }'
    printf '%s\n' "$wait_block"
    printf '%s\n' 'on_ready=$(mktemp /tmp/frp-int-outer-on-ready.XXXXXX); /usr/bin/env --default-signal=INT /usr/bin/setsid /bin/sh -c '\''printf ready >"$1"; exec /bin/sleep 1'\'' sh "$on_ready" & pid_on=$!; for ((i = 0; i < 100; i++)); do [[ -s "$on_ready" ]] && break; /bin/sleep 0.01; done; [[ -s "$on_ready" ]]; /bin/rm -f -- "$on_ready"; kill -INT "$pid_on"'
    printf '%s\n' 'if wait_for_int_outer_bounded "$pid_on"; then on_rc=0; else on_rc=$?; fi'
    printf '%s\n' 'on_next=executed; case $- in *e*) on_errexit=on;; *) on_errexit=off;; esac'
    printf '%s\n' 'if wait "$pid_on"; then on_reap_rc=0; else on_reap_rc=$?; fi'
    printf '%s\n' 'set +e'
    printf '%s\n' 'off_ready=$(mktemp /tmp/frp-int-outer-off-ready.XXXXXX); /usr/bin/env --default-signal=INT /usr/bin/setsid /bin/sh -c '\''printf ready >"$1"; exec /bin/sleep 1'\'' sh "$off_ready" & pid_off=$!; for ((i = 0; i < 100; i++)); do [[ -s "$off_ready" ]] && break; /bin/sleep 0.01; done; [[ -s "$off_ready" ]]; /bin/rm -f -- "$off_ready"; kill -INT "$pid_off"'
    printf '%s\n' 'if wait_for_int_outer_bounded "$pid_off"; then off_rc=0; else off_rc=$?; fi'
    printf '%s\n' 'off_next=executed; case $- in *e*) off_errexit=on;; *) off_errexit=off;; esac'
    printf '%s\n' 'if wait "$pid_off"; then off_reap_rc=0; else off_reap_rc=$?; fi'
    printf '%s\n' 'printf "on=%s/%s/%s off=%s/%s/%s status=%s/%s\n" "$on_rc" "$on_next" "$on_errexit" "$off_rc" "$off_next" "$off_errexit" "${TEST_CHILD_STATUS[$pid_on]-missing}" "${TEST_CHILD_STATUS[$pid_off]-missing}"'
    printf '%s\n' 'on_active=no; off_active=no; jobs -pr | while IFS= read -r active_pid; do [[ $active_pid == "$pid_on" ]] && on_active=yes; [[ $active_pid == "$pid_off" ]] && off_active=yes; done'
    printf '%s\n' '[[ $on_rc == 130 && $on_next == executed && $on_errexit == on && $off_rc == 130 && $off_next == executed && $off_errexit == off && $on_active == no && $off_active == no && ${TEST_CHILD_STATUS[$pid_on]-missing} == 130 && ${TEST_CHILD_STATUS[$pid_off]-missing} == 130 ]]'
  } >"$probe"
  if bash "$probe" >"$probe.out" 2>&1; then rc=0; else rc=$?; fi
  if (( rc != 0 )); then
    sed -n '1,80p' -- "$probe.out" >&2
  fi
  "$REAL_RM" -f -- "$probe" "$probe.out"
  return "$rc"
}

assert_wait_for_int_outer_preserves_errexit_and_reaps_status
pass 'INT bounded wait preserves caller errexit state, reaps child, and returns real status'

assert_int_bounded_wait_and_stage_schema() {
  local source=${BASH_SOURCE[0]} wait_block signaler_block watchdog_block
  wait_block=$(awk '/^wait_for_int_outer_bounded\(\)/ { capture=1 } capture { print } capture && /^}$/ { exit }' "$source")
  signaler_block=$(awk '/^cat >"\$int_signaler"/ { capture=1 } capture { print } capture && /^EOF$/ { exit }' "$source")
  watchdog_block=$(awk '/^cat >"\$int_watchdog"/ { capture=1 } capture { print } capture && /^EOF$/ { exit }' "$source")
  [[ "$wait_block" == *'test_process_state'* && "$wait_block" == *'wait "$pid"'* &&
    "$wait_block" == *'return 124'* && "$wait_block" == *'for ((i = 0; i < 3000; i++))'* ]] || return 1
  [[ "$signaler_block" == *'phase=%s'* &&
    "$signaler_block" == *'release-consumed'* && "$signaler_block" == *'authority-validated'* &&
    "$signaler_block" == *'signal-sent'* && "$signaler_block" == *'failed:'* ]] || return 1
  [[ "$watchdog_block" == *'phase=%s'* &&
    "$watchdog_block" == *'release-consumed'* && "$watchdog_block" == *'timeout-actions'* ]] || return 1
}

assert_int_stage_update_contract() {
  local source=${BASH_SOURCE[0]} stage_block probe stage target rc
  stage_block=$(awk '
    /^cat >"\$int_signaler"/ { capture=1 }
    capture && /^atomic_stage\(\)/ { found=1 }
    found { print }
    found && /^}/ { exit }
  ' "$source")
  [[ "$stage_block" == *'[[ ! -L "$stage_marker" ]]'* &&
    "$stage_block" == *'|1|600'* &&
    "$stage_block" == *'mktemp -- "${stage_marker}.tmp.XXXXXX"'* &&
    "$stage_block" == *'mv -f -- "$tmp" "$stage_marker"'* ]] || return 1
  probe=$($REAL_MKTEMP /tmp/frp-stage-contract.XXXXXX)
  {
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'stage_marker=$1 handshake_token=token handshake_role=role'
    printf '%s\n' "$stage_block"
    printf '%s\n' 'atomic_stage release-consumed'
    printf '%s\n' 'atomic_stage authority-validated'
    printf '%s\n' '[[ $(awk -F= '\''$1 == "phase" { print $2 }'\'' "$stage_marker") == authority-validated ]]'
  } >"$probe"
  if bash "$probe" "$probe.stage" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  [[ "$rc" == 0 ]] || { "$REAL_RM" -f -- "$probe" "$probe.stage"; return 1; }
  printf 'token=other\nrole=role\nphase=old\n' >"$probe.stage"
  if bash "$probe" "$probe.stage" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  [[ "$rc" != 0 ]] || { "$REAL_RM" -f -- "$probe" "$probe.stage"; return 1; }
  printf 'token=token\nrole=role\nphase=old\n' >"$probe.stage"
  chmod 0640 -- "$probe.stage"
  if bash "$probe" "$probe.stage" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  [[ "$rc" != 0 ]] || { "$REAL_RM" -f -- "$probe" "$probe.stage"; return 1; }
  "$REAL_RM" -f -- "$probe.stage"
  stage="$probe.link.stage"; target="$stage.target"
  printf 'token=token\nrole=role\nphase=old\n' >"$target"
  ln -s -- "$target" "$stage"
  if bash "$probe" "$stage" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  "$REAL_RM" -f -- "$target" "$stage"
  [[ "$rc" != 0 ]] || return 1
  stage="$probe.hard.stage"; target="$stage.target"
  printf 'token=token\nrole=role\nphase=old\n' >"$target"
  chmod 0600 -- "$target"
  ln -- "$target" "$stage"
  if bash "$probe" "$stage" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  "$REAL_RM" -f -- "$target" "$stage"
  [[ "$rc" != 0 ]] || return 1
  "$REAL_RM" -f -- "$probe"
}

assert_int_stage_update_contract
pass 'INT stage marker updates atomically and reject token/role or unsafe leaves'

assert_int_bounded_wait_and_stage_schema
pass 'INT bounded wait reaps real child status and stage markers fail closed on token/role schema'

assert_authority_failure_reason_contract() {
  local source=${BASH_SOURCE[0]} signaler_block probe rc reason
  local -a reasons=(
    read-1 read-2 serial-unstable lock-inode-stat lock-inode-mismatch
    lock-fd-not-held flock-open flock-not-held supervisor-identity
    business-identity business-leader-mismatch protected-supervisor
    protected-business wrapper-identity wrapper-separation
  )
  signaler_block=$(awk '/^cat >"\$int_signaler"/ { capture=1 } capture { print } capture && /^EOF$/ { exit }' "$source")
  [[ "$signaler_block" == *"stat -Lc '%d:%i'"* &&
    "$signaler_block" == *'authority_fail_reason='* &&
    "$signaler_block" == *'validation-1'* &&
    "$signaler_block" == *'validation-2'* &&
    "$signaler_block" == *'marker_has_lock_fd "$pass"'* ]] || return 1
  for reason in "${reasons[@]}"; do
    [[ "$signaler_block" == *'"$pass-'* && "$signaler_block" == *"$reason"* ]] || return 1
  done
  probe=$($REAL_MKTEMP /tmp/frp-authority-reason-contract.XXXXXX)
  {
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'AUTHORITY_FAIL_REASON='
    printf '%s\n' 'authority_fail() { AUTHORITY_FAIL_REASON=$1; return 1; }'
    printf '%s\n' 'reasons=('"${reasons[*]}"')'
    printf '%s\n' 'for reason in "${reasons[@]}"; do set +e; authority_fail "$reason"; rc=$?; set -e; [[ $rc == 1 && $AUTHORITY_FAIL_REASON == "$reason" ]]; done'
  } >"$probe"
  if bash "$probe"; then rc=0; else rc=$?; fi
  "$REAL_RM" -f -- "$probe"
  [[ "$rc" == 0 ]]
}

assert_authority_failure_reason_contract
pass 'authority validator distinguishes every protected sub-check and binds lock FD by device/inode'

assert_generated_read_marker_control_flow() {
  local source=${BASH_SOURCE[0]} read_block phase_values_block probe marker rc reason
  read_block=$(awk '/^read_marker\(\)/,/^write_diagnostic\(\)/' "$source" |
    sed '$d')
  phase_values_block=$(awk '
    /^validate_authority_marker\(\)/ && occurrence == 2 { exit }
    /^validate_marker_phase_values\(\)/ { occurrence++ }
    occurrence == 2 { print }
  ' "$source" | sed '$d')
  [[ "$read_block" == *'if ! [['* &&
    "$read_block" == *'authority_fail "$label-values"'* &&
    "$read_block" == *'validate_marker_phase_values "$RECOVERY_PHASE"'* ]] || return 1
  probe=$($REAL_MKTEMP /tmp/frp-read-marker-real.XXXXXX)
  {
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'declare -A marker_seen=()'
    printf '%s\n' 'AUTHORITY_FAIL_REASON='
    printf '%s\n' 'authority_fail() { AUTHORITY_FAIL_REASON=$1; return 1; }'
    printf '%s\n' 'RECOVERY_RC_TIMEOUT=124'
    printf '%s\n' "$phase_values_block"
    printf '%s\n' "$read_block"
    printf '%s\n' 'supervisor_ready=$1'
    printf '%s\n' 'printf "phase=body-running\\nlock_inode=8:9\\nresult_rc=0\\nsupervisor_pid=2001\\nsupervisor_pgid=2002\\nsupervisor_starttime=3001\\nbusiness_pid=2003\\nbusiness_pgid=2003\\nbusiness_starttime=4001\\n" >"$supervisor_ready"'
    printf '%s\n' 'chmod 0600 -- "$supervisor_ready"'
    printf '%s\n' 'set +e; read_marker canonical; rc=$?; set -e'
    printf '%s\n' '[[ $rc == 0 && -z $AUTHORITY_FAIL_REASON ]]'
    printf '%s\n' 'printf "phase=body-running\\nlock_inode=8:9\\nresult_rc=1\\nsupervisor_pid=2001\\nsupervisor_pgid=2002\\nsupervisor_starttime=3001\\nbusiness_pid=2003\\nbusiness_pgid=2003\\nbusiness_starttime=4001\\n" >"$supervisor_ready"'
    printf '%s\n' 'AUTHORITY_FAIL_REASON='
    printf '%s\n' 'set +e; read_marker invalid; rc=$?; set -e'
    printf '%s\n' 'reason=$AUTHORITY_FAIL_REASON'
    printf '%s\n' '[[ $rc == 1 && $reason == invalid-values ]]'
  } >"$probe"
  if bash "$probe" "$TEST_DIR/read-marker-real.marker"; then rc=0; else rc=$?; fi
  "$REAL_RM" -f -- "$probe" "$TEST_DIR/read-marker-real.marker"
  [[ "$rc" == 0 ]]
}

assert_generated_read_marker_control_flow
pass 'generated read_marker accepts canonical body-running values and rejects invalid values with exact reason'

assert_process_registration_is_atomic() {
  local process_block probe rc
  process_block=$(awk '
    /^register_test_process\(\)/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${BASH_SOURCE[0]}")
  [[ "$process_block" == *'Roll back both registries'* ]] || return 1
  probe=$($REAL_MKTEMP /tmp/frp-register-test-process.XXXXXX)
  {
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'TEST_PIDS=(9001) TEST_PGIDS=(9001)'
    printf '%s\n' 'declare -A TEST_PID_STARTTIME=([9001]=1) TEST_PID_PGID=([9001]=9001)'
    printf '%s\n' 'register_test_pid() { TEST_PIDS+=(9002); TEST_PID_STARTTIME[9002]=2; TEST_PID_PGID[9002]=9002; return 0; }'
    printf '%s\n' 'register_test_pgid_for_pid() { return 1; }'
    printf '%s\n' "$process_block"
    printf '%s\n' 'set +e; register_test_process 9002; rc=$?; set -e'
    printf '%s\n' '[[ $rc == 1 && ${#TEST_PIDS[@]} == 1 && ${TEST_PIDS[0]} == 9001 && ${#TEST_PGIDS[@]} == 1 && ${TEST_PGIDS[0]} == 9001 && ${TEST_PID_STARTTIME[9002]+present} != present && ${TEST_PID_PGID[9002]+present} != present ]]'
  } >"$probe"
  if bash "$probe"; then rc=0; else rc=$?; fi
  "$REAL_RM" -f -- "$probe"
  return "$rc"
}

assert_process_registration_is_atomic
pass 'process registration rolls back PID and PGID state on PGID failure'

assert_final_cleanup_proof_contract() {
  local proof probe output
  proof=$(awk '
    /^final_cleanup_proof\(\)/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${BASH_SOURCE[0]}")
  [[ -n "$proof" && "$proof" == *'TEST_CHILD_STATUS'* &&
    "$proof" == *'test_group_owned_by_registered_process'* &&
    "$proof" == *'test_group_state'* ]] || return 1
  probe=$($REAL_MKTEMP /tmp/frp-final-cleanup-proof.XXXXXX)
  {
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'declare -a TEST_PIDS=(101) TEST_CHILD_PIDS=(101) TEST_PGIDS=(101)'
    printf '%s\n' 'declare -A TEST_PID_STARTTIME=([101]=123) TEST_PID_PGID=([101]=101)'
    printf '%s\n' 'declare -A TEST_CHILD_STATUS=([101]=143)'
    printf '%s\n' 'test_process_state() { return 1; }'
    printf '%s\n' 'test_group_owned_by_registered_process() { return 1; }'
    printf '%s\n' 'test_group_state() { return 1; }'
    printf '%s\n' "$proof"
    printf '%s\n' 'final_cleanup_proof'
    printf '%s\n' 'set +e'
    printf '%s\n' 'test_process_state() { return 0; }; final_cleanup_proof; rc=$?; [[ $rc == 2 ]] || exit 1'
    printf '%s\n' 'test_process_state() { return 1; }; test_group_owned_by_registered_process() { return 0; }; final_cleanup_proof; rc=$?; [[ $rc == 2 ]] || exit 1'
    printf '%s\n' 'test_group_owned_by_registered_process() { return 2; }; final_cleanup_proof; rc=$?; [[ $rc == 2 ]] || exit 1'
    printf '%s\n' 'test_group_owned_by_registered_process() { return 1; }; test_group_state() { return 2; }; final_cleanup_proof; rc=$?; [[ $rc == 2 ]] || exit 1'
    printf '%s\n' 'TEST_CHILD_PIDS=(202); TEST_CHILD_STATUS[202]=143; final_cleanup_proof; rc=$?; [[ $rc == 2 ]] || exit 1'
    printf '%s\n' 'set -e'
  } >"$probe"
  if ! output=$(bash "$probe" 2>&1); then
    "$REAL_RM" -f -- "$probe"
    return 1
  fi
  "$REAL_RM" -f -- "$probe"
  return 0
}

assert_final_cleanup_proof_contract
pass 'cleanup clears only after known-gone, empty-group and reaped-child proof'

assert_reaped_child_result_contract() {
  local state_block probe rc
  state_block=$(awk '
    /^    if ! read_recovery_state "\$ready_file"; then$/ { capture=1 }
    capture && /^    if \[\[ "\$RECOVERY_STATE_SUPERVISOR_PID"/ { exit }
    capture { print }
  ' "$RECOVERY")
  [[ "$state_block" == *'INNER_JOB_REGISTERED && INNER_REAPED && wait_status != 0'* &&
     "$state_block" == *'INNER_PGID > 0 && group_rc == 2'* &&
     "$state_block" == *'return "$wait_status"'* &&
     "$state_block" == *'return "$RECOVERY_RC_INTERNAL"'* ]]
  probe=$($REAL_MKTEMP /tmp/frp-reaped-child-result.XXXXXX)
  {
    printf '%s\n' 'set -u'
    printf '%s\n' 'ready_file=/tmp/frp-reaped-child-result-missing RECOVERY_RC_INTERNAL=74'
    printf '%s\n' 'read_recovery_state() { return 1; }'
    printf '%s\n' 'finish_with_marker_cleanup() { return 0; }'
    printf '%s\n' 'abort_inner_before_cleanup() { return 0; }'
    printf '%s\n' 'replay_state() {'
    printf '%s\n' '  INNER_JOB_REGISTERED=1 INNER_REAPED=1 INNER_PGID=9001 group_rc=$2 wait_status=$1'
    printf '%s\n' "$state_block"
    printf '%s\n' '}'
    printf '%s\n' 'set +e; replay_state 75 2; printf "preserved=%s\n" "$?"'
    printf '%s\n' 'set +e; replay_state 0 2; printf "zero=%s\n" "$?"'
    printf '%s\n' 'set +e; replay_state 75 3; printf "unknown_group=%s\n" "$?"'
  } >"$probe"
  rc=$(bash "$probe")
  "$REAL_RM" -f -- "$probe"
  [[ "$rc" == *$'preserved=75'* && "$rc" == *$'zero=74'* &&
     "$rc" == *$'unknown_group=74'* ]]
}

assert_reaped_child_result_contract
pass 'reaped direct child preserves non-zero result only after empty-group proof'

prebuilt_parent_policy_probe() {
  local probe unsafe safe actual
  probe=$($REAL_MKTEMP /tmp/frp-parent-policy.XXXXXX)
  awk '
    /^xudp_prebuilt_parent_safe\(\)/ { copying=1 }
    copying { print }
    copying && /^}$/ { exit }
  ' "$RECOVERY" >"$probe"
  printf '%s\n' 'set -Eeuo pipefail' 'xudp_prebuilt_parent_safe "$1"' >>"$probe"
  bash -n "$probe"

  actual=/tmp/frp-bin/frps
  [[ -x "$actual" ]] || {
    printf 'parent policy probe requires current prebuilt artifact: %s\n' "$actual" >&2
    return 1
  }
  bash "$probe" "$actual"

  unsafe=$($REAL_MKTEMP -d /tmp/frp-parent-unsafe.XXXXXX)
  chmod 0777 -- "$unsafe"
  printf 'unsafe\n' >"$unsafe/artifact"
  chmod 0555 -- "$unsafe/artifact"
  if bash "$probe" "$unsafe/artifact"; then
    printf 'non-sticky world-writable parent was accepted\n' >&2
    return 1
  fi

  safe=$($REAL_MKTEMP -d /tmp/frp-parent-safe.XXXXXX)
  chmod 700 -- "$safe"
  printf 'safe\n' >"$safe/artifact"
  chmod 0555 -- "$safe/artifact"
  bash "$probe" "$safe/artifact"
  "$REAL_RM" -rf -- "$unsafe" "$safe" "$probe"
}

prebuilt_parent_policy_probe

prebuilt_early_selection_probe() {
  local state_before state_after output rc
  local marker_glob='/tmp/frp-xudp-recovery-marker.*'
  local runtime_glob='/tmp/frp-xudp-smoke.*'
  state_before=$(find /tmp -maxdepth 1 \( -name 'frp-xudp-recovery-marker.*' -o -name 'frp-xudp-recovery-uid-*' -o -name 'frp-xudp-smoke.*' \) -printf '%f\n' | sort)

  set +e
  output=$(timeout --foreground 5 env -i PATH=/usr/bin:/bin HOME=/ \
    FRP_XUDP_FRPS=/tmp/prebuilt-frps \
    bash "$RECOVERY" --p2p --recreate --help 2>&1)
  rc=$?
  set -e
  [[ "$rc" == 2 ]] || {
    printf 'partial prebuilt early probe expected rc2, got %s\n%s\n' "$rc" "$output" >&2
    return 1
  }
  [[ "$output" == *'prebuilt artifact selection requires either none or all four paths'* ]] || return 1

  state_after=$(find /tmp -maxdepth 1 \( -name 'frp-xudp-recovery-marker.*' -o -name 'frp-xudp-recovery-uid-*' -o -name 'frp-xudp-smoke.*' \) -printf '%f\n' | sort)
  [[ "$state_after" == "$state_before" ]] || {
    printf 'partial prebuilt early probe changed recovery state\n' >&2
    return 1
  }

  run_expect 0 "$TEST_DIR/prebuilt-zero-help.out" env -i PATH=/usr/bin:/bin HOME=/ \
    bash "$RECOVERY" --p2p --recreate --help
  run_expect 0 "$TEST_DIR/prebuilt-four-help.out" env -i PATH=/usr/bin:/bin HOME=/ \
    FRP_XUDP_FRPS=/bin/true FRP_XUDP_FRPC=/bin/true \
    FRP_XUDP_UDP_SEND=/bin/true FRP_XUDP_UDP_ECHO=/bin/true \
    bash "$RECOVERY" --p2p --recreate --help
  require_not_contains "$TEST_DIR/prebuilt-zero-help.out" 'prebuilt artifact selection requires either none or all four paths'
  require_not_contains "$TEST_DIR/prebuilt-four-help.out" 'prebuilt artifact selection requires either none or all four paths'

  prebuilt_gate_case() {
    local label=$1 mode=$2 recreate=$3 frps=$4 frpc=$5 send=$6 echo=$7 fixture=$TEST_DIR/prebuilt-gate-$1.sh
    {
      printf 'MODE=%q\nRECREATE=%q\nSHOW_HELP=0\n' "$mode" "$recreate"
      printf 'PREBUILT_FRPS=%q\nPREBUILT_FRPC=%q\nUDP_SEND=%q\nUDP_ECHO=%q\n' "$frps" "$frpc" "$send" "$echo"
      printf 'PREBUILT_ARTIFACT_COUNT=0\nPREBUILT_ARTIFACT_MODE=0\n'
      awk '/^validate_prebuilt_artifact_selection_early\(\)/,/^}/' "$RECOVERY"
      printf 'validate_prebuilt_artifact_selection_early\n'
    } >"$fixture"
    set +e
    bash "$fixture" >/dev/null 2>&1
    local rc=$?
    set -e
    rm -f -- "$fixture"
    printf '%s\n' "$rc"
  }
  [[ $(prebuilt_gate_case existing-send existing 0 '' '' /tmp/udp-send '') == 0 ]] || return 1
  [[ $(prebuilt_gate_case existing-frps existing 0 /tmp/frps '' '' '') == 2 ]] || return 1
  [[ $(prebuilt_gate_case recreate-one p2p 1 /tmp/frps '' '' '') == 2 ]] || return 1
  [[ $(prebuilt_gate_case recreate-four relay 1 /tmp/frps /tmp/frpc /tmp/udp-send /tmp/udp-echo) == 0 ]] || return 1
}

runtime_identity_for() {
  local root=$1 label path stat_line devino kind uid mode
  printf 'v1'
  for label in root bin config log; do
    path=$root
    [[ "$label" == root ]] || path=$root/$label
    stat_line=$(LC_ALL=C "$REAL_STAT" -Lc '%d:%i|%F|%u|%a' -- "$path")
    IFS='|' read -r devino kind uid mode <<<"$stat_line"
    printf '|%s=%s,%s,%s,%s,%s' "$label" "$path" "$devino" "$kind" "$uid" "$mode"
  done
  printf '\n'
}

prepare_labeled_old_runtime() {
  local root=$1 entry
  mkdir -m 700 -- "$root/bin" "$root/config" "$root/log"
  for entry in \
    "$root/bin/frps" "$root/bin/frpc" \
    "$root/config/frps.toml" "$root/config/frpc.toml" "$root/config/frpc-visitor.toml" \
    "$root/log/frpsA.log" "$root/log/frpcB.log" "$root/log/frpC.log"; do
    printf 'old-runtime-fixture\n' >"$entry"
  done
  runtime_identity_for "$root"
}

remove_runtime_fixture() {
  local root=$1 leaf dir
  for leaf in \
    "$root/bin/frps" "$root/bin/frpc" "$root/bin/udp_send" "$root/bin/udp_echo" \
    "$root/config/frps.toml" "$root/config/frpc.toml" "$root/config/frpc-visitor.toml" \
    "$root/log/frps.log" "$root/log/frpc.log" "$root/log/frpc-visitor.log" \
    "$root/log/frpsA.log" "$root/log/frpcB.log" "$root/log/frpC.log"; do
    "$REAL_RM" -f -- "$leaf" 2>/dev/null || true
  done
  for dir in "$root/log" "$root/config" "$root/bin" "$root"; do
    "$REAL_RMDIR" -- "$dir" 2>/dev/null || true
  done
}

if bash -n -- "${BASH_SOURCE[0]}"; then
  :
else
  rc=$?
  printf 'xudp-init-command-error rc=%s stage=script-syntax path=%s\n' \
    "$rc" "${BASH_SOURCE[0]}" >&2
  exit "$rc"
fi
pass 'test driver itself passes the main-script bash syntax gate'
if bash -n -- "$RECOVERY"; then
  :
else
  rc=$?
  printf 'xudp-init-command-error rc=%s stage=recovery-syntax path=%s\n' \
    "$rc" "$RECOVERY" >&2
  exit "$rc"
fi
pass 'updated recovery entrypoint passes the main-script bash syntax gate'

FAKE_HELPERS=(
  "$FAKE_BIN/docker" "$FAKE_BIN/timeout" "$FAKE_BIN/udp_send"
  "$FAKE_BIN/mktemp" "$FAKE_BIN/rm" "$FAKE_BIN/rmdir" "$FAKE_BIN/sleep" "$FAKE_BIN/flock"
  "$FAKE_BIN/stat"
)
[[ ${#FAKE_HELPERS[@]} == 9 ]] || {
  printf 'expected exactly 9 fake helper files, got %s\n' "${#FAKE_HELPERS[@]}" >&2
  exit 1
}
for generated_helper in "${FAKE_HELPERS[@]}"; do
  [[ -f "$generated_helper" && ! -L "$generated_helper" ]] || {
    printf 'fake helper is not an exact regular file: %s\n' "$generated_helper" >&2
    exit 1
  }
  if bash -n -- "$generated_helper"; then
    :
  else
    rc=$?
    printf 'xudp-init-command-error rc=%s stage=helper-syntax path=%s\n' \
      "$rc" "$generated_helper" >&2
    exit "$rc"
  fi
done
pass 'all fake helper heredocs pass bash -n before any fixture scenario'

static_check_helper_symbols() {
  local helper symbol
  local -a helpers=("$@")
  local -a symbols=(layout_error valid_name timeout_error atomic_marker proc_snapshot
    protected_pgid target_state read_marker write_diagnostic fail_signal
    stable_wrapper_identity stable_marker_identity marker_has_lock_fd
    validate_authority_marker group_state refresh_target target_valid
    authority_marker_valid signaler_is_gone)
  for helper in "${helpers[@]}"; do
    for symbol in "${symbols[@]}"; do
      if grep -Eq "(^|[[:space:];|&])${symbol}([[:space:]]|\\()" "$helper" &&
        ! grep -Eq "^[[:space:]]*${symbol}[[:space:]]*\\(\\)" "$helper"; then
        printf 'helper %s references undefined local function %s\n' "$helper" "$symbol" >&2
        return 1
      fi
    done
  done
}

static_check_helper_symbols "${FAKE_HELPERS[@]}"
pass 'fake helper function calls are statically self-contained'

process_starttime() {
  local pid=$1 line rest state starttime
  local -a fields=()
  [[ "$pid" =~ ^[0-9]+$ && "$pid" != 0 ]] || return 1
  [[ -r "/proc/$pid/stat" ]] || return 1
  line=$(<"/proc/$pid/stat") || return 1
  rest=${line#*') '}
  [[ "$rest" != "$line" ]] || return 1
  read -r -a fields <<<"$rest"
  state=${fields[0]-}
  starttime=${fields[19]-}
  [[ "$state" != Z* && "$starttime" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$starttime"
}

REAL_SETPRIV=/usr/bin/setpriv

assert_isolated_hostile_precondition() {
  local init_exe pid_ns_self pid_ns_init mnt_ns_self mnt_ns_init cgroup_text
  local mountinfo_text dockerenv_stat dockerenv_kind dockerenv_owner dockerenv_mode
  local dockerenv_mode_value root_fstype proc_fstype workspace_mount_options
  local shell_pid=$$ shell_ppid timeout_pid timeout_exe shell_exe
  local shell_first timeout_first init_first shell_second timeout_second init_second
  local shell_starttime timeout_starttime init_starttime
  [[ "$ISOLATED_MODE" == 1 ]] || {
    printf 'hostile lock-root tests require --isolated\n' >&2
    return 75
  }
  [[ "$(id -u)" == 0 ]] || {
    printf 'isolated mode requires current UID 0 for setpriv fixture cleanup\n' >&2
    return 75
  }
  proc_chain_snapshot() {
    local pid=$1 line rest state ppid starttime
    local -a fields=()
    [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/$pid/stat" ]] || return 1
    line=$(<"/proc/$pid/stat") || return 1
    rest=${line#*') '}
    [[ "$rest" != "$line" ]] || return 1
    read -r -a fields <<<"$rest"
    state=${fields[0]-}
    ppid=${fields[1]-}
    starttime=${fields[19]-}
    [[ "$state" != Z* && "$ppid" =~ ^[0-9]+$ &&
      "$starttime" =~ ^[0-9]+$ ]] || return 1
    printf '%s %s\n' "$starttime" "$ppid"
  }

  proc_argv0() {
    local pid=$1 argv0=
    [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/$pid/cmdline" ]] || return 1
    IFS= read -r -d '' argv0 <"/proc/$pid/cmdline" || return 1
    [[ -n "$argv0" ]] || return 1
    PROC_ARGV0=$argv0
  }

  mountinfo_lookup() {
    local text=$1 target=$2 line left right separator
    local -a fields=() right_fields=()
    local mount_id parent major root mountpoint options optional fstype source superoptions
    local target_count=0 separator_count=0
    MOUNTINFO_FOUND=0
    MOUNTINFO_FSTYPE=
    MOUNTINFO_MOUNT_OPTIONS=
    MOUNTINFO_MOUNT_SOURCE=
    [[ -n "$text" && -n "$target" ]] || return 2
    mountinfo_decode_field() {
      local value=$1 i ch code out=
      for ((i = 0; i < ${#value}; i++)); do
        ch=${value:i:1}
        if [[ "$ch" == \\ ]]; then
          ((i + 3 < ${#value})) || return 1
          code=${value:i+1:3}
          case "$code" in
            040) out+=' ' ;;
            011) out+=$'\t' ;;
            012) out+=$'\n' ;;
            134) out+=$'\\' ;;
            *) return 1 ;;
          esac
          ((i += 3))
        else
          [[ "$ch" != *[[:cntrl:]]* ]] || return 1
          out+=$ch
        fi
      done
      MOUNTINFO_DECODED=$out
    }
    mountinfo_validate_options() {
      local value=$1 option
      local -a option_fields=()
      [[ -n "$value" && "$value" != ,* && "$value" != *, &&
        "$value" != *,,* ]] || return 1
      IFS=, read -r -a option_fields <<<"$value"
      (( ${#option_fields[@]} > 0 )) || return 1
      for option in "${option_fields[@]}"; do
        [[ -n "$option" && "$option" != *[[:space:]]* &&
          "$option" != *[[:cntrl:]]* && "$option" != *\\* ]] || return 1
      done
    }
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" && "$line" != *[[:cntrl:]]* &&
        "$line" != ' '* && "$line" != *' ' && "$line" != *'  '* ]] || return 2
      [[ "$line" == *" - "* ]] || return 2
      right=${line#* - }
      [[ -n "$right" && "$right" != "$line" ]] || return 2
      separator=" - $right"
      left=${line%"$separator"}
      [[ -n "$left" && "$left" != "$line" && "$left" != *" - "* &&
        "$right" != *" - "* ]] || return 2
      ((separator_count++))
      read -r -a fields <<<"$left"
      read -r -a right_fields <<<"$right"
      (( ${#fields[@]} >= 6 && ${#right_fields[@]} == 3 )) || return 2
      mount_id=${fields[0]}; parent=${fields[1]}; major=${fields[2]}
      root=${fields[3]}; mountpoint=${fields[4]}; options=${fields[5]}
      [[ "$mount_id" =~ ^[1-9][0-9]*$ && "$parent" =~ ^[1-9][0-9]*$ &&
        "$major" =~ ^[0-9]+:[0-9]+$ ]] || return 2
      mountinfo_decode_field "$root" || return 2; root=$MOUNTINFO_DECODED
      mountinfo_decode_field "$mountpoint" || return 2; mountpoint=$MOUNTINFO_DECODED
      mountinfo_decode_field "$options" || return 2; options=$MOUNTINFO_DECODED
      [[ "$root" == /* && "$mountpoint" == /* ]] || return 2
      mountinfo_validate_options "$options" || return 2
      if (( ${#fields[@]} > 6 )); then
        for optional in "${fields[@]:6}"; do
          mountinfo_decode_field "$optional" || return 2
          optional=$MOUNTINFO_DECODED
          [[ -n "$optional" && "$optional" != '-' &&
            "$optional" != *[[:cntrl:]]* ]] || return 2
          if [[ "$optional" =~ ^(shared|master|propagate_from):[1-9][0-9]*$ ||
            "$optional" == unbindable || "$optional" == idmapped ]]; then
            :
          else
            return 2
          fi
        done
      fi
      fstype=${right_fields[0]}; source=${right_fields[1]}; superoptions=${right_fields[2]}
      mountinfo_decode_field "$fstype" || return 2; fstype=$MOUNTINFO_DECODED
      mountinfo_decode_field "$source" || return 2; source=$MOUNTINFO_DECODED
      mountinfo_decode_field "$superoptions" || return 2; superoptions=$MOUNTINFO_DECODED
      [[ "$fstype" =~ ^[^[:space:][:cntrl:]]+$ && -n "$source" &&
        -n "$superoptions" ]] || return 2
      mountinfo_validate_options "$superoptions" || return 2
      if [[ "$mountpoint" == "$target" ]]; then
        ((target_count++))
        MOUNTINFO_FSTYPE=$fstype
        MOUNTINFO_MOUNT_OPTIONS=$options
        MOUNTINFO_MOUNT_SOURCE=$source
      fi
    done <<<"$text"
    (( separator_count > 0 && target_count == 1 )) || return 2
    MOUNTINFO_FOUND=1
    return 0
  }

  cgroup_parse_strict() {
    local text=$1 line hierarchy controllers path controller mode=
    local -A seen_hierarchies=() seen_controllers=()
    local line_count=0
    [[ -n "$text" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
      ((line_count++))
      [[ -n "$line" && "$line" != *$'\r' && "$line" != *$'\t'* &&
        "$line" != *$'\n'* && "$line" != *[[:cntrl:]]* ]] || return 1
      if [[ "$line" =~ ^0::/[^[:cntrl:]]*$ ]]; then
        [[ "$mode" == '' && "$line_count" == 1 ]] || return 1
        mode=v2
        continue
      fi
      [[ "$line" =~ ^([1-9][0-9]*):([A-Za-z0-9_.=-]+(,[A-Za-z0-9_.=-]+)*):(/[^[:cntrl:]]*)$ ]] || return 1
      [[ "$mode" == '' || "$mode" == v1 ]] || return 1
      mode=v1
      hierarchy=${BASH_REMATCH[1]}
      controllers=${BASH_REMATCH[2]}
      path=${BASH_REMATCH[4]}
      [[ "$hierarchy" =~ ^[1-9][0-9]*$ && "$path" == /* ]] || return 1
      [[ -z "${seen_hierarchies[$hierarchy]+x}" ]] || return 1
      seen_hierarchies[$hierarchy]=1
      IFS=, read -r -a controller_fields <<<"$controllers"
      for controller in "${controller_fields[@]}"; do
        [[ -n "$controller" && -z "${seen_controllers[$controller]+x}" ]] || return 1
        seen_controllers[$controller]=1
      done
    done <<<"$text"
    [[ "$line_count" -gt 0 && ( "$mode" == v1 || "$mode" == v2 ) ]] || return 1
    CGROUP_MODE=$mode
    return 0
  }

  dockerenv_stat_parse_strict() {
    local text=$1
    local delimiter_only
    local -a fields=()
    local kind owner mode
    [[ -n "$text" && "$text" != *[[:cntrl:]]* ]] || return 1
    delimiter_only=${text//[^|]/}
    [[ ${#delimiter_only} -eq 2 ]] || return 1
    IFS='|' read -r -a fields <<<"$text"
    [[ ${#fields[@]} -eq 3 ]] || return 1
    kind=${fields[0]}; owner=${fields[1]}; mode=${fields[2]}
    [[ -n "$kind" && -n "$owner" && -n "$mode" &&
      ( "$kind" == 'regular file' || "$kind" == 'regular empty file' ) &&
      "$owner" == 0 &&
      "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    DOCKERENV_KIND=$kind
    DOCKERENV_OWNER=$owner
    DOCKERENV_MODE=$mode
    DOCKERENV_MODE_VALUE=$((8#$mode))
    (( (DOCKERENV_MODE_VALUE & 18) == 0 )) || return 1
    return 0
  }

  dockerenv_stat_result_parse_strict() {
    local rc=$1 text=$2
    [[ "$rc" =~ ^0$ ]] || return 1
    dockerenv_stat_parse_strict "$text"
  }

  dockerenv_stat_parser_pure_tests() {
    local valid valid_four_digit extra missing_kind missing_owner missing_mode
    local empty_valid bad_kind non_root dangerous malformed control invalid
    valid='regular file|0|644'
    valid_four_digit='regular file|0|0644'
    empty_valid='regular empty file|0|755'
    extra='regular file|0|644|unexpected'
    missing_kind='|0|644'
    missing_owner='regular file||644'
    missing_mode='regular file|0|'
    bad_kind='directory|0|644'
    non_root='regular file|1000|644'
    dangerous='regular file|0|0664'
    malformed='regular file|0|08'
    control=$'regular file|0|644\n'
    dockerenv_stat_parse_strict "$valid" || return 1
    [[ "$DOCKERENV_KIND" == 'regular file' && "$DOCKERENV_OWNER" == 0 &&
      "$DOCKERENV_MODE" == 644 && "$DOCKERENV_MODE_VALUE" -eq 420 ]] || return 1
    dockerenv_stat_parse_strict "$valid_four_digit" || return 1
    [[ "$DOCKERENV_KIND" == 'regular file' && "$DOCKERENV_OWNER" == 0 &&
      "$DOCKERENV_MODE" == 0644 && "$DOCKERENV_MODE_VALUE" -eq 420 ]] || return 1
    dockerenv_stat_parse_strict "$empty_valid" || return 1
    [[ "$DOCKERENV_KIND" == 'regular empty file' && "$DOCKERENV_OWNER" == 0 &&
      "$DOCKERENV_MODE" == 755 && "$DOCKERENV_MODE_VALUE" -eq 493 ]] || return 1
    for invalid in "$extra" "$missing_kind" "$missing_owner" "$missing_mode" \
      "$bad_kind" "regular empty file|1000|755" "regular empty file|0|0664" \
      "symlink|0|755" "socket|0|755" "fifo|0|755" "block special file|0|755" \
      "character special file|0|755" "unknown|0|755" "$non_root" "$dangerous" \
      "$malformed" "$control"; do
      dockerenv_stat_parse_strict "$invalid" && return 1
    done
    dockerenv_stat_result_parse_strict 0 "$valid" || return 1
    dockerenv_stat_result_parse_strict 0 "$valid_four_digit" || return 1
    dockerenv_stat_result_parse_strict 1 "$valid" && return 1
    dockerenv_stat_result_parse_strict 1 "$valid_four_digit" && return 1
    return 0
  }

  mountinfo_options_include() {
    local options=$1 wanted=$2 option
    local -a option_fields=()
    IFS=, read -r -a option_fields <<<"$options"
    for option in "${option_fields[@]}"; do
      [[ "$option" == "$wanted" ]] && return 0
    done
    return 1
  }

  mountinfo_parser_pure_tests() {
    local valid escaped missing_root proc_wrong workspace_rw malformed unknown_escape duplicate_root
    local bad_fields bad_separator bad_right optional_valid optional_bad optional_zero
    local optional_leading_zero optional_non_numeric optional_unknown super_missing
    valid=$'36 25 0:32 / / rw,relatime - overlay overlay rw\n37 25 0:33 / /proc rw,nosuid,nodev,noexec,relatime - proc proc rw\n38 25 0:34 /src /workspace/src ro,relatime - xfs /dev/vdb ro'
    escaped=$'39 25 0:35 /root\\040dir /mnt\\040space ro - ext4 dev\\040mapper\\134root ro'
    missing_root=$'37 25 0:33 / /proc rw - proc proc rw'
    proc_wrong=$'36 25 0:32 / / rw - overlay overlay rw\n37 25 0:33 / /proc rw - tmpfs tmpfs rw'
    workspace_rw=$'36 25 0:32 / / rw - overlay overlay rw\n38 25 0:34 /src /workspace/src rw,relatime - xfs /dev/vdb rw'
    malformed=$'36 25 0:32 / / rw - overlay overlay rw\nmalformed mountinfo record'
    unknown_escape=$'36 25 0:32 / / rw - overlay overlay rw\n38 25 0:34 /bad\\777 /workspace/src ro - xfs /dev/vdb ro'
    duplicate_root=$'36 25 0:32 / / rw - overlay overlay rw\n39 25 0:35 / / rw - overlay overlay rw'
    bad_fields=$'36 xx 0:32 / / rw - overlay overlay rw'
    bad_separator=$'36 25 0:32 / / rw - overlay overlay rw - extra extra extra'
    bad_right=$'36 25 0:32 / / rw - overlay overlay'
    optional_valid=$'36 25 0:32 / / rw shared:1 - overlay overlay rw\n37 25 0:33 / /proc rw master:1 - proc proc rw\n38 25 0:34 /src /workspace/src ro,relatime propagate_from:10 - xfs /dev/vdb ro'
    optional_bad=$'36 25 0:32 / / rw shared:x - overlay overlay rw'
    optional_zero=$'36 25 0:32 / / rw shared:0 - overlay overlay rw'
    optional_leading_zero=$'36 25 0:32 / / rw master:01 - overlay overlay rw'
    optional_non_numeric=$'36 25 0:32 / / rw propagate_from:x - overlay overlay rw'
    optional_unknown=$'36 25 0:32 / / rw vendor:1 - overlay overlay rw'
    super_missing=$'36 25 0:32 / / rw - overlay overlay'

    mountinfo_lookup "$valid" / || return 1
    [[ "$MOUNTINFO_FSTYPE" == overlay ]] || return 1
    mountinfo_lookup "$valid" /workspace/src || return 1
    mountinfo_options_include "$MOUNTINFO_MOUNT_OPTIONS" ro || return 1
    mountinfo_lookup "$escaped" '/mnt space' || return 1
    [[ "$MOUNTINFO_MOUNT_SOURCE" == 'dev mapper\root' ]] || return 1
    mountinfo_lookup "$missing_root" / && return 1
    mountinfo_lookup "$proc_wrong" /proc || return 1
    [[ "$MOUNTINFO_FSTYPE" != proc ]] || return 1
    mountinfo_lookup "$workspace_rw" /workspace/src || return 1
    mountinfo_options_include "$MOUNTINFO_MOUNT_OPTIONS" ro && return 1
    mountinfo_lookup "$malformed" / && return 1
    [[ $? == 2 ]] || return 1
    mountinfo_lookup "$unknown_escape" /workspace/src && return 1
    [[ $? == 2 ]] || return 1
    mountinfo_lookup "$duplicate_root" / && return 1
    [[ $? == 2 ]] || return 1
    mountinfo_lookup "$bad_fields" / && return 1
    [[ $? == 2 ]] || return 1
    mountinfo_lookup "$bad_separator" / && return 1
    [[ $? == 2 ]] || return 1
    mountinfo_lookup "$bad_right" / && return 1
    [[ $? == 2 ]] || return 1
    mountinfo_lookup "$optional_valid" / || return 1
    mountinfo_lookup "$optional_valid" /proc || return 1
    mountinfo_lookup "$optional_valid" /workspace/src || return 1
    mountinfo_lookup "$optional_bad" / && return 1
    [[ $? == 2 ]] || return 1
    for invalid in "$optional_zero" "$optional_leading_zero" \
      "$optional_non_numeric" "$optional_unknown"; do
      mountinfo_lookup "$invalid" / && return 1
      [[ $? == 2 ]] || return 1
    done
    mountinfo_lookup "$super_missing" / && return 1
    [[ $? == 2 ]] || return 1
  }

  cgroup_parser_pure_tests() {
    local v2 duplicate_v2 v1 mixed duplicate_hierarchy duplicate_controller malformed empty
    v2='0::/'
    duplicate_v2=$'0::/\n0::/user.slice'
    v1=$'7:cpu,cpuacct:/docker/a\n8:memory:/docker/a'
    mixed=$'0::/docker/a\n7:cpu:/docker/a'
    duplicate_hierarchy=$'7:cpu:/docker/a\n7:memory:/docker/b'
    duplicate_controller=$'7:cpu,cpuacct:/docker/a\n8:cpu:/docker/b'
    malformed=$'0:cpu:/docker/a'
    empty=''
    cgroup_parse_strict "$v2" || return 1
    [[ "$CGROUP_MODE" == v2 ]] || return 1
    cgroup_parse_strict "$duplicate_v2" && return 1
    cgroup_parse_strict "$v1" || return 1
    [[ "$CGROUP_MODE" == v1 ]] || return 1
    cgroup_parse_strict "$mixed" && return 1
    cgroup_parse_strict "$duplicate_hierarchy" && return 1
    cgroup_parse_strict "$duplicate_controller" && return 1
    cgroup_parse_strict "$malformed" && return 1
    cgroup_parse_strict "$empty" && return 1
    return 0
  }

  mountinfo_parser_pure_tests || {
    printf 'isolated mode mountinfo parser pure tests failed\n' >&2
    return 75
  }
  cgroup_parser_pure_tests || {
    printf 'isolated mode cgroup parser pure tests failed\n' >&2
    return 75
  }

  trusted_canonical_regular_file() {
    local path=$1 file_kind file_owner file_mode mode_value
    file_kind=$($REAL_STAT -c '%F' -- "$path" 2>/dev/null) || return 1
    file_owner=$($REAL_STAT -c '%u' -- "$path" 2>/dev/null) || return 1
    file_mode=$($REAL_STAT -c '%a' -- "$path" 2>/dev/null) || return 1
    [[ "$file_kind" == 'regular file' && "$file_owner" == 0 &&
      "$file_mode" =~ ^[0-7]{3,4}$ && ! -L "$path" ]] || return 1
    mode_value=$((8#$file_mode))
    (( (mode_value & 18) == 0 ))
  }

  trusted_timeout_argv0_path() {
    local path=$1 file_kind file_owner file_mode mode_value parent parent_kind
    local parent_owner parent_mode parent_mode_value
    case "$path" in
      /bin/timeout|/usr/bin/timeout) ;;
      *) return 1 ;;
    esac
    file_kind=$($REAL_STAT -c '%F' -- "$path" 2>/dev/null) || return 1
    file_owner=$($REAL_STAT -c '%u' -- "$path" 2>/dev/null) || return 1
    file_mode=$($REAL_STAT -c '%a' -- "$path" 2>/dev/null) || return 1
    [[ "$file_kind" == 'symbolic link' || "$file_kind" == 'regular file' ]] || return 1
    [[ "$file_owner" == 0 ]] || return 1
    if [[ "$file_kind" == 'regular file' ]]; then
      [[ "$file_mode" =~ ^[0-7]{3,4}$ ]] || return 1
      mode_value=$((8#$file_mode))
      (( (mode_value & 18) == 0 )) || return 1
    else
      # Symlink mode bits are non-authoritative on Linux; bind the link to a
      # root-owned, non-group/other-writable system directory instead.
      parent=${path%/*}
      parent_kind=$($REAL_STAT -c '%F' -- "$parent" 2>/dev/null) || return 1
      parent_owner=$($REAL_STAT -c '%u' -- "$parent" 2>/dev/null) || return 1
      parent_mode=$($REAL_STAT -c '%a' -- "$parent" 2>/dev/null) || return 1
      [[ "$parent_kind" == directory && "$parent_owner" == 0 &&
        "$parent_mode" =~ ^[0-7]{3,4}$ ]] || return 1
      parent_mode_value=$((8#$parent_mode))
      (( (parent_mode_value & 18) == 0 )) || return 1
    fi
  }

  timeout_argv0_canonical_allowed() {
    local argv0=$1 canonical=$2
    # The isolated ancestor chain accepts exactly two timeout families:
    #
    #   GNU/system timeout (including usrmerge):
    #     argv0=/bin/timeout or /usr/bin/timeout, canonical=/bin/timeout
    #     or /usr/bin/timeout.
    #   This image's Rust coreutils timeout:
    #     the same argv0 paths, canonical=/usr/lib/cargo/bin/coreutils or
    #     the exact timeout applet /usr/lib/cargo/bin/coreutils/timeout.
    #
    # Keep this mapping role-specific: cargo is valid only for timeout, and
    # no non-timeout executable is admitted by this function.
    case "$argv0:$canonical" in
      /bin/timeout:/bin/timeout|\
      /bin/timeout:/usr/bin/timeout|\
      /usr/bin/timeout:/bin/timeout|\
      /usr/bin/timeout:/usr/bin/timeout|\
      /bin/timeout:/usr/lib/cargo/bin/coreutils|\
      /usr/bin/timeout:/usr/lib/cargo/bin/coreutils|\
      /bin/timeout:/usr/lib/cargo/bin/coreutils/timeout|\
      /usr/bin/timeout:/usr/lib/cargo/bin/coreutils/timeout)
        return 0
        ;;
      *) return 1 ;;
    esac
  }

  trusted_system_exe() {
    local exe=$1 candidate file_stat file_mode mode_value
    case "$exe" in
      /bin/bash|/usr/bin/bash|/bin/timeout|/usr/bin/timeout|\
      /bin/docker-init|/usr/bin/docker-init|/sbin/docker-init|/usr/sbin/docker-init|\
      /bin/tini|/usr/bin/tini|/sbin/tini|/usr/sbin/tini)
        for candidate in /bin/bash /usr/bin/bash /bin/timeout /usr/bin/timeout \
          /bin/docker-init /usr/bin/docker-init /sbin/docker-init /usr/sbin/docker-init \
          /bin/tini /usr/bin/tini /sbin/tini /usr/sbin/tini; do
          [[ "$exe" == "$candidate" && -f "$candidate" && ! -L "$candidate" ]] || continue
          file_kind=$($REAL_STAT -Lc '%F' -- "$candidate" 2>/dev/null) || return 1
          file_owner=$($REAL_STAT -Lc '%u' -- "$candidate" 2>/dev/null) || return 1
          file_mode=$($REAL_STAT -Lc '%a' -- "$candidate" 2>/dev/null) || return 1
          [[ "$file_kind" == 'regular file' && "$file_owner" == 0 &&
            "$file_mode" =~ ^[0-7]{3,4}$ ]] || return 1
          mode_value=$((8#$file_mode))
          (( (mode_value & 18) == 0 )) || return 1
          return 0
        done
        ;;
    esac
    return 1
  }

  # Pure function-level timeout policy gates: these do not start a process and
  # do not contribute to the TAP pass count. Keep both accepted families
  # explicit here so a future edit cannot silently remove one implementation.
  for timeout_argv0 in /bin/timeout /usr/bin/timeout; do
    for timeout_canonical in /bin/timeout /usr/bin/timeout \
      /usr/lib/cargo/bin/coreutils /usr/lib/cargo/bin/coreutils/timeout; do
      timeout_argv0_canonical_allowed "$timeout_argv0" "$timeout_canonical" || {
        printf 'isolated mode rejected an allowed timeout mapping: %s -> %s\n' \
          "$timeout_argv0" "$timeout_canonical" >&2
        return 75
      }
    done
  done
  timeout_argv0_canonical_allowed /usr/bin/not-timeout /usr/lib/cargo/bin/coreutils && {
    printf 'isolated mode rejected mismatched timeout argv0\n' >&2
    return 75
  }
  timeout_argv0_canonical_allowed /bin/bash /usr/lib/cargo/bin/coreutils && {
    printf 'isolated mode rejected cargo canonical target for a non-timeout role\n' >&2
    return 75
  }
  timeout_argv0_canonical_allowed /usr/bin/timeout /usr/lib/other/coreutils && {
    printf 'isolated mode rejected non-exact timeout canonical target\n' >&2
    return 75
  }
  timeout_argv0_canonical_allowed /usr/bin/timeout /usr/lib/cargo/bin/coreutils/echo && {
    printf 'isolated mode rejected non-timeout cargo applet canonical target\n' >&2
    return 75
  }
  timeout_argv0_canonical_allowed /bin/bash /bin/bash && {
    printf 'isolated mode rejected non-timeout role in timeout trust gate\n' >&2
    return 75
  }

  shell_exe=$(readlink -f -- "/proc/$shell_pid/exe" 2>/dev/null || true)
  [[ "$shell_exe" == /bin/bash || "$shell_exe" == /usr/bin/bash ]] || {
    printf 'isolated mode exe trust validation failed: current shell is not trusted system bash (%s)\n' \
      "${shell_exe:-unresolved}" >&2
    return 75
  }
  trusted_system_exe "$shell_exe" || {
    printf 'isolated mode exe trust validation failed: current shell file is not root-owned and non-writable (%s)\n' \
      "$shell_exe" >&2
    return 75
  }

  if [[ "$PPID" == 1 ]]; then
    timeout_pid=0
    init_exe=$(readlink -f -- /proc/1/exe 2>/dev/null || true)
    case "$init_exe" in
      /bin/docker-init|/usr/bin/docker-init|/sbin/docker-init|/usr/sbin/docker-init|\
      /bin/tini|/usr/bin/tini|/sbin/tini|/usr/sbin/tini) ;;
      *)
        printf 'isolated mode exe trust validation failed: PID1 is not trusted docker-init/tini (%s)\n' \
          "${init_exe:-unresolved}" >&2
        return 75
        ;;
    esac
    trusted_system_exe "$init_exe" || {
      printf 'isolated mode exe trust validation failed: PID1 file is not root-owned and non-writable (%s)\n' \
        "$init_exe" >&2
      return 75
    }
    shell_first=$(proc_chain_snapshot "$shell_pid" 2>/dev/null || true)
    init_first=$(proc_chain_snapshot 1 2>/dev/null || true)
    read -r shell_starttime shell_ppid <<<"$shell_first"
    read -r init_starttime _ <<<"$init_first"
    [[ "$shell_ppid" == 1 && "$shell_starttime" =~ ^[0-9]+$ &&
      "$init_starttime" =~ ^[0-9]+$ ]] || {
      printf 'isolated mode ancestor chain validation failed: direct PID1 chain is unstable or malformed\n' >&2
      return 75
    }
  else
    timeout_pid=$PPID
    timeout_exe=$(readlink -f -- "/proc/$timeout_pid/exe" 2>/dev/null || true)
    proc_argv0 "$timeout_pid" || {
      printf 'isolated mode ancestor chain validation failed: timeout argv0 is unavailable\n' >&2
      return 75
    }
    timeout_argv0_canonical_allowed "$PROC_ARGV0" "$timeout_exe" || {
      printf 'isolated mode ancestor chain validation failed: timeout argv0/canonical target is not trusted (%s -> %s)\n' \
        "$PROC_ARGV0" "${timeout_exe:-unresolved}" >&2
      return 75
    }
    trusted_timeout_argv0_path "$PROC_ARGV0" || {
      printf 'isolated mode exe trust validation failed: timeout argv0 path is not root-owned and non-writable (%s)\n' \
        "$PROC_ARGV0" >&2
      return 75
    }
    if [[ "$timeout_exe" == /usr/lib/cargo/bin/coreutils ||
      "$timeout_exe" == /usr/lib/cargo/bin/coreutils/timeout ]]; then
      trusted_canonical_regular_file "$timeout_exe" || {
        printf 'isolated mode exe trust validation failed: timeout canonical target is not root-owned, non-writable, regular, and non-symlink (%s)\n' \
          "$timeout_exe" >&2
        return 75
      }
    else
      trusted_system_exe "$timeout_exe" || {
        printf 'isolated mode exe trust validation failed: timeout file is not root-owned and non-writable (%s)\n' \
          "$timeout_exe" >&2
        return 75
      }
    fi
    init_exe=$(readlink -f -- /proc/1/exe 2>/dev/null || true)
    case "$init_exe" in
      /bin/docker-init|/usr/bin/docker-init|/sbin/docker-init|/usr/sbin/docker-init|\
      /bin/tini|/usr/bin/tini|/sbin/tini|/usr/sbin/tini) ;;
      *)
        printf 'isolated mode exe trust validation failed: PID1 is not trusted docker-init/tini (%s)\n' \
          "${init_exe:-unresolved}" >&2
        return 75
        ;;
    esac
    trusted_system_exe "$init_exe" || {
      printf 'isolated mode exe trust validation failed: PID1 file is not root-owned and non-writable (%s)\n' \
        "$init_exe" >&2
      return 75
    }
    shell_first=$(proc_chain_snapshot "$shell_pid" 2>/dev/null || true)
    timeout_first=$(proc_chain_snapshot "$timeout_pid" 2>/dev/null || true)
    init_first=$(proc_chain_snapshot 1 2>/dev/null || true)
    read -r shell_starttime shell_ppid <<<"$shell_first"
    read -r timeout_starttime timeout_ppid <<<"$timeout_first"
    read -r init_starttime init_ppid <<<"$init_first"
    [[ "$shell_ppid" == "$timeout_pid" && "$timeout_ppid" == 1 &&
      "$shell_starttime" =~ ^[0-9]+$ && "$timeout_starttime" =~ ^[0-9]+$ &&
      "$init_starttime" =~ ^[0-9]+$ ]] || {
      printf 'isolated mode ancestor chain validation failed: expected PID1 -> timeout -> bash with no extra wrapper\n' >&2
      return 75
    }
  fi

  /bin/sleep 0.01
  shell_second=$(proc_chain_snapshot "$shell_pid" 2>/dev/null || true)
  init_second=$(proc_chain_snapshot 1 2>/dev/null || true)
  if (( timeout_pid != 0 )); then
    timeout_second=$(proc_chain_snapshot "$timeout_pid" 2>/dev/null || true)
  else
    timeout_second=
  fi
  [[ "$shell_first" == "$shell_second" && "$init_first" == "$init_second" &&
    "$timeout_first" == "$timeout_second" ]] || {
    printf 'isolated mode stability validation failed: shell/timeout/PID1 proc stat changed during double sampling\n' >&2
    return 75
  }
  if (( timeout_pid != 0 )); then
    [[ "$timeout_second" == "$timeout_first" ]] || {
      printf 'isolated mode stability validation failed: timeout ancestor changed during double sampling\n' >&2
      return 75
    }
  fi
  [[ -x "$REAL_SETPRIV" && ! -L "$REAL_SETPRIV" ]] || {
    printf 'isolated mode requires a trusted non-symlink setpriv\n' >&2
    return 75
  }
  [[ "$($REAL_STAT -Lc '%F %u %a' -- "$REAL_SETPRIV" 2>/dev/null)" == 'regular file 0 755' ||
    "$($REAL_STAT -Lc '%F %u %a' -- "$REAL_SETPRIV" 2>/dev/null)" == 'regular file 0 750' ||
    "$($REAL_STAT -Lc '%F %u %a' -- "$REAL_SETPRIV" 2>/dev/null)" == 'regular file 0 700' ]] || {
    printf 'isolated mode rejected untrusted setpriv ownership or mode\n' >&2
    return 75
  }
  case "$(readlink -f -- "$REAL_SETPRIV" 2>/dev/null || true)" in
    "$ROOT"/*|'')
      printf 'isolated mode rejected workspace-controlled setpriv\n' >&2
      return 75
      ;;
  esac
  pid_ns_self=$($REAL_STAT -Lc '%i' /proc/self/ns/pid 2>/dev/null || true)
  pid_ns_init=$($REAL_STAT -Lc '%i' /proc/1/ns/pid 2>/dev/null || true)
  [[ "$pid_ns_self" =~ ^[0-9]+$ && "$pid_ns_self" == "$pid_ns_init" ]] || {
    printf 'isolated mode could not verify the PID namespace boundary\n' >&2
    return 75
  }
  mnt_ns_self=$($REAL_STAT -Lc '%i' /proc/self/ns/mnt 2>/dev/null || true)
  mnt_ns_init=$($REAL_STAT -Lc '%i' /proc/1/ns/mnt 2>/dev/null || true)
  [[ "$mnt_ns_self" =~ ^[0-9]+$ && "$mnt_ns_self" == "$mnt_ns_init" ]] || {
    printf 'isolated mode mount namespace mismatch: current=%s pid1=%s\n' \
      "${mnt_ns_self:-unresolved}" "${mnt_ns_init:-unresolved}" >&2
    return 75
  }
  [[ -d /proc/1/root && -x /proc/1/root ]] || {
    printf 'isolated mode rootfs path unavailable or not traversable: /proc/1/root\n' >&2
    return 75
  }
  [[ -r /proc/1/mountinfo ]] || {
    printf 'isolated mode mountinfo unavailable: /proc/1/mountinfo is not readable\n' >&2
    return 75
  }
  if ! mountinfo_text=$(< /proc/1/mountinfo); then
    printf 'isolated mode mountinfo unreadable: /proc/1/mountinfo\n' >&2
    return 75
  fi
  [[ -n "$mountinfo_text" ]] || {
    printf 'isolated mode mountinfo read empty: /proc/1/mountinfo\n' >&2
    return 75
  }
  mountinfo_lookup "$mountinfo_text" / || {
    printf 'isolated mode mountinfo root entry missing or malformed\n' >&2
    return 75
  }
  root_fstype=$MOUNTINFO_FSTYPE
  printf 'isolated root mount fstype=%s\n' "$root_fstype" >&2
  case "$root_fstype" in
    overlay|overlayfs|fuse.overlayfs|aufs|btrfs|zfs) ;;
    *) printf 'isolated root mount uses unlisted fstype=%s\n' "$root_fstype" >&2; return 75 ;;
  esac
  mountinfo_lookup "$mountinfo_text" /proc || {
    printf 'isolated mode mountinfo /proc entry missing or malformed\n' >&2
    return 75
  }
  proc_fstype=$MOUNTINFO_FSTYPE
  [[ "$proc_fstype" == proc ]] || {
    printf 'isolated mode /proc mount has invalid fstype=%s (expected proc)\n' \
      "$proc_fstype" >&2
    return 75
  }
  mountinfo_lookup "$mountinfo_text" /workspace/src || {
    printf 'isolated mode exact /workspace/src mountpoint is missing or malformed\n' >&2
    return 75
  }
  workspace_mount_options=$MOUNTINFO_MOUNT_OPTIONS
  mountinfo_options_include "$workspace_mount_options" ro || {
    printf 'isolated mode /workspace/src mount options lack ro: %s\n' \
      "$workspace_mount_options" >&2
    return 75
  }
  mountinfo_options_include "$workspace_mount_options" rw && {
    printf 'isolated mode /workspace/src mount options contain rw: %s\n' \
      "$workspace_mount_options" >&2
    return 75
  }
  dockerenv_stat_parser_pure_tests || {
    printf 'isolated mode /.dockerenv parser pure tests failed\n' >&2
    return 75
  }
  if dockerenv_stat=$($REAL_STAT -Lc '%F|%u|%a' -- /proc/1/root/.dockerenv 2>/dev/null); then
    dockerenv_stat_rc=0
  else
    dockerenv_stat_rc=$?
  fi
  (( dockerenv_stat_rc == 0 )) || {
    printf 'isolated mode /.dockerenv stat failed: rc=%s\n' "$dockerenv_stat_rc" >&2
    return 75
  }
  [[ ! -L /proc/1/root/.dockerenv && -f /proc/1/root/.dockerenv &&
    -n "$dockerenv_stat" ]] || {
    printf 'isolated mode /.dockerenv is missing, symlinked, or not a regular file\n' >&2
    return 75
  }
  dockerenv_stat_result_parse_strict "$dockerenv_stat_rc" "$dockerenv_stat" || {
    printf 'isolated mode /.dockerenv has invalid type or owner: %s\n' \
      "$dockerenv_stat" >&2
    return 75
  }
  dockerenv_mode_value=$DOCKERENV_MODE_VALUE
  (( (dockerenv_mode_value & 18) == 0 )) || {
    printf 'isolated mode /.dockerenv is group/other writable: mode=%s\n' \
      "$DOCKERENV_MODE" >&2
    return 75
  }
  if ! cgroup_text=$(< /proc/self/cgroup); then
    printf 'isolated mode cgroup content is unreadable: /proc/self/cgroup\n' >&2
    return 75
  fi
  [[ -n "$cgroup_text" ]] || {
    printf 'isolated mode cgroup content is empty: /proc/self/cgroup\n' >&2
    return 75
  }
  cgroup_parse_strict "$cgroup_text" || {
    printf 'isolated mode cgroup syntax invalid or mixed: %s\n' "$cgroup_text" >&2
    return 75
  }
  if [[ "$cgroup_text" =~ (docker|kubepods|containerd|libpod|podman) ]]; then
    printf 'isolated cgroup diagnostic: recognizable container runtime token present\n' >&2
  else
    printf 'isolated cgroup diagnostic: no docker/containerd token; valid cgroup syntax accepted\n' >&2
  fi
  # These checks are isolation prerequisites for destructive fixture cleanup.
  # The external Docker invocation supplies the host-isolation contract; this
  # container can validate only its own contract and cannot prove that its PID
  # or mount namespace differs from the host namespace.
}

uid_in_use_by_proc() {
  local wanted=$1 entry uid_line uid
  for entry in /proc/[0-9]*; do
    [[ -d "$entry" ]] || { [[ ! -e "$entry" ]] && continue; return 2; }
    [[ -r "$entry/status" ]] || return 2
    uid_line=$(awk '/^Uid:/{print $2" "$3" "$4" "$5; exit}' "$entry/status" 2>/dev/null) || return 2
    [[ -n "$uid_line" ]] || return 2
    for uid in $uid_line; do [[ "$uid" == "$wanted" ]] && return 0; done
  done
  return 1
}

uid_database_lookup() {
  local uid=$1 database_file database_match database_rc

  # Do not use an END exit status here.  An awk END block can overwrite the
  # non-zero status produced when an input database cannot be opened.  A
  # successful scan prints a marker only for a match; the shell then maps an
  # empty successful result to the explicit no-match state 1.
  for database_file in /etc/passwd /etc/group; do
    if database_match=$(awk -F: -v uid="$uid" \
      '$1 == uid { print "uid-match"; exit 0 }' "$database_file" 2>/dev/null); then
      [[ -z "$database_match" ]] || return 0
      continue
    else
      database_rc=$?
      case "$database_rc" in
        1) continue ;;
        *) return "$database_rc" ;;
      esac
    fi
  done
  return 1
}

uid_is_unused() {
  local uid=$1 proc_rc current_uid database_rc
  [[ "$uid" =~ ^(6[0-4][0-9]{3}|65000)$ ]] || return 1
  current_uid=$(id -u) || return 75
  [[ "$uid" != "$current_uid" ]] || return 1
  if uid_database_lookup "$uid"; then
    database_rc=0
  else
    database_rc=$?
  fi
  case "$database_rc" in
    0) return 1 ;;
    1) : ;;
    2|74|75) return 75 ;;
    *) return 75 ;;
  esac
  if uid_in_use_by_proc "$uid"; then
    proc_rc=0
  else
    proc_rc=$?
  fi
  case "$proc_rc" in
    0) return 1 ;;
    1) : ;;
    2|74|75) return 75 ;;
    *) return 75 ;;
  esac
  if [[ ! -e "/tmp/frp-xudp-recovery-uid-$uid" &&
    ! -L "/tmp/frp-xudp-recovery-uid-$uid" &&
    ! -e "$TEST_DIR/hostile-$uid" &&
    ! -L "$TEST_DIR/hostile-$uid" ]]; then
    return 0
  fi
  return 1
}

choose_unused_uid_in_range() {
  local first=${1-} last=${2-} uid excluded
  local -a excluded_uids=()
  (( $# >= 2 )) || return 75
  shift 2
  (( $# <= 8 )) || return 75
  [[ "$first" =~ ^(6[0-4][0-9]{3}|65000)$ ]] || return 75
  [[ "$last" =~ ^(6[0-4][0-9]{3}|65000)$ ]] || return 75
  (( 10#$first <= 10#$last )) || return 75
  for excluded in "$@"; do
    if [[ ! "$excluded" =~ ^(6[0-4][0-9]{3}|65000)$ ]]; then
      printf 'isolated mode refused an invalid excluded UID: %s\n' "$excluded" >&2
      return 75
    fi
    excluded_uids+=("$excluded")
  done
  for ((uid = 10#$first; uid <= 10#$last; uid++)); do
    for excluded in "${excluded_uids[@]}"; do
      [[ "$uid" == "$excluded" ]] && continue 2
    done
    if uid_is_unused "$uid"; then
      printf '%s\n' "$uid"
      return 0
    else
      local unused_rc=$?
      case "$unused_rc" in
        1) continue ;;
        *)
          printf 'isolated mode UID database or availability check failed for %s (rc=%s)\n' \
            "$uid" "$unused_rc" >&2
          return 75
          ;;
      esac
    fi
  done
  printf 'isolated mode could not reserve an unused high UID\n' >&2
  return 75
}

choose_unused_uid() {
  (( $# <= 2 )) || return 75
  choose_unused_uid_in_range 60000 65000 "$@"
}

uid_recheck_before_setpriv() {
  local uid=$1 expected_root=${2-} proc_rc current_uid database_rc
  [[ "$uid" =~ ^(6[0-4][0-9]{3}|65000)$ ]] || return 1
  current_uid=$(id -u) || return 1
  [[ "$uid" != "$current_uid" ]] || return 1
  if uid_database_lookup "$uid"; then
    database_rc=0
  else
    database_rc=$?
  fi
  case "$database_rc" in
    0) return 1 ;;
    1) : ;;
    *) return 1 ;;
  esac
  if uid_in_use_by_proc "$uid"; then
    proc_rc=0
  else
    proc_rc=$?
  fi
  case "$proc_rc" in
    0) return 1 ;;
    1) : ;;
    2) return 1 ;;
    *) return 1 ;;
  esac
  if [[ -n "$expected_root" ]]; then
    [[ -e "$expected_root" || -L "$expected_root" ]] || return 1
  else
    [[ ! -e "/tmp/frp-xudp-recovery-uid-$uid" &&
      ! -L "/tmp/frp-xudp-recovery-uid-$uid" ]] || return 1
  fi
}

uid_selection_pure_tests() {
  (
    set -Eeuo pipefail

    uid_is_unused() {
      [[ "$1" == 60000 || "$1" == 60001 || "$1" == 60002 ]]
    }

    first=$(choose_unused_uid_in_range 60000 60004) || exit 1
    second=$(choose_unused_uid_in_range 60000 60004 "$first") || exit 1
    third=$(choose_unused_uid_in_range 60000 60004 "$first" "$second") || exit 1
    [[ "$first" == 60000 && "$second" == 60001 && "$third" == 60002 &&
      "$first" != "$second" && "$first" != "$third" && "$second" != "$third" ]] || exit 1

    for malformed in '' 59999 65001 060000 +60000 -1 abc 6000 600000; do
      if choose_unused_uid_in_range "$malformed" 60004 >/dev/null 2>&1; then
        exit 1
      else
        malformed_rc=$?
      fi
      [[ "$malformed_rc" == 75 ]] || exit 1
      if choose_unused_uid_in_range 60000 "$malformed" >/dev/null 2>&1; then
        exit 1
      else
        malformed_rc=$?
      fi
      [[ "$malformed_rc" == 75 ]] || exit 1
      if choose_unused_uid_in_range 60000 60004 "$malformed" >/dev/null 2>&1; then
        exit 1
      else
        malformed_rc=$?
      fi
      [[ "$malformed_rc" == 75 ]] || exit 1
    done
    if choose_unused_uid_in_range 60004 60000 >/dev/null 2>&1; then
      exit 1
    else
      malformed_rc=$?
    fi
    [[ "$malformed_rc" == 75 ]] || exit 1
    if choose_unused_uid_in_range 60000 60004 \
      60000 60001 60002 60003 60004 60000 60001 60002 60003 >/dev/null 2>&1; then
      exit 1
    else
      malformed_rc=$?
    fi
    [[ "$malformed_rc" == 75 ]] || exit 1

    uid_is_unused() {
      [[ "$1" == 60000 ]]
    }
    if choose_unused_uid_in_range 60000 60000 "$first" "$second" >/dev/null 2>&1; then
      exit 1
    else
      exhausted_rc=$?
    fi
    [[ "$exhausted_rc" == 75 ]] || exit 1

    case_test_dir=$($REAL_MKTEMP -d "$TEST_DIR/uid-selection-pure.XXXXXX")
    case_records=()
    for pure_uid in 60000 60001 60002; do
      pure_case="$case_test_dir/hostile-$pure_uid"
      mkdir -- "$pure_case"
      pure_identity=$($REAL_STAT -c '%d:%i' -- "$pure_case")
      case_records+=("$pure_case|$pure_identity")
    done
    for case_record in "${case_records[@]}"; do
      pure_case=${case_record%%|*}
      pure_identity=${case_record#*|}
      [[ "$($REAL_STAT -c '%d:%i' -- "$pure_case")" == "$pure_identity" ]] || exit 1
      "$REAL_RM" -rf -- "$pure_case"
    done
    [[ -z "$(find "$case_test_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]
    "$REAL_RM" -rf -- "$case_test_dir"

    uid_is_unused() {
      return 1
    }
    if choose_unused_uid_in_range 60000 60004 >/dev/null 2>&1; then
      exit 1
    else
      exhausted_rc=$?
    fi
    [[ "$exhausted_rc" == 75 ]]
  )
}

uid_selection_pure_tests

uid_proc_semantics_pure_tests() {
  (
    set -Eeuo pipefail

    # Keep this regression independent of the host's process table and UID
    # database.  The production /proc scanner itself remains unchanged.
    id() {
      [[ "$1" == -u ]] || return 2
      printf '1234\n'
    }
    MOCK_AWK_RC=1
    MOCK_AWK_CALLS="$TEST_DIR/uid-proc-awk.calls"
    : >"$MOCK_AWK_CALLS"
    awk() {
      printf '%s\n' "$MOCK_AWK_RC" >>"$MOCK_AWK_CALLS"
      case "$MOCK_AWK_RC" in
        0)
          printf 'uid-match\n'
          return 0
          ;;
        1)
          return 1
          ;;
        *)
          return "$MOCK_AWK_RC"
          ;;
      esac
    }

    MOCK_PROC_RC=0
    uid_in_use_by_proc() {
      case "$MOCK_PROC_RC:$1" in
        0:60000) return 0 ;;
        2:60000) return 2 ;;
        7:60000) return 7 ;;
        *) return 1 ;;
      esac
    }

    MOCK_PROC_RC=1
    MOCK_AWK_RC=0
    : >"$MOCK_AWK_CALLS"
    if uid_is_unused 60000; then
      exit 1
    else
      database_occupied_rc=$?
    fi
    [[ "$database_occupied_rc" == 1 ]] || exit 1
    : >"$MOCK_AWK_CALLS"
    if choose_unused_uid_in_range 60000 60004 >/dev/null 2>&1; then
      exit 1
    else
      occupied_choose_rc=$?
    fi
    [[ "$occupied_choose_rc" == 75 ]] || exit 1
    mapfile -t awk_calls <"$MOCK_AWK_CALLS"
    [[ ${#awk_calls[@]} == 5 ]] || exit 1

    MOCK_AWK_RC=1
    : >"$MOCK_AWK_CALLS"
    selected=$(choose_unused_uid_in_range 60000 60004)
    [[ "$selected" == 60000 ]] || exit 1
    mapfile -t awk_calls <"$MOCK_AWK_CALLS"
    [[ ${#awk_calls[@]} == 2 ]] || exit 1

    for database_error_rc in 2 7; do
      MOCK_AWK_RC=$database_error_rc
      : >"$MOCK_AWK_CALLS"
      if choose_unused_uid_in_range 60000 60004 >/dev/null 2>&1; then
        exit 1
      else
        database_choose_rc=$?
      fi
      [[ "$database_choose_rc" == 75 ]] || exit 1
      mapfile -t awk_calls <"$MOCK_AWK_CALLS"
      [[ ${#awk_calls[@]} == 1 ]] || exit 1
    done

    MOCK_PROC_RC=0
    MOCK_AWK_RC=0
    : >"$MOCK_AWK_CALLS"
    if uid_recheck_before_setpriv 60000 /tmp; then
      exit 1
    else
      recheck_rc=$?
    fi
    [[ "$recheck_rc" == 1 ]] || exit 1
    mapfile -t awk_calls <"$MOCK_AWK_CALLS"
    [[ ${#awk_calls[@]} == 1 ]] || exit 1

    MOCK_PROC_RC=1
    MOCK_AWK_RC=1
    : >"$MOCK_AWK_CALLS"
    uid_recheck_before_setpriv 60000 /tmp
    mapfile -t awk_calls <"$MOCK_AWK_CALLS"
    [[ ${#awk_calls[@]} == 2 ]] || exit 1

    for database_error_rc in 2 7; do
      MOCK_AWK_RC=$database_error_rc
      : >"$MOCK_AWK_CALLS"
      if uid_recheck_before_setpriv 60000 /tmp; then
        exit 1
      else
        recheck_rc=$?
      fi
      [[ "$recheck_rc" == 1 ]] || exit 1
      mapfile -t awk_calls <"$MOCK_AWK_CALLS"
      [[ ${#awk_calls[@]} == 1 ]] || exit 1
    done
  )
}

uid_proc_semantics_pure_tests

clear_fixture_markers() {
  local file relative file_stat file_kind file_links test_dir_stat
  local rc=0

  test_dir_stat=$("$REAL_STAT" -c '%F' -- "$TEST_DIR" 2>/dev/null) || {
    printf 'marker cleanup refused an unreadable TEST_DIR: %s\n' "$TEST_DIR" >&2
    return 1
  }
  [[ "$test_dir_stat" == directory && "$TEST_DIR" != */ ]] || {
    printf 'marker cleanup refused an invalid TEST_DIR: %s\n' "$TEST_DIR" >&2
    return 1
  }

  for file in "$@"; do
    if [[ -z "$file" || "$file" != "$TEST_DIR/"* ]]; then
      printf 'marker cleanup refused a path outside TEST_DIR: %s\n' "$file" >&2
      rc=1
      continue
    fi
    relative=${file#"$TEST_DIR/"}
    if [[ -z "$relative" || "$relative" == */* || "$relative" == . ||
      "$relative" == .. ]]; then
      printf 'marker cleanup refused a non-leaf marker path: %s\n' "$file" >&2
      rc=1
      continue
    fi
    # Missing markers are the normal idempotent case. Broken symlinks are not.
    if [[ ! -e "$file" && ! -L "$file" ]]; then
      continue
    fi
    if [[ -L "$file" ]]; then
      printf 'marker cleanup refused a symlink: %s\n' "$file" >&2
      rc=1
      continue
    fi
    file_stat=$("$REAL_STAT" -c '%F|%h' -- "$file" 2>/dev/null) || {
      printf 'marker cleanup refused an unreadable marker: %s\n' "$file" >&2
      rc=1
      continue
    }
    IFS='|' read -r file_kind file_links <<<"$file_stat"
    if [[ "$file_kind" != 'regular file' || "$file_links" != 1 ]]; then
      printf 'marker cleanup refused a non-single-link regular file: %s\n' "$file" >&2
      rc=1
      continue
    fi
    # Recheck immediately before unlinking so a replacement cannot turn this
    # into an operation on a symlink or hardlink after the first inspection.
    file_stat=$("$REAL_STAT" -c '%F|%h' -- "$file" 2>/dev/null) || {
      printf 'marker cleanup refused a changed marker: %s\n' "$file" >&2
      rc=1
      continue
    }
    IFS='|' read -r file_kind file_links <<<"$file_stat"
    if [[ "$file_kind" != 'regular file' || "$file_links" != 1 ]]; then
      printf 'marker cleanup refused a replaced marker: %s\n' "$file" >&2
      rc=1
      continue
    fi
    "$REAL_RM" -f -- "$file" || rc=1
    [[ ! -e "$file" && ! -L "$file" ]] || {
      printf 'marker cleanup could not remove exact file: %s\n' "$file" >&2
      rc=1
    }
  done
  return "$rc"
}

reset_test_process_registry() {
  TEST_PIDS=()
  TEST_CHILD_PIDS=()
  TEST_PGIDS=()
  TEST_CHILD_STATUS=()
  TEST_PID_STARTTIME=()
  TEST_PID_PGID=()
  TEST_PROTECTED_PIDS=()
}

write_eligible_report() {
  local file=$1 scenario=$2
  cat >"$file" <<EOF
provenance_schema=1
scenario=$scenario
git_head=0123456789012345678901234567890123456789
git_tree=abcdefabcdefabcdefabcdefabcdefabcdefabcd
worktree_dirty=false
status_digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
status_entries=0
required_files_valid=true
required_files_missing=none
build_source=current-worktree
build_started_at_utc=2026-01-01T00:00:00Z
frpc_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
frps_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
frpc_config_sha256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
frps_config_sha256=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
visitor_config_sha256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
docker_image_server=sha256:1111111111111111111111111111111111111111111111111111111111111111
docker_image_proxy=sha256:2222222222222222222222222222222222222222222222222222222222222222
docker_image_visitor=sha256:3333333333333333333333333333333333333333333333333333333333333333
release_eligible=true
EOF
  if [[ "$scenario" == pmtud ]]; then
    cat >>"$file" <<'EOF'
default_frpc_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
default_frps_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
experiment_frpc_sha256=1111111111111111111111111111111111111111111111111111111111111111
experiment_frps_sha256=2222222222222222222222222222222222222222222222222222222222222222
docker_image_id=sha256:4444444444444444444444444444444444444444444444444444444444444444
pmtud_inputs_present=true
pmtud_default_result=PASS
pmtud_experiment_result=PASS
pmtud_default_disabled=true
pmtud_experiment_enabled=true
EOF
  fi
  printf 'RESULT=PASS exit_code=0 detail=synthetic\n' >>"$file"
}

# Pure parser used by the generated authority-signer checks.  It only reads a
# file and validates bytes; it does not inspect /proc, start processes, or
# send signals.  Keep this separate so malformed marker tests remain pure.
validate_marker_phase_values() {
  local phase=$1 result_rc=$2 business_pid=$3 business_pgid=$4 business_starttime=$5
  case "$phase" in
    supervisor-ready)
      [[ "$result_rc" == 0 && "$business_pid" == 0 &&
        "$business_pgid" == 0 && "$business_starttime" == 0 ]] ;;
    business-starting)
      [[ "$result_rc" == 0 && "$business_pid" =~ ^[1-9][0-9]*$ &&
        "$business_pgid" == 0 && "$business_starttime" =~ ^[1-9][0-9]*$ ]] ;;
    business-ready|body-running|body-success)
      [[ "$result_rc" == 0 && "$business_pid" =~ ^[1-9][0-9]*$ &&
        "$business_pgid" =~ ^[1-9][0-9]*$ &&
        "$business_starttime" =~ ^[1-9][0-9]*$ ]] ;;
    business-exited|body-failed)
      [[ "$result_rc" =~ ^[1-9][0-9]*$ &&
        "$business_pid" =~ ^[1-9][0-9]*$ &&
        "$business_pgid" =~ ^[1-9][0-9]*$ &&
        "$business_starttime" =~ ^[1-9][0-9]*$ ]] ;;
    timeout)
      [[ "$result_rc" == "$RECOVERY_RC_TIMEOUT" &&
        "$business_pid" =~ ^[1-9][0-9]*$ &&
        "$business_pgid" =~ ^[1-9][0-9]*$ &&
        "$business_starttime" =~ ^[1-9][0-9]*$ ]] ;;
    *) return 1 ;;
  esac
}

parse_authority_marker_file() {
  local file=$1 line key value count=0
  local -A seen=()
  local -a required=(phase lock_inode result_rc supervisor_pid supervisor_pgid
    supervisor_starttime business_pid business_pgid business_starttime)
  [[ -f "$file" && ! -L "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" && "$line" != *$'\r' && "$line" == *=* ]] || return 1
    [[ "$line" != *=*=* ]] || return 1
    key=${line%%=*}
    value=${line#*=}
    [[ "$key" =~ ^[a-z_]+$ && -n "$value" ]] || return 1
    [[ -z ${seen[$key]+x} ]] || return 1
    case "$key" in
      phase|lock_inode|result_rc|supervisor_pid|supervisor_pgid|supervisor_starttime|business_pid|business_pgid|business_starttime) ;;
      *) return 1 ;;
    esac
    seen[$key]=$value
    count=$((count + 1))
  done <"$file"
  [[ "$count" == 9 ]] || return 1
  for key in "${required[@]}"; do
    [[ -n ${seen[$key]+x} ]] || return 1
  done
  [[ ${seen[phase]} =~ ^(supervisor-ready|business-starting|business-ready|business-exited|body-running|body-success|body-failed|timeout)$ &&
    ${seen[lock_inode]} =~ ^[1-9][0-9]*:[1-9][0-9]*$ &&
    ${seen[result_rc]} =~ ^(0|[1-9][0-9]*)$ &&
    ${seen[supervisor_pid]} =~ ^[1-9][0-9]*$ &&
    ${seen[supervisor_pgid]} =~ ^[1-9][0-9]*$ &&
    ${seen[supervisor_starttime]} =~ ^[1-9][0-9]*$ &&
    ${seen[business_pid]} =~ ^[0-9]+$ &&
    ${seen[business_pgid]} =~ ^[0-9]+$ &&
    ${seen[business_starttime]} =~ ^[0-9]+$ ]] || return 1
  validate_marker_phase_values "${seen[phase]}" "${seen[result_rc]}" \
    "${seen[business_pid]}" "${seen[business_pgid]}" \
    "${seen[business_starttime]}"
}

write_marker_parser_fixture() {
  local file=$1
  cat >"$file" <<'EOF'
phase=business-ready
lock_inode=1:2
result_rc=0
supervisor_pid=11
supervisor_pgid=11
supervisor_starttime=12
business_pid=13
business_pgid=13
business_starttime=14
EOF
}

run_expect() {
  local expected=$1 output=$2
  shift 2
  local rc
  if "$@" >"$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  [[ $rc == "$expected" ]] || {
    printf 'expected exit %s, got %s\n' "$expected" "$rc" >&2
    sed -n '1,240p' "$output" >&2
    if [[ -d ${FAKE_STATE:-} ]]; then
      printf 'fake-state diagnostics:\n' >&2
      find -P "$FAKE_STATE" -mindepth 1 -maxdepth 1 -printf '%f|%y\n' 2>/dev/null |
        sort >&2 || true
      if [[ -f "$FAKE_STATE/current-runtime" ]]; then
        diagnostic_runtime=$(<"$FAKE_STATE/current-runtime")
        printf 'current-runtime=%q\n' "$diagnostic_runtime" >&2
        if [[ "$diagnostic_runtime" =~ ^/tmp/frp-xudp-smoke\.[A-Za-z0-9]{6}$ &&
          -f "$diagnostic_runtime/bin/frpc" ]]; then
          sha256sum -- "$diagnostic_runtime/bin/frpc" >&2 || true
        fi
      fi
      if [[ -f "$FAKE_STATE/inspect-mounts-tamper-value" ]]; then
        printf 'inspect-mounts-tamper-value=%q\n' \
          "$(<"$FAKE_STATE/inspect-mounts-tamper-value")" >&2
      fi
      if [[ -f "$FAKE_STATE/staged-tamper-validation-failed" ]]; then
        sed -n '1,20p' -- "$FAKE_STATE/staged-tamper-validation-failed" >&2 || true
      fi
    fi
    exit 1
  }
}

prebuilt_early_selection_probe

normalize_marker_schema_function() {
  local normalized
  normalized=$(awk '
    NR == 1 {
      if ($0 ~ /^[[:space:]]*(function[[:space:]]+)?(marker_schema|validate_recovery_marker_phase|validate_marker_phase_values)[[:space:]]*(\(\))?[[:space:]]*\{[[:space:]]*$/) {
        print "marker_schema() {"
        next
      }
      if ($0 ~ /^[[:space:]]*(function[[:space:]]+)?(marker_schema|validate_recovery_marker_phase|validate_marker_phase_values)[[:space:]]*(\(\))?[[:space:]]*$/) {
        print "marker_schema()"
        next
      }
      exit 1
    }
    { print }
  ')
  bash -c 'set -e; source /dev/stdin; declare -f marker_schema' <<<"$normalized"
}

assert_marker_schema_parity() {
  local production_schema test_schema
  production_schema=$(awk '
    function header(line) {
      return line ~ /^[[:space:]]*(function[[:space:]]+)?validate_recovery_marker_phase[[:space:]]*(\(\))?[[:space:]]*(\{)?[[:space:]]*$/
    }
    !capture && header($0) {
      capture=1
      print "marker_schema() {"
      if ($0 !~ /\{[[:space:]]*$/) { need_open=1 }
      next
    }
    capture && need_open {
      if ($0 ~ /^[[:space:]]*\{[[:space:]]*$/) { need_open=0; next }
      exit 1
    }
    capture {
      print
      if ($0 ~ /^[[:space:]]*}[[:space:]]*$/) { exit }
    }
  ' "$RECOVERY" | normalize_marker_schema_function)
  test_schema=$(declare -f validate_marker_phase_values | normalize_marker_schema_function)
  [[ -n "$production_schema" && "$production_schema" == "$test_schema" ]] || {
    printf 'recovery marker schema drift between production and test parser\n' >&2
    diff -u <(printf '%s\n' "$production_schema") <(printf '%s\n' "$test_schema") >&2 || true
    return 1
  }
}

run_generated_inner_supervisor_probe() {
  local generated="$TEST_DIR/generated-inner-supervisor"
  local without_schema="$TEST_DIR/generated-inner-supervisor-without-schema"
  local dump_output="$TEST_DIR/generated-inner-dump.out"
  local missing_output="$TEST_DIR/generated-inner-missing-schema.out"
  local valid_output="$TEST_DIR/generated-inner-valid.out"
  local valid_marker="$TEST_DIR/generated-inner-valid.marker"
  local lock_path="/tmp/frp-xudp-recovery-uid-$(id -u)"
  local missing_ready="$TEST_DIR/generated-inner-missing.ready"
  local valid_ready="$TEST_DIR/generated-inner-valid.ready"
  local inner_pid inner_rc=0 ready_seen=0 i

  assert_marker_schema_parity
  run_expect 0 "$dump_output" /usr/bin/timeout --foreground 5 env \
    FRP_XUDP_TEST_DUMP_INNER_SCRIPT=1 bash "$RECOVERY" --existing
  awk 'NR == 1 { found=($0 ~ /^validate_recovery_marker_phase[[:space:]]*\(\)$/) }
    END { exit(found ? 0 : 1) }' "$generated" 2>/dev/null || {
    # The dump command writes directly to stdout; this copy keeps the probe
    # assertions below independent from the command output capture helper.
    cp -- "$dump_output" "$generated"
  }
  [[ -s "$generated" ]] || {
    printf 'generated inner supervisor script is empty\n' >&2
    return 1
  }
  cp -- "$dump_output" "$generated"
  /usr/bin/timeout --foreground 5 /bin/bash -n "$generated"

  # Remove the injected function through the generated constant boundary.  A
  # missing function header or boundary is a fixture-construction error.
  awk '
    function is_header(line) {
      return line ~ /^[[:space:]]*(function[[:space:]]+)?validate_recovery_marker_phase[[:space:]]*(\(\))?[[:space:]]*(\{)?[[:space:]]*$/
    }
    !header_seen && is_header($0) { header_seen=1; next }
    header_seen && $0 ~ /^RECOVERY_RC_INTERNAL=/ { boundary_seen=1; emit=1 }
    emit { print }
    END {
      if (!header_seen || !boundary_seen) exit 2
    }
  ' "$generated" >"$without_schema" || {
    printf 'generated inner schema removal fixture boundary is invalid\n' >&2
    return 2
  }
  [[ $(sed -n '1p' "$without_schema") =~ ^RECOVERY_RC_INTERNAL= ]] || {
    printf 'generated inner schema removal has unexpected first line\n' >&2
    return 1
  }
  [[ $(sed -n '2p' "$without_schema") == 'export RECOVERY_RC_INTERNAL' ]] || {
    printf 'generated inner schema removal has unexpected export line\n' >&2
    return 1
  }
  grep -Fq 'set -Eeuo pipefail' "$without_schema" || {
    printf 'generated inner schema removal lost set-e mode\n' >&2
    return 1
  }
  ! grep -Eq '^validate_recovery_marker_phase[[:space:]]*\(\)' "$without_schema" || {
    printf 'generated inner schema removal retained validator header\n' >&2
    return 1
  }
  rm -f -- "$missing_ready"
  run_expect 74 "$missing_output" env \
    RECOVERY_RC_INTERNAL=74 RECOVERY_RC_TIMEOUT="$RECOVERY_RC_TIMEOUT" \
    PATH=/usr/bin:/bin /usr/bin/setsid /bin/bash -c "$(<"$without_schema")" \
    _ "$lock_path" "$missing_ready" /bin/false --existing
  require_contains "$missing_output" 'validate_recovery_marker_phase: command not found'
  [[ ! -e "$missing_ready" ]] || {
    printf 'schema-free inner supervisor unexpectedly published a marker\n' >&2
    return 1
  }

  # Execute the actual generated script with a harmless /bin/false business
  # command.  The probe stops at the first supervisor-ready marker, before any
  # report or Docker path can be entered, and validates the marker bytes with
  # the same parser used by the suite.
  rm -f -- "$valid_ready" "$valid_marker"
  env RECOVERY_RC_INTERNAL=74 RECOVERY_RC_TIMEOUT="$RECOVERY_RC_TIMEOUT" \
    PATH=/usr/bin:/bin /usr/bin/setsid /bin/bash -c "$(<"$generated")" \
    _ "$lock_path" "$valid_ready" /bin/false --existing \
    >"$valid_output" 2>&1 &
  inner_pid=$!
  for ((i = 0; i < 200; i++)); do
    if [[ -f "$valid_ready" ]]; then
      ready_seen=1
      cp -- "$valid_ready" "$valid_marker"
      break
    fi
    if ! kill -0 "$inner_pid" 2>/dev/null; then
      break
    fi
    /bin/sleep 0.01
  done
  if (( ready_seen )); then
    kill -TERM -- "-$inner_pid" 2>/dev/null || true
  fi
  for ((i = 0; i < 200; i++)); do
    if ! kill -0 "$inner_pid" 2>/dev/null; then
      break
    fi
    /bin/sleep 0.01
  done
  if kill -0 "$inner_pid" 2>/dev/null; then
    kill -KILL -- "-$inner_pid" 2>/dev/null || true
  fi
  wait "$inner_pid" || inner_rc=$?
  if (( ready_seen != 1 )) || [[ ! -s "$valid_marker" ]]; then
    printf 'generated inner supervisor did not publish supervisor-ready (rc=%s)\n' \
      "$inner_rc" >&2
    sed -n '1,160p' "$valid_output" >&2
    return 1
  fi
  parse_authority_marker_file "$valid_marker"
  require_not_contains "$valid_output" 'validate_recovery_marker_phase: command not found'
}

hostile_prepare_case() {
  local uid=$1 case_dir="$TEST_DIR/hostile-$1" fake_udp case_id
  local root="/tmp/frp-xudp-recovery-uid-$uid"
  [[ ! -e "$root" && ! -L "$root" ]] || return 75
  mkdir -- "$case_dir"
  chmod 700 -- "$case_dir"
  chown "$uid:$uid" -- "$case_dir"
  fake_udp="$case_dir/udp_send"
  printf '#!/bin/sh\nexit 0\n' >"$fake_udp"
  chmod 755 -- "$fake_udp"
  chown "$uid:$uid" -- "$fake_udp"
  case_id=$($REAL_STAT -c '%d:%i' -- "$case_dir") || return 1
  ISOLATED_HOSTILE_ROOTS+=("$root")
  ISOLATED_HOSTILE_IDS+=("")
  ISOLATED_HOSTILE_CASE_DIRS+=("$case_dir|$case_id")
  HOSTILE_CASE_DIR=$case_dir
}

hostile_record_root() {
  local root=$1 identity
  identity=$($REAL_STAT -c '%d:%i %F %u %a' -- "$root" 2>/dev/null) || return 1
  ISOLATED_HOSTILE_IDS[${#ISOLATED_HOSTILE_IDS[@]}-1]="$identity"
}

hostile_run_recovery() {
  local uid=$1 case_dir=$2 report=$3
  uid_recheck_before_setpriv "$uid" "/tmp/frp-xudp-recovery-uid-$uid" || return 75
  env -i PATH=/usr/bin:/bin HOME=/ XDG_CONFIG_HOME=/dev/null \
    FRP_XUDP_RECOVERY_REPORT="$report" \
    FRP_XUDP_UDP_SEND="$case_dir/udp_send" \
    "$REAL_SETPRIV" --reuid "$uid" --regid "$uid" --clear-groups \
    /bin/bash "$RECOVERY" --existing
}

hostile_remove_exact_current() {
  local index=$1 root=${ISOLATED_HOSTILE_ROOTS[$1]} expected current
  expected=${ISOLATED_HOSTILE_IDS[$index]}
  current=$($REAL_STAT -c '%d:%i %F %u %a' -- "$root" 2>/dev/null || true)
  [[ "$current" == "$expected" ]] || return 1
  "$REAL_RM" -rf -- "$root"
}

current_uid_lock_snapshot() {
  local path=$1 kind="absent" stat_line
  if [[ -e "$path" || -L "$path" ]]; then
    stat_line=$($REAL_STAT -c '%F %d:%i %u %a' -- "$path") || return 1
    [[ -L "$path" ]] && kind=symlink || kind=present
    printf '%s %s\n' "$kind" "$stat_line"
  else
    printf 'absent\n'
  fi
}

assert_current_uid_lock_unchanged() {
  local after
  after=$(current_uid_lock_snapshot "$lock_root") || return 1
  [[ "$after" == "$CURRENT_UID_LOCK_SNAPSHOT" ]]
}

run_isolated_lock_hostile_checks() {
  local uid_symlink uid_wrong_owner uid_wrong_mode case_dir root report target current expected_lock_root
  assert_isolated_hostile_precondition
  expected_lock_root="/tmp/frp-xudp-recovery-uid-$(id -u)"
  if [[ ${lock_root+x} != x ]]; then
    return 75
  fi
  [[ "$lock_root" == "$expected_lock_root" ]] || return 75
  CURRENT_UID_LOCK_SNAPSHOT=$(current_uid_lock_snapshot "$lock_root") || return 1
  uid_symlink=$(choose_unused_uid) || return 75
  uid_recheck_before_setpriv "$uid_symlink" || return 75
  ISOLATED_HOSTILE_UIDS+=("$uid_symlink")
  uid_wrong_owner=$(choose_unused_uid "$uid_symlink") || return 75
  uid_recheck_before_setpriv "$uid_wrong_owner" || return 75
  [[ "$uid_wrong_owner" != "$uid_symlink" ]] || return 75
  ISOLATED_HOSTILE_UIDS+=("$uid_wrong_owner")
  uid_wrong_mode=$(choose_unused_uid "$uid_symlink" "$uid_wrong_owner") || return 75
  uid_recheck_before_setpriv "$uid_wrong_mode" || return 75
  [[ "$uid_wrong_mode" != "$uid_symlink" && "$uid_wrong_mode" != "$uid_wrong_owner" ]] || return 75
  ISOLATED_HOSTILE_UIDS+=("$uid_wrong_mode")

  hostile_prepare_case "$uid_symlink"
  case_dir=$HOSTILE_CASE_DIR
  root="/tmp/frp-xudp-recovery-uid-$uid_symlink"
  target="$case_dir/symlink-target"
  mkdir -- "$target"
  chown "$uid_symlink:$uid_symlink" -- "$target"
  ln -s -- "$target" "$root"
  hostile_record_root "$root"
  report="$case_dir/symlink-report.log"
  run_expect 74 "$TEST_DIR/recovery-lock-symlink.out" \
    hostile_run_recovery "$uid_symlink" "$case_dir" "$report"
  [[ -L "$root" && -d "$target" && ! -e "$report" ]] || return 1
  hostile_remove_exact_current 0
  pass 'isolated spare-UID symlink lock-root is rejected without touching the current-UID lock'

  hostile_prepare_case "$uid_wrong_owner"
  case_dir=$HOSTILE_CASE_DIR
  root="/tmp/frp-xudp-recovery-uid-$uid_wrong_owner"
  mkdir -- "$root"
  chown "$uid_symlink:$uid_symlink" -- "$root"
  chmod 700 -- "$root"
  hostile_record_root "$root"
  report="$case_dir/wrong-owner-report.log"
  run_expect 74 "$TEST_DIR/recovery-lock-wrong-owner.out" \
    hostile_run_recovery "$uid_wrong_owner" "$case_dir" "$report"
  [[ -d "$root" && ! -e "$report" ]] || return 1
  hostile_remove_exact_current 1
  pass 'isolated spare-UID wrong-owner lock-root is rejected before business execution'

  hostile_prepare_case "$uid_wrong_mode"
  case_dir=$HOSTILE_CASE_DIR
  root="/tmp/frp-xudp-recovery-uid-$uid_wrong_mode"
  mkdir -- "$root"
  chown "$uid_wrong_mode:$uid_wrong_mode" -- "$root"
  chmod 755 -- "$root"
  hostile_record_root "$root"
  report="$case_dir/wrong-mode-report.log"
  run_expect 74 "$TEST_DIR/recovery-lock-wrong-mode.out" \
    hostile_run_recovery "$uid_wrong_mode" "$case_dir" "$report"
  current=$($REAL_STAT -c '%d:%i %F %u %a' -- "$root")
  [[ "$current" == "${ISOLATED_HOSTILE_IDS[2]}" && ! -e "$report" ]] || return 1
  hostile_remove_exact_current 2
  pass 'isolated spare-UID wrong-mode lock-root is rejected and exact objects are cleaned'
  assert_current_uid_lock_unchanged
  pass 'isolated hostile checks preserve the current-UID lock path identity'
  CURRENT_UID_LOCK_SNAPSHOT=
}

base_env=(
  env
  "PATH=$FAKE_BIN:$PATH"
  "FAKE_DOCKER_LOG=$DOCKER_LOG"
  "FAKE_TIMEOUT_LOG=$TIMEOUT_LOG"
  "FAKE_RM_LOG=$RM_LOG"
  "FAKE_RMDIR_LOG=$TEST_DIR/rmdir.log"
  "FAKE_STATE_DIR=$FAKE_STATE"
  "REAL_MKTEMP=$REAL_MKTEMP"
  "REAL_RM=$REAL_RM"
  "REAL_RMDIR=$REAL_RMDIR"
  "REAL_STAT=$REAL_STAT"
  "FRP_XUDP_FRPS="
  "FRP_XUDP_FRPC="
  "FRP_XUDP_UDP_SEND="
  "FRP_XUDP_UDP_ECHO="
  "FAKE_BUILD_LOG=$FAKE_BUILD_LOG"
  "FAKE_LOCK_PATH=/tmp/frp-xudp-recovery-uid-$(id -u)"
)

# Recreate lifecycle tests below consume a complete four-artifact selection.
# The UDP helper paths are supplied per test because some cases intentionally
# exercise zero-artifact build mode or the early 0-or-4 rejection gate.
recreate_binary_prebuilt_env=(
  "FRP_XUDP_FRPS=/tmp/frp-bin/frps"
  "FRP_XUDP_FRPC=/tmp/frp-bin/frpc"
)

# Provenance tests use an isolated repository created inside the Docker test
# environment.  They never point production code at a host-controlled .git.
GIT_FIXTURE="$TEST_DIR/git-fixture"
GIT_SPOOF="$TEST_DIR/git-spoof"
mkdir -p -- "$GIT_FIXTURE" "$GIT_SPOOF"
git -C "$GIT_FIXTURE" init -q
git -C "$GIT_FIXTURE" config user.email test@example.invalid
git -C "$GIT_FIXTURE" config user.name xudp-test
printf 'fixture\n' >"$GIT_FIXTURE/input.txt"
git -C "$GIT_FIXTURE" add -- input.txt
git -C "$GIT_FIXTURE" commit -q -m fixture
git -C "$GIT_SPOOF" init -q
git -C "$GIT_SPOOF" config user.email test@example.invalid
git -C "$GIT_SPOOF" config user.name xudp-test
printf 'spoof\n' >"$GIT_SPOOF/input.txt"
git -C "$GIT_SPOOF" add -- input.txt
git -C "$GIT_SPOOF" commit -q -m spoof

provenance_clean="$TEST_DIR/provenance-clean.txt"
(
  . "$ROOT/dev/test/xudp-provenance.sh"
  GIT_DIR="$GIT_SPOOF/.git" XUDP_GIT_HEAD=forged XUDP_WORKTREE_DIRTY=true
  xudp_collect_git_provenance "$GIT_FIXTURE"
  printf 'head=%s tree=%s dirty=%s entries=%s digest=%s required=%s\n' \
    "$XUDP_GIT_HEAD" "$XUDP_GIT_TREE" "$XUDP_WORKTREE_DIRTY" \
    "$XUDP_STATUS_ENTRIES" "$XUDP_STATUS_DIGEST" "$XUDP_REQUIRED_FILES_VALID"
) >"$provenance_clean"
require_contains "$provenance_clean" '^head=[0-9a-f]{40} tree=[0-9a-f]{40} dirty=false entries=0 digest=[0-9a-f]{64} required=false$'
pass 'clean provenance ignores forged Git environment selectors and fields'

printf 'dirty\n' >"$GIT_FIXTURE/dirty.txt"
provenance_dirty="$TEST_DIR/provenance-dirty.txt"
(
  . "$ROOT/dev/test/xudp-provenance.sh"
  xudp_collect_git_provenance "$GIT_FIXTURE"
  printf 'head=%s tree=%s dirty=%s entries=%s digest=%s required=%s\n' \
    "$XUDP_GIT_HEAD" "$XUDP_GIT_TREE" "$XUDP_WORKTREE_DIRTY" \
    "$XUDP_STATUS_ENTRIES" "$XUDP_STATUS_DIGEST" "$XUDP_REQUIRED_FILES_VALID"
) >"$provenance_dirty"
require_contains "$provenance_dirty" '^head=[0-9a-f]{40} tree=[0-9a-f]{40} dirty=true entries=1 digest=[0-9a-f]{64} required=false$'
pass 'dirty provenance is recorded as ineligible evidence'

provenance_unavailable="$TEST_DIR/provenance-unavailable.txt"
(
  . "$ROOT/dev/test/xudp-provenance.sh"
  xudp_collect_git_provenance "$TEST_DIR/no-git-fixture"
  printf 'head=%s tree=%s dirty=%s entries=%s digest=%s required=%s missing=%s\n' \
    "$XUDP_GIT_HEAD" "$XUDP_GIT_TREE" "$XUDP_WORKTREE_DIRTY" \
    "$XUDP_STATUS_ENTRIES" "$XUDP_STATUS_DIGEST" "$XUDP_REQUIRED_FILES_VALID" \
    "$XUDP_REQUIRED_FILES_MISSING"
) >"$provenance_unavailable"
require_contains "$provenance_unavailable" '^head=unavailable tree=unavailable dirty=unknown entries=unavailable digest=unavailable required=false missing=unavailable$'
pass 'missing Git metadata remains unavailable and cannot become eligible'

required_untracked_fixture="$TEST_DIR/git-required-untracked"
mkdir -p -- "$required_untracked_fixture"
git -C "$required_untracked_fixture" init -q
git -C "$required_untracked_fixture" config user.email test@example.invalid
git -C "$required_untracked_fixture" config user.name xudp-test
printf 'fixture\n' >"$required_untracked_fixture/input.txt"
git -C "$required_untracked_fixture" add -- input.txt
git -C "$required_untracked_fixture" commit -q -m fixture
printf 'required but untracked\n' >"$required_untracked_fixture/required.txt"
[[ -z "$(git -C "$required_untracked_fixture" ls-files --error-unmatch -- required.txt 2>/dev/null)" ]]
[[ "$(git -C "$required_untracked_fixture" status --porcelain=v1 --untracked-files=all -- required.txt)" == '?? required.txt' ]]
[[ -z "$(git -C "$required_untracked_fixture" diff --cached --name-only -- required.txt)" ]]
if git -C "$required_untracked_fixture" cat-file -e HEAD:required.txt 2>/dev/null; then
  printf 'untracked fixture unexpectedly contains required.txt in HEAD\n' >&2
  exit 1
fi
required_untracked_provenance="$TEST_DIR/provenance-required-untracked.txt"
(
  . "$ROOT/dev/test/xudp-provenance.sh"
  XUDP_REQUIRED_FILES=(required.txt)
  xudp_collect_git_provenance "$required_untracked_fixture"
  printf 'required=%s missing=%s eligible=%s\n' \
    "$XUDP_REQUIRED_FILES_VALID" "$XUDP_REQUIRED_FILES_MISSING" \
    "$([[ $XUDP_REQUIRED_FILES_VALID == true ]] && echo true || echo false)"
) >"$required_untracked_provenance"
require_contains "$required_untracked_provenance" '^required=false missing=required.txt eligible=false$'
required_untracked_p2p="$TEST_DIR/summary-required-untracked-p2p.log"
required_untracked_relay="$TEST_DIR/summary-required-untracked-relay.log"
required_untracked_pmtud="$TEST_DIR/summary-required-untracked-pmtud.log"
write_eligible_report "$required_untracked_p2p" p2p
write_eligible_report "$required_untracked_relay" relay
write_eligible_report "$required_untracked_pmtud" pmtud
sed -i \
  -e 's/^required_files_valid=true$/required_files_valid=false/' \
  -e 's/^required_files_missing=none$/required_files_missing=required.txt/' \
  -e 's/^release_eligible=true$/release_eligible=false/' \
  "$required_untracked_p2p"
required_untracked_summary="$TEST_DIR/summary-required-untracked.json"
run_expect 1 "$TEST_DIR/summary-required-untracked.out" bash "$SUMMARY" \
  --output "$required_untracked_summary" --p2p "$required_untracked_p2p" \
  --relay "$required_untracked_relay" --pmtud "$required_untracked_pmtud"
validate_json "$required_untracked_summary"
require_contains "$required_untracked_summary" '^  "release_eligible": false,$'
require_contains "$required_untracked_summary" 'required-files-not-tracked'
pass 'existing untracked required input is ineligible in provenance and release summary'

required_staged_fixture="$TEST_DIR/git-required-staged"
mkdir -p -- "$required_staged_fixture"
git -C "$required_staged_fixture" init -q
git -C "$required_staged_fixture" config user.email test@example.invalid
git -C "$required_staged_fixture" config user.name xudp-test
printf 'fixture\n' >"$required_staged_fixture/input.txt"
git -C "$required_staged_fixture" add -- input.txt
git -C "$required_staged_fixture" commit -q -m fixture
printf 'required but not in HEAD\n' >"$required_staged_fixture/required.txt"
git -C "$required_staged_fixture" add -- required.txt
[[ "$(git -C "$required_staged_fixture" ls-files --error-unmatch -- required.txt)" == required.txt ]]
[[ "$(git -C "$required_staged_fixture" diff --cached --name-only -- required.txt)" == required.txt ]]
if git -C "$required_staged_fixture" cat-file -e HEAD:required.txt 2>/dev/null; then
  printf 'staged fixture unexpectedly contains required.txt in HEAD\n' >&2
  exit 1
fi
required_staged_provenance="$TEST_DIR/provenance-required-staged.txt"
(
  . "$ROOT/dev/test/xudp-provenance.sh"
  XUDP_REQUIRED_FILES=(required.txt)
  xudp_collect_git_provenance "$required_staged_fixture"
  printf 'required=%s missing=%s eligible=%s\n' \
    "$XUDP_REQUIRED_FILES_VALID" "$XUDP_REQUIRED_FILES_MISSING" \
    "$([[ $XUDP_REQUIRED_FILES_VALID == true ]] && echo true || echo false)"
) >"$required_staged_provenance"
require_contains "$required_staged_provenance" '^required=false missing=required.txt eligible=false$'
required_staged_p2p="$TEST_DIR/summary-required-staged-p2p.log"
required_staged_relay="$TEST_DIR/summary-required-staged-relay.log"
required_staged_pmtud="$TEST_DIR/summary-required-staged-pmtud.log"
write_eligible_report "$required_staged_p2p" p2p
write_eligible_report "$required_staged_relay" relay
write_eligible_report "$required_staged_pmtud" pmtud
sed -i \
  -e 's/^required_files_valid=true$/required_files_valid=false/' \
  -e 's/^required_files_missing=none$/required_files_missing=required.txt/' \
  -e 's/^release_eligible=true$/release_eligible=false/' \
  "$required_staged_p2p"
required_staged_summary="$TEST_DIR/summary-required-staged.json"
run_expect 1 "$TEST_DIR/summary-required-staged.out" bash "$SUMMARY" \
  --output "$required_staged_summary" --p2p "$required_staged_p2p" \
  --relay "$required_staged_relay" --pmtud "$required_staged_pmtud"
validate_json "$required_staged_summary"
require_contains "$required_staged_summary" '^  "release_eligible": false,$'
require_contains "$required_staged_summary" 'required-files-not-tracked'
pass 'required input staged but absent from HEAD is ineligible in provenance and release summary'

[[ $(int_marker_phase_allows_signal supervisor-ready) == '' ]]
int_marker_contract_fields_valid supervisor-ready 1:2 1:2 2001 2002 2003 \
  2001 2002 2003 1
# The supervisor-ready marker can be replaced before this poll observes it;
# body-running is the directed regression for that skipped transient phase.
int_marker_contract_fields_valid body-running 1:2 1:2 2001 2002 2003 \
  2001 2002 2003 1
int_marker_contract_fields_valid business-ready 1:2 1:2 2001 2002 2003 \
  2001 2002 2003 1
if int_marker_contract_fields_valid not-started 1:2 1:2 2001 2002 2003 \
  2001 2002 2003 1; then
  printf 'INT marker contract accepted an early unknown phase\n' >&2
  exit 1
fi
for int_terminal_phase in business-exited body-success body-failed timeout; do
  if int_marker_contract_fields_valid "$int_terminal_phase" 1:2 1:2 \
    2001 2002 2003 2001 2002 2003 1; then
    printf 'INT marker contract accepted terminal phase=%s\n' \
      "$int_terminal_phase" >&2
    exit 1
  fi
done
if int_marker_contract_fields_valid body-running 9:9 1:2 2001 2002 2003 \
  2001 2002 2003 1 ||
  int_marker_contract_fields_valid body-running 1:2 1:2 2999 2002 2003 \
    2001 2002 2003 1 ||
  int_marker_contract_fields_valid body-running 1:2 1:2 2001 2999 2003 \
    2001 2002 2003 1 ||
  int_marker_contract_fields_valid body-running 1:2 1:2 2001 2002 2999 \
    2001 2002 2003 1 ||
  int_marker_contract_fields_valid body-running 1:2 1:2 2001 2002 2003 \
    2001 2002 2003 0; then
  printf 'INT marker contract accepted stale or mismatched run identity\n' >&2
  exit 1
fi
pass 'INT barrier accepts a skipped supervisor-ready phase only for the same active run and rejects early, terminal, stale, and mismatched identities'

marker_parser_dir="$TEST_DIR/marker-parser"
mkdir -- "$marker_parser_dir"
marker_valid="$marker_parser_dir/valid"
write_marker_parser_fixture "$marker_valid"
parse_authority_marker_file "$marker_valid"
pass 'pure authority marker parser accepts the canonical marker'

marker_duplicate="$marker_parser_dir/duplicate"
sed '1a phase=business-ready' "$marker_valid" >"$marker_duplicate"
if parse_authority_marker_file "$marker_duplicate"; then exit 1; fi
pass 'pure authority marker parser rejects duplicate fields'

marker_unknown="$marker_parser_dir/unknown"
sed 's/^phase=/unexpected=/' "$marker_valid" >"$marker_unknown"
if parse_authority_marker_file "$marker_unknown"; then exit 1; fi
pass 'pure authority marker parser rejects unknown fields'

marker_missing="$marker_parser_dir/missing"
sed '/^business_starttime=/d' "$marker_valid" >"$marker_missing"
if parse_authority_marker_file "$marker_missing"; then exit 1; fi
pass 'pure authority marker parser rejects missing fields'

marker_malformed="$marker_parser_dir/malformed"
sed 's/^phase=.*/not-a-marker/' "$marker_valid" >"$marker_malformed"
if parse_authority_marker_file "$marker_malformed"; then exit 1; fi
pass 'pure authority marker parser rejects malformed lines'

marker_bad_phase="$marker_parser_dir/bad-phase"
sed 's/^phase=.*/phase=not-a-production-phase/' "$marker_valid" >"$marker_bad_phase"
if parse_authority_marker_file "$marker_bad_phase"; then exit 1; fi
pass 'pure authority marker parser rejects illegal phases'

marker_non_numeric="$marker_parser_dir/non-numeric"
sed 's/^business_pid=.*/business_pid=pid/' "$marker_valid" >"$marker_non_numeric"
if parse_authority_marker_file "$marker_non_numeric"; then exit 1; fi
pass 'pure authority marker parser rejects non-numeric identity fields'

marker_business_result="$marker_parser_dir/business-ready-result"
sed 's/^result_rc=.*/result_rc=9/' "$marker_valid" >"$marker_business_result"
if parse_authority_marker_file "$marker_business_result"; then exit 1; fi
pass 'business-ready authority marker requires result_rc=0'

marker_supervisor="$marker_parser_dir/supervisor-ready"
[[ $(awk '
  /^[[:space:]]*business_pid=0$/ { state=1; next }
  state == 1 && /^[[:space:]]*business_pgid=0$/ { state=2; next }
  state == 2 && /^[[:space:]]*business_starttime=0$/ { count++; state=0; next }
  { state=0 }
  END { print count + 0 }
' "$RECOVERY") == 1 ]] || {
  printf 'xudp-init-assertion-failed reason=production_business_starttime_not_zero\n' >&2
  exit 1
}
sed -e 's/^phase=.*/phase=supervisor-ready/' \
  -e 's/^business_pid=.*/business_pid=0/' \
  -e 's/^business_pgid=.*/business_pgid=0/' \
  -e 's/^business_starttime=.*/business_starttime=0/' \
"$marker_valid" >"$marker_supervisor"
parse_authority_marker_file "$marker_supervisor"
marker_supervisor_result="$marker_parser_dir/supervisor-ready-result"
sed 's/^result_rc=.*/result_rc=9/' "$marker_supervisor" >"$marker_supervisor_result"
if parse_authority_marker_file "$marker_supervisor_result"; then exit 1; fi
marker_supervisor_empty="$marker_parser_dir/supervisor-ready-empty-starttime"
sed 's/^business_starttime=.*/business_starttime=/' "$marker_supervisor" >"$marker_supervisor_empty"
if parse_authority_marker_file "$marker_supervisor_empty"; then exit 1; fi
marker_supervisor_inconsistent="$marker_parser_dir/supervisor-ready-inconsistent"
sed -e 's/^business_starttime=.*/business_starttime=1/' \
  "$marker_supervisor" >"$marker_supervisor_inconsistent"
if parse_authority_marker_file "$marker_supervisor_inconsistent"; then exit 1; fi
run_generated_inner_supervisor_probe
pass 'authority marker parser and generated inner supervisor preserve the production schema'

marker_body_success_result="$marker_parser_dir/body-success-result"
sed -e 's/^phase=.*/phase=body-success/' -e 's/^result_rc=.*/result_rc=9/' \
  "$marker_valid" >"$marker_body_success_result"
if parse_authority_marker_file "$marker_body_success_result"; then exit 1; fi

marker_business_starting="$marker_parser_dir/business-starting"
sed -e 's/^phase=.*/phase=business-starting/' \
  -e 's/^business_pgid=.*/business_pgid=0/' \
  "$marker_valid" >"$marker_business_starting"
parse_authority_marker_file "$marker_business_starting"
marker_business_starting_incomplete="$marker_parser_dir/business-starting-incomplete"
sed -e 's/^business_starttime=.*/business_starttime=/' \
  "$marker_business_starting" >"$marker_business_starting_incomplete"
if parse_authority_marker_file "$marker_business_starting_incomplete"; then exit 1; fi
marker_business_starting_wrong_pgid="$marker_parser_dir/business-starting-wrong-pgid"
sed 's/^business_pgid=.*/business_pgid=13/' "$marker_business_starting" >"$marker_business_starting_wrong_pgid"
if parse_authority_marker_file "$marker_business_starting_wrong_pgid"; then exit 1; fi

marker_business_exited="$marker_parser_dir/business-exited"
sed -e 's/^phase=.*/phase=business-exited/' -e 's/^result_rc=.*/result_rc=9/' \
  "$marker_valid" >"$marker_business_exited"
parse_authority_marker_file "$marker_business_exited"
marker_business_exited_incomplete="$marker_parser_dir/business-exited-incomplete"
sed -e 's/^business_pgid=.*/business_pgid=/' \
  "$marker_business_exited" >"$marker_business_exited_incomplete"
if parse_authority_marker_file "$marker_business_exited_incomplete"; then exit 1; fi

lock_root=/tmp/frp-xudp-recovery-uid-$(id -u)

assert_lock_root_initialization_order() {
  local source_file=$1 assignment_count assignment_line consumer_line
  assignment_count=$(awk '
    /^[[:space:]]*lock_root=\/tmp\/frp-xudp-recovery-uid-\$\(id -u\)$/ { count++ }
    END { print count + 0 }
  ' "$source_file") || return 75
  [[ "$assignment_count" == 1 ]] || return 75
  assignment_line=$(awk '
    /^[[:space:]]*lock_root=\/tmp\/frp-xudp-recovery-uid-\$\(id -u\)$/ { print NR; exit }
  ' "$source_file") || return 75
  consumer_line=$(awk '
    /^[[:space:]]*run_isolated_lock_hostile_checks[[:space:]]*$/ { print NR; exit }
  ' "$source_file") || return 75
  [[ "$assignment_line" =~ ^[0-9]+$ && "$consumer_line" =~ ^[0-9]+$ ]] || return 75
  (( assignment_line < consumer_line )) || return 75
}

trap_cleanup_state_regression() {
  local probe="$TEST_DIR/trap-cleanup-state-probe" output="$TEST_DIR/trap-cleanup-state.out" rc
  : >"$output"
  if (
    # Simulate a caller exporting a stale snapshot before the trap fires.  The
    # mock would mark a path touch if cleanup expanded or inspected lock_root.
    unset lock_root
    CURRENT_UID_LOCK_SNAPSHOT=caller-supplied-snapshot
    current_uid_lock_snapshot() {
      : >"$probe"
      printf 'unexpected-probe-call\n'
      return 99
    }
    set +e
    isolated_hostile_cleanup
    rc=$?
    set -e
    [[ "$rc" == 1 && ! -e "$probe" ]]

    # A correctly initialized exact path still performs the identity check;
    # this mock avoids reading or mutating the real current-UID lock.
    lock_root="/tmp/frp-xudp-recovery-uid-$(id -u)"
    CURRENT_UID_LOCK_SNAPSHOT=expected-snapshot
    current_uid_lock_snapshot() {
      if [[ ${MOCK_LOCK_DRIFT:-0} == 1 ]]; then
        printf 'changed-snapshot\n'
      else
        printf '%s\n' "$CURRENT_UID_LOCK_SNAPSHOT"
      fi
    }
    MOCK_LOCK_DRIFT=0
    isolated_hostile_cleanup
    MOCK_LOCK_DRIFT=1
    set +e
    isolated_hostile_cleanup
    rc=$?
    set -e
    [[ "$rc" == 1 ]]
  ) >"$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  (( rc == 0 )) || {
    sed -n '1,120p' "$output" >&2
    return 1
  }
  return 0
}

assert_lock_root_initialization_order "${BASH_SOURCE[0]}"
trap_cleanup_state_regression

if (( ISOLATED_MODE )); then
  : >"$DOCKER_LOG"
  run_isolated_lock_hostile_checks
fi

recovery_report="$TEST_DIR/recovery-pass.log"
: >"$TIMEOUT_LOG"
run_expect 0 "$TEST_DIR/recovery-pass.out" "${base_env[@]}" \
  FRP_XUDP_RECOVERY_REPORT="$recovery_report" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
  bash "$RECOVERY" --existing
require_contains "$recovery_report" '^packet=existing-3 result=PASS'
require_contains "$recovery_report" '^path=UNCONFIRMED '
require_contains "$recovery_report" '^not_covered=.*5G,Wi-Fi'
require_contains "$recovery_report" '^old_runtime_cleanup_status=NOT_APPLICABLE old_runtime_cleanup_exit_code=0 old_runtime_cleanup_detail=not-evaluated$'
require_contains "$recovery_report" '^current_runtime_cleanup_status=NOT_REQUIRED current_runtime_cleanup_exit_code=0 current_runtime_cleanup_detail=not-required$'
require_contains "$recovery_report" '^cleanup_status=PASS cleanup_exit_code=0 cleanup_detail=old:NOT_APPLICABLE,current:NOT_REQUIRED$'
require_result_once "$recovery_report" PASS 0
require_contains "$recovery_report" '^provenance_schema=1$'
require_contains "$recovery_report" '^git_head=[0-9a-f]{40}$'
require_contains "$recovery_report" '^status_digest=[0-9a-f]{64}$'
require_contains "$recovery_report" '^release_eligible=false$'
[[ $(wc -l <"$TIMEOUT_LOG") == 3 ]]
require_contains "$TIMEOUT_LOG" '^timeout --foreground 15 /.*udp_send 127\.0\.0\.1:9000 existing-1$'
require_not_contains "$TIMEOUT_LOG" ' 15 -- '
require_not_contains "$TEST_DIR/recovery-pass.out" 'internal marker is missing|child-start-unknown|child-state-unknown|child state unknown|outer-state-unknown|marker cleanup could not be proved'
pass 'recovery report persists evidence and one final PASS'

run_expect 64 "$TEST_DIR/timeout-old-layout.out" env \
  FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" FAKE_TIMEOUT_LOG="$TIMEOUT_LOG" \
  "$FAKE_BIN/timeout" --foreground 15 -- "$FAKE_BIN/udp_send" 127.0.0.1:9000 existing-1
pass 'fake timeout rejects a separator after duration'

recovery_fail_report="$TEST_DIR/recovery-fail.log"
run_expect 9 "$TEST_DIR/recovery-fail.out" "${base_env[@]}" \
  FAKE_UDP_FAIL=1 FRP_XUDP_RECOVERY_REPORT="$recovery_fail_report" \
  FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" bash "$RECOVERY" --existing
require_contains "$recovery_fail_report" '^packet=existing-1 result=FAIL exit_code=9'
require_contains "$recovery_fail_report" '^old_runtime_cleanup_status=NOT_APPLICABLE '
require_contains "$recovery_fail_report" '^current_runtime_cleanup_status=NOT_REQUIRED '
require_contains "$recovery_fail_report" '^cleanup_status=PASS cleanup_exit_code=0 cleanup_detail=old:NOT_APPLICABLE,current:NOT_REQUIRED$'
require_result_once "$recovery_fail_report" FAIL 9
pass 'recovery preserves packet failure rc and writes one final FAIL'

cp -- "$recovery_report" "$TEST_DIR/recovery-before.log"
run_expect 1 "$TEST_DIR/recovery-existing.out" "${base_env[@]}" \
  FRP_XUDP_RECOVERY_REPORT="$recovery_report" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
  bash "$RECOVERY" --existing
cmp -- "$recovery_report" "$TEST_DIR/recovery-before.log"
pass 'recovery refuses an existing report leaf'

printf 'symlink-target-unchanged\n' >"$TEST_DIR/recovery-symlink-target.log"
ln -s -- "$TEST_DIR/recovery-symlink-target.log" "$TEST_DIR/recovery-link.log"
run_expect 1 "$TEST_DIR/recovery-symlink.out" "${base_env[@]}" \
  FRP_XUDP_RECOVERY_REPORT="$TEST_DIR/recovery-link.log" \
  FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" bash "$RECOVERY" --existing
[[ $(<"$TEST_DIR/recovery-symlink-target.log") == symlink-target-unchanged ]]
pass 'recovery refuses a symlink report leaf'

printf 'hardlink-source-unchanged\n' >"$TEST_DIR/recovery-hardlink-source.log"
ln -- "$TEST_DIR/recovery-hardlink-source.log" "$TEST_DIR/recovery-hardlink.log"
run_expect 1 "$TEST_DIR/recovery-hardlink.out" "${base_env[@]}" \
  FRP_XUDP_RECOVERY_REPORT="$TEST_DIR/recovery-hardlink.log" \
  FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" bash "$RECOVERY" --existing
[[ $(<"$TEST_DIR/recovery-hardlink-source.log") == hardlink-source-unchanged ]]
[[ $(stat -c %h -- "$TEST_DIR/recovery-hardlink-source.log") == 2 ]]
pass 'recovery refuses an existing hardlink report leaf'

reset_test_process_registry
: >"$DOCKER_LOG"
: >"$DOCKER_LOG"
marker_report="$TEST_DIR/recovery-marker-direct.log"
run_expect 75 "$TEST_DIR/recovery-marker-direct.out" "${base_env[@]}" \
  FRP_XUDP_RECOVERY_REPORT="$marker_report" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
  bash "$RECOVERY" __frp_xudp_recovery_internal_lock_v1 --existing
[[ ! -e "$marker_report" && ! -s "$DOCKER_LOG" ]]
pass 'direct internal marker is rejected without another process holding the lock'

: >"$DOCKER_LOG"
busy_report="$TEST_DIR/recovery-lock-busy.log"
busy_marker="$TEST_DIR/recovery-lock-held"
busy_wait_fifo="$TEST_DIR/recovery-lock-busy.fifo"
mkfifo -m 600 -- "$busy_wait_fifo"
exec {busy_wait_fd}<>"$busy_wait_fifo"
/usr/bin/setsid /bin/bash -c '
  lock_path=$1
  marker=$2
  wait_fifo=$3
  exec {lock_fd}<"$lock_path"
  /usr/bin/flock -E 75 -n "$lock_fd"
  printf held >"$marker"
  trap "exit 143" INT TERM HUP
  exec 7<"$wait_fifo"
  while IFS= read -r _ <&7; do :; done
' sh "$lock_root" "$busy_marker" "$busy_wait_fifo" &
busy_holder=$!
if ! register_test_process_bounded "$busy_holder" 'busy-lock-holder'; then
  stop_test_processes || true
  exit 1
fi
for ((i = 0; i < 100; i++)); do
  [[ -s "$busy_marker" ]] && break
done
[[ -s "$busy_marker" ]]
run_expect 75 "$TEST_DIR/recovery-lock-busy.out" "${base_env[@]}" \
  FRP_XUDP_RECOVERY_REPORT="$busy_report" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
  bash "$RECOVERY" --existing
[[ ! -e "$busy_report" && ! -s "$DOCKER_LOG" ]]
registered_group_kill TERM "${TEST_PID_PGID[$busy_holder]}" || true
registered_pid_kill TERM "$busy_holder" || true
wait "$busy_holder" 2>/dev/null || true
exec {busy_wait_fd}>&-
pass 'real flock competition returns 75 before report or Docker side effects'

reset_test_process_registry
: >"$DOCKER_LOG"
hold_report="$TEST_DIR/recovery-process-group.log"
hold_output_file="$TEST_DIR/recovery-process-group.out"
hold_pid_file="$TEST_DIR/recovery-hold.pid"
hold_fd_file="$TEST_DIR/recovery-hold-fd-count"
hold_descendant_file="$TEST_DIR/recovery-hold-descendants"
hold_child_file="$TEST_DIR/recovery-hold-child.pid"
hold_grandchild_file="$TEST_DIR/recovery-hold-grandchild.pid"
hold_child_fd_file="$TEST_DIR/recovery-hold-child-fd-count"
hold_grandchild_fd_file="$TEST_DIR/recovery-hold-grandchild-fd-count"
term_delivered_file="$TEST_DIR/recovery-term-delivered.log"
term_sentinel_ready="$TEST_DIR/recovery-term-sentinel.ready"
term_caller_sentinel_signal="$TEST_DIR/recovery-term-sentinel.signal"
clear_fixture_markers "$term_delivered_file" "$term_sentinel_ready" "$term_caller_sentinel_signal" \
  "$hold_pid_file" "$hold_fd_file" "$hold_descendant_file" "$hold_child_file" \
  "$hold_grandchild_file" "$hold_child_fd_file" "$hold_grandchild_fd_file"
/usr/bin/setsid /bin/bash -c '
  ready=$1
  signal_file=$2
  printf ready >"$ready"
  on_signal() { printf signal >"$signal_file"; exit 143; }
  trap on_signal INT TERM HUP
  for ((i = 0; i < 6000; i++)); do /bin/sleep 0.05; done
' sh "$term_sentinel_ready" "$term_caller_sentinel_signal" &
term_sentinel=$!
if ! register_test_process_bounded "$term_sentinel" 'term-caller-sentinel'; then
  stop_test_processes || true
  exit 1
fi
for ((i = 0; i < 300; i++)); do
  [[ -s "$term_sentinel_ready" ]] && break
  /bin/sleep 0.01
done
[[ -s "$term_sentinel_ready" && ! -e "$term_caller_sentinel_signal" ]]
set +e
env "PATH=$FAKE_BIN:$PATH" "FAKE_DOCKER_LOG=$DOCKER_LOG" \
  "FAKE_TIMEOUT_LOG=$TIMEOUT_LOG" "FAKE_RM_LOG=$RM_LOG" "FAKE_STATE_DIR=$FAKE_STATE" \
  "REAL_MKTEMP=$REAL_MKTEMP" "REAL_RM=$REAL_RM" "REAL_STAT=$REAL_STAT" \
  "FAKE_BUILD_LOG=$FAKE_BUILD_LOG" "FAKE_LOCK_PATH=$lock_root" \
  "FAKE_UDP_HOLD_PID_FILE=$hold_pid_file" "FAKE_UDP_FD_FILE=$hold_fd_file" \
  "FAKE_UDP_DESCENDANT_PID_FILE=$hold_descendant_file" \
  "FAKE_UDP_CHILD_PID_FILE=$hold_child_file" \
  "FAKE_UDP_GRANDCHILD_PID_FILE=$hold_grandchild_file" \
  "FAKE_UDP_CHILD_FD_FILE=$hold_child_fd_file" \
  "FAKE_UDP_GRANDCHILD_FD_FILE=$hold_grandchild_fd_file" \
  "FAKE_UDP_SIGNAL_DELIVERED_FILE=$term_delivered_file" \
  FRP_XUDP_RECOVERY_REPORT="$hold_report" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
  /usr/bin/setsid bash "$RECOVERY" --existing >"$hold_output_file" 2>&1 &
hold_outer=$!
set -e
if ! register_test_process_bounded "$hold_outer" 'term-recovery-outer'; then
  stop_test_processes || true
  exit 1
fi
if ! wait_for_hold_ready; then
  stop_test_processes || true
  exit 1
fi
pass 'real recovery process group reaches complete readiness before teardown'
for pid_file in "$hold_pid_file" "$hold_child_file" "$hold_grandchild_file"; do
  pid=$(head -n 1 "$pid_file")
  set +e
  register_test_process "$pid"
  register_rc=$?
  set -e
  if (( register_rc != 0 )); then
    report_test_pid_identity "$pid"
    printf 'register_test_process pid=%s rc=%s\n' "$pid" "$register_rc" >&2
    dump_hold_diagnostics
    exit 2
  fi
done
set +e
registered_pid_kill TERM "$hold_outer"
term_signal_rc=$?
set -e
if (( term_signal_rc != 0 )); then
  report_test_pid_identity "$hold_outer"
  printf 'registered_pid_kill signal=TERM pid=%s rc=%s\n' "$hold_outer" \
    "$term_signal_rc" >&2
  dump_hold_diagnostics
  exit 2
fi
set +e
wait "$hold_outer"
hold_rc=$?
set -e
TEST_CHILD_STATUS["$hold_outer"]=$hold_rc
if [[ $hold_rc != 143 ]]; then
  printf 'TERM foreground recovery returned unexpected status: got=%s expected=143 pid=%s\n' \
    "$hold_rc" "$hold_outer" >&2
  dump_hold_diagnostics
  exit 1
fi
for pid_file in "$hold_pid_file" "$hold_child_file" "$hold_grandchild_file"; do
  pid=$(head -n 1 "$pid_file")
  wait_for_process_exit "$pid"
done
require_contains "$term_delivered_file" '^TERM:[0-9]+$'
[[ $(grep -Ec '^TERM:[0-9]+$' "$term_delivered_file") == 3 ]]
kill -0 "$term_sentinel" 2>/dev/null
[[ ! -e "$term_caller_sentinel_signal" ]]
pass 'TERM reaches worker, child and grandchild without killing the caller sentinel'
[[ $(<"$hold_fd_file") == 0 && $(<"$hold_child_fd_file") == 0 &&
  $(<"$hold_grandchild_fd_file") == 0 ]]
registered_pid_kill TERM "$term_sentinel"
set +e
wait "$term_sentinel"
term_sentinel_rc=$?
set -e
TEST_CHILD_STATUS["$term_sentinel"]=$term_sentinel_rc
[[ $term_sentinel_rc == 143 && -e "$term_caller_sentinel_signal" ]]
relock_report="$TEST_DIR/recovery-relock-after-term.log"
run_expect 0 "$TEST_DIR/recovery-relock-after-term.out" "${base_env[@]}" \
  FRP_XUDP_RECOVERY_REPORT="$relock_report" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
  bash "$RECOVERY" --existing
require_result_once "$relock_report" PASS 0
pass 'TERM keeps lock FD counts at zero and permits immediate relock'

# The TERM case above has already proved immediate relock. The INT run keeps
# the validated lock object and only resets its own fixture state.
: >"$DOCKER_LOG"
hold_report="$TEST_DIR/recovery-process-group-int.log"
hold_pid_file="$TEST_DIR/recovery-int-hold.pid"
hold_starttime_file="$TEST_DIR/recovery-int-hold.starttime"
hold_fd_file="$TEST_DIR/recovery-int-hold-fd-count"
hold_descendant_file="$TEST_DIR/recovery-int-hold-descendants"
hold_child_file="$TEST_DIR/recovery-int-hold-child.pid"
hold_grandchild_file="$TEST_DIR/recovery-int-hold-grandchild.pid"
hold_child_fd_file="$TEST_DIR/recovery-int-hold-child-fd-count"
hold_grandchild_fd_file="$TEST_DIR/recovery-int-hold-grandchild-fd-count"
int_delivered_file="$TEST_DIR/recovery-int-delivered.log"
int_process_diagnostic="$TEST_DIR/recovery-int-process-diagnostic.log"
int_sentinel_ready="$TEST_DIR/recovery-int-sentinel.ready"
int_caller_sentinel_signal="$TEST_DIR/recovery-int-sentinel.signal"

int_outer_pid_file="$TEST_DIR/recovery-int-foreground.pid"
int_outer_pgid_file="$TEST_DIR/recovery-int-foreground.pgid"
int_outer_starttime_file="$TEST_DIR/recovery-int-foreground.starttime"
int_signaler_marker="$TEST_DIR/recovery-int-signaler.sent"
int_signaler_failed="$TEST_DIR/recovery-int-signaler.failed"
int_signaler_stage="$TEST_DIR/recovery-int-signaler.stage"
int_signaler_diagnostic="$TEST_DIR/recovery-int-signaler.out"
int_wrapper="$TEST_DIR/recovery-int-foreground-wrapper"
int_signaler="$TEST_DIR/recovery-int-signaler"
int_watchdog="$TEST_DIR/recovery-int-watchdog"
int_handshake_helper="$TEST_DIR/recovery-int-handshake-helper"
int_signaler_token="int-signaler-$RANDOM-$PPID"
int_watchdog_token="int-watchdog-$RANDOM-$PPID"
int_signaler_ready="$TEST_DIR/recovery-int-signaler.ready"
int_signaler_release="$TEST_DIR/recovery-int-signaler.release"
int_signaler_abort="$TEST_DIR/recovery-int-signaler.abort"
int_watchdog_ready="$TEST_DIR/recovery-int-watchdog.ready"
int_watchdog_release="$TEST_DIR/recovery-int-watchdog.release"
int_watchdog_abort="$TEST_DIR/recovery-int-watchdog.abort"
int_watchdog_timeout_marker="$TEST_DIR/recovery-int-watchdog-timeout"
int_watchdog_term_sent="$TEST_DIR/recovery-int-watchdog-term-sent"
int_watchdog_kill_sent="$TEST_DIR/recovery-int-watchdog-kill-sent"
int_watchdog_stage="$TEST_DIR/recovery-int-watchdog.stage"
int_supervisor_ready="$TEST_DIR/recovery-int-supervisor-held"
int_signaler_pid_file="$TEST_DIR/recovery-int-signaler.pid"
int_signaler_pgid_file="$TEST_DIR/recovery-int-signaler.pgid"
int_signaler_starttime_file="$TEST_DIR/recovery-int-signaler.starttime"
int_watchdog_pid_file="$TEST_DIR/recovery-int-watchdog.pid"
int_watchdog_pgid_file="$TEST_DIR/recovery-int-watchdog.pgid"
int_watchdog_starttime_file="$TEST_DIR/recovery-int-watchdog.starttime"
cat >"$int_wrapper" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
pid_file=$1
pgid_file=$2
starttime_file=$3
shift 3
trap - INT TERM HUP
printf '%s\n' "$$" >"$pid_file"
pgid=
for ((i = 0; i < 300; i++)); do
  pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]' || true)
  if [[ "$pgid" =~ ^[0-9]+$ && "$pgid" == "$$" ]]; then
    printf '%s\n' "$pgid" >"$pgid_file"
    break
  fi
  /bin/sleep 0.01
done
[[ "$pgid" == "$$" ]]
stat_line=$(<"/proc/$$/stat")
stat_rest=${stat_line#*') '}
read -r -a stat_fields <<<"$stat_rest"
printf '%s\n' "${stat_fields[19]:-}" >"$starttime_file"
exec "$@"
EOF
chmod 0755 -- "$int_wrapper"

cat >"$int_handshake_helper" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
hs_stat() { stat -Lc '%F|%u|%h|%a' -- "$1" 2>/dev/null; }
hs_atomic() { local file=$1 content=$2 tmp; tmp="${file}.tmp.$$"; printf '%s\n' "$content" >"$tmp"; chmod 0600 -- "$tmp"; mv -f -- "$tmp" "$file"; }
hs_identity() { local line rest; local -a fields=(); line=$(<"/proc/$$/stat") || return 1; rest=${line#*') '}; read -r -a fields <<<"$rest"; HS_STARTTIME=${fields[19]-}; HS_PGID=${fields[2]-}; [[ "$HS_STARTTIME" =~ ^[0-9]+$ && "$HS_PGID" =~ ^[1-9][0-9]*$ && "$HS_PGID" != 1 ]]; }
hs_field() { awk -F= -v k="$2" '$1 == k { print substr($0, index($0,"=")+1); exit }' "$1"; }
hs_publish_ready() { local role=$1 token=$2 ready=$3; hs_identity || return 1; hs_atomic "$ready" "token=$token
role=$role
pid=$$
starttime=$HS_STARTTIME
pgid=$HS_PGID"; }
hs_validate_ready() {
  local ready=$1 token=$2 role=$3 expected_pid=${4-} expected_start=${5-} expected_pgid=${6-}
  local line count=0 key value
  [[ -f "$ready" && ! -L "$ready" && "$(hs_stat "$ready")" == "regular file|$(id -u)|1|600" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* && "$line" != *=*=* && "$line" != *$'\r' ]] || return 1
    key=${line%%=*}; value=${line#*=}; case "$key" in token|role|pid|starttime|pgid) [[ -n "$value" ]] || return 1 ;; *) return 1 ;; esac; count=$((count + 1))
  done <"$ready"
  [[ "$count" == 5 && "$(hs_field "$ready" token)" == "$token" && "$(hs_field "$ready" role)" == "$role" && "$(hs_field "$ready" pid)" =~ ^[1-9][0-9]*$ && "$(hs_field "$ready" pid)" != 1 && "$(hs_field "$ready" starttime)" =~ ^[0-9]+$ && "$(hs_field "$ready" pgid)" =~ ^[1-9][0-9]*$ && "$(hs_field "$ready" pgid)" != 1 ]] || return 1
  [[ -z "$expected_pid" || "$(hs_field "$ready" pid)" == "$expected_pid" ]] || return 1
  [[ -z "$expected_start" || "$(hs_field "$ready" starttime)" == "$expected_start" ]] || return 1
  [[ -z "$expected_pgid" || "$(hs_field "$ready" pgid)" == "$expected_pgid" ]]
}
hs_wait_release() {
  local ready=$1 release=$2 abort=$3 token=$4 role=$5 i
  for ((i = 0; i < 300; i++)); do
    hs_validate_ready "$ready" "$token" "$role" "$$" "$HS_STARTTIME" "$HS_PGID" || return 1
    if [[ -f "$abort" && ! -L "$abort" && "$(hs_stat "$abort")" == "regular file|$(id -u)|1|600" && "$(<"$abort")" == "token=$token role=$role" ]]; then return 143; fi
    if [[ -f "$release" && ! -L "$release" && "$(hs_stat "$release")" == "regular file|$(id -u)|1|600" && "$(<"$release")" == "token=$token role=$role" ]]; then return 0; fi
    /bin/sleep 0.01
  done
  return 124
}
EOF
chmod 0700 -- "$int_handshake_helper"

cat >"$int_signaler" <<'EOF'
#!/bin/bash
set -Eeuo pipefail

handshake_helper=$1
handshake_role=$2
handshake_token=$3
handshake_ready=$4
handshake_release=$5
handshake_abort=$6
source "$handshake_helper"
diagnostic_file=${FRP_XUDP_INT_DIAGNOSTIC_FILE-}
diagnostic_emit() {
  local line=${1-}
  # The fixture directory is disposable. Always mirror the bounded,
  # non-sensitive record to stderr so cleanup cannot erase the evidence.
  printf '%s\n' "$line" >&2
  if [[ -n "$diagnostic_file" ]]; then
    # Never open a caller-controlled FIFO, device, or symlink from the
    # best-effort diagnostic path.  stderr remains the authoritative copy.
    [[ ! -L "$diagnostic_file" && ! -p "$diagnostic_file" &&
      ( ! -e "$diagnostic_file" || -f "$diagnostic_file" ) ]] || return 0
    printf '%s\n' "$line" >>"$diagnostic_file" 2>/dev/null || true
  fi
}

diagnostic_stat_snapshot() {
  local pid=${1:-} fd line rest state ppid pgid sid starttime
  local -a fields=()
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  if ! { exec {fd}<"/proc/$pid/stat"; } 2>/dev/null; then
    return 1
  fi
  if ! IFS= read -r -t 0.05 -u "$fd" line; then
    exec {fd}<&-
    return 1
  fi
  exec {fd}<&-
  rest=${line##*') '}
  [[ "$rest" != "$line" ]] || return 1
  read -r -a fields <<<"$rest" || return 1
  state=${fields[0]-}
  ppid=${fields[1]-}
  pgid=${fields[2]-}
  sid=${fields[3]-}
  starttime=${fields[19]-}
  [[ "$state" =~ ^[A-Za-z]$ && "$ppid" =~ ^[1-9][0-9]*$ &&
    "$pgid" =~ ^[1-9][0-9]*$ && "$starttime" =~ ^[0-9]+$ ]] || return 1
  DIAG_STATE=$state
  DIAG_PPID=$ppid
  DIAG_PGID=$pgid
  DIAG_SID=$sid
  DIAG_STARTTIME=$starttime
}

diagnostic_signal_disposition() {
  local pid=${1:-} fd line value lines=0
  DIAG_IGN=missing
  DIAG_CGT=missing
  if ! { exec {fd}<"/proc/$pid/status"; } 2>/dev/null; then
    return 0
  fi
  while (( lines < 96 )); do
    if ! IFS= read -r -t 0.005 -u "$fd" line; then
      break
    fi
    lines=$((lines + 1))
    case "$line" in
      SigIgn:*)
        value=${line#SigIgn:}
        value=${value#"${value%%[![:space:]]*}"}
        [[ "$value" =~ ^[0-9A-Fa-f]+$ ]] && DIAG_IGN=$value
        ;;
      SigCgt:*)
        value=${line#SigCgt:}
        value=${value#"${value%%[![:space:]]*}"}
        [[ "$value" =~ ^[0-9A-Fa-f]+$ ]] && DIAG_CGT=$value
        ;;
    esac
    if [[ "$DIAG_IGN" != missing && "$DIAG_CGT" != missing ]]; then
      break
    fi
  done
  exec {fd}<&-
}

diagnostic_cmdline_summary() {
  local pid=${1:-} fd part count=0 bytes=0 first=
  DIAG_CMD_EXE=missing
  DIAG_CMD_ARGC=missing
  DIAG_CMD_BYTES=missing
  if ! { exec {fd}<"/proc/$pid/cmdline"; } 2>/dev/null; then
    return 0
  fi
  # Read at most sixteen NUL-delimited arguments and never expose their
  # contents.  The first argument is reduced to its basename below.
  while (( count < 16 )); do
    if ! IFS= read -r -d '' -t 0.005 -u "$fd" part; then
      break
    fi
    if [[ $count == 0 ]]; then
      first=$part
    fi
    count=$((count + 1))
    bytes=$((bytes + ${#part} + 1))
  done
  exec {fd}<&-
  if (( count > 0 )); then
    DIAG_CMD_EXE=${first##*/}
    [[ -n "$DIAG_CMD_EXE" ]] || DIAG_CMD_EXE=missing
    DIAG_CMD_ARGC=$count
    DIAG_CMD_BYTES=$bytes
  fi
}

diagnostic_process() {
  local phase=${1:-unknown} pid=${2:-} identity_before identity_after
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  if ! diagnostic_stat_snapshot "$pid"; then
    diagnostic_emit "process phase=$phase pid=$pid unavailable=proc-stat"
    return 0
  fi
  identity_before="$pid:$DIAG_PGID:$DIAG_STARTTIME"
  diagnostic_signal_disposition "$pid"
  diagnostic_cmdline_summary "$pid"
  if ! diagnostic_stat_snapshot "$pid"; then
    diagnostic_emit "process phase=$phase pid=$pid unavailable=identity-recheck"
    return 0
  fi
  identity_after="$pid:$DIAG_PGID:$DIAG_STARTTIME"
  [[ "$identity_before" == "$identity_after" ]] || {
    diagnostic_emit "process phase=$phase pid=$pid unavailable=identity-changed"
    return 0
  }
  diagnostic_emit "process phase=$phase pid=$pid ppid=$DIAG_PPID pgid=$DIAG_PGID sid=$DIAG_SID starttime=$DIAG_STARTTIME state=$DIAG_STATE SigIgn=$DIAG_IGN SigCgt=$DIAG_CGT cmdline_summary=exe:$DIAG_CMD_EXE,argc:$DIAG_CMD_ARGC,bytes:$DIAG_CMD_BYTES"
}
diagnostic_chain() {
  local phase=$1 pid=$2 depth=0
  while [[ "$pid" =~ ^[1-9][0-9]*$ && $depth -lt 8 ]]; do
    diagnostic_process "$phase-$depth" "$pid"
    diagnostic_stat_snapshot "$pid" || break
    [[ "$DIAG_PPID" =~ ^[1-9][0-9]*$ && "$DIAG_PPID" != "$pid" ]] || break
    pid=$DIAG_PPID
    depth=$((depth + 1))
  done
}
diagnostic_group() {
  local phase=$1 wanted_pgid=$2 entry pid checked=0 matched=0
  [[ "$wanted_pgid" =~ ^[1-9][0-9]*$ ]] || return 0
  for entry in /proc/[0-9]*; do
    checked=$((checked + 1))
    (( checked <= 256 )) || break
    [[ -d "$entry" ]] || continue
    pid=${entry##*/}
    diagnostic_stat_snapshot "$pid" || continue
    [[ "$DIAG_PGID" == "$wanted_pgid" ]] || continue
    diagnostic_process "$phase-group-$matched" "$pid"
    matched=$((matched + 1))
    (( matched < 8 )) || break
  done
}
signal=$7
pid_file=$8
pgid_file=$9
starttime_file=${10}
marker=${11}
failure_marker=${12}
diagnostic=${13}
stage_marker=${14}
recovery_output=${15}
lock_path=${16}
supervisor_ready=${17}
caller_pgid=${18}
suite_pgid=${19}
caller_pid=${20}
suite_pid=${21}
shift 21
ready_files=("$@")
declare -Ag marker_seen=()
MARKER_SERIAL=

if [[ "$handshake_role" != pre-signal ]]; then
  hs_publish_ready "$handshake_role" "$handshake_token" "$handshake_ready" || exit 2
  hs_wait_release "$handshake_ready" "$handshake_release" "$handshake_abort" "$handshake_token" "$handshake_role" || exit $?
fi

atomic_stage() {
  local phase=$1 tmp stage_stat existing_token existing_role
  [[ "$phase" =~ ^[a-z][a-z0-9-]*(:[a-z0-9-]+)?$ ]] || return 1
  [[ -d "${stage_marker%/*}" && ! -L "${stage_marker%/*}" ]] || return 1
  if [[ -e "$stage_marker" || -L "$stage_marker" ]]; then
    [[ ! -L "$stage_marker" ]] || return 1
    stage_stat=$(stat -Lc '%F|%u|%h|%a' -- "$stage_marker" 2>/dev/null) || return 1
    [[ "$stage_stat" == "regular file|$(id -u)|1|600" ]] || return 1
    existing_token=$(awk -F= '$1 == "token" { print $2; exit }' "$stage_marker") || return 1
    existing_role=$(awk -F= '$1 == "role" { print $2; exit }' "$stage_marker") || return 1
    [[ "$existing_token" == "$handshake_token" && "$existing_role" == "$handshake_role" ]] || return 1
  fi
  tmp=$(mktemp -- "${stage_marker}.tmp.XXXXXX") || return 1
  printf 'token=%s\nrole=%s\nphase=%s\n' \
    "$handshake_token" "$handshake_role" "$phase" >"$tmp"
  chmod 0600 -- "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$stage_marker" || { rm -f -- "$tmp"; return 1; }
}
init_failed() {
  local reason=$1 field=${2:-unset} value=${3:-unset}
  atomic_stage "failed:$reason" || true
  printf 'token=%s role=%s phase=failed:%s field=%s value=%s\n' \
    "$handshake_token" "$handshake_role" "$reason" "$field" "$value" \
    >"$failure_marker"
  printf 'token=%s role=%s phase=failed:%s field=%s value=%s\n' \
    "$handshake_token" "$handshake_role" "$reason" "$field" "$value" \
    >"$diagnostic"
  exit 1
}
if [[ "$handshake_role" != pre-signal ]]; then
  atomic_stage release-consumed || init_failed stage-write release-consumed failed
fi

atomic_marker() {
  local file=$1 content=$2 tmp="${1}.tmp.$$"
  printf '%s\n' "$content" >"$tmp"
  mv -f -- "$tmp" "$file"
}

proc_snapshot() {
  local pid=$1 line rest
  local -a fields=()
  [[ "$pid" =~ ^[0-9]+$ && "$pid" != 0 ]] || return 1
  [[ -r "/proc/$pid/stat" ]] || return 1
  line=$(<"/proc/$pid/stat") || return 1
  rest=${line#*') '}
  [[ "$rest" != "$line" ]] || return 1
  read -r -a fields <<<"$rest"
  PROC_STATE=${fields[0]-}
  PROC_PPID=${fields[1]-}
  PROC_PGID=${fields[2]-}
  PROC_STARTTIME=${fields[19]-}
  [[ "$PROC_STATE" =~ ^[A-Za-z]$ && "$PROC_PPID" =~ ^[0-9]+$ &&
    "$PROC_PGID" =~ ^[1-9][0-9]*$ && "$PROC_STARTTIME" =~ ^[0-9]+$ &&
    "$PROC_STATE" != Z* ]]
}

own_pgid=$(${REAL_PS:?} -o pgid= -p "$$" 2>/dev/null | ${REAL_TR:?} -d '[:space:]')
[[ "$own_pgid" =~ ^[1-9][0-9]*$ ]] || init_failed invalid-identity own_pgid "$own_pgid"
[[ "$caller_pgid" =~ ^[1-9][0-9]*$ ]] || init_failed invalid-identity caller_pgid "$caller_pgid"
[[ "$suite_pgid" =~ ^[1-9][0-9]*$ ]] || init_failed invalid-identity suite_pgid "$suite_pgid"
[[ "$caller_pid" =~ ^[1-9][0-9]*$ ]] || init_failed invalid-identity caller_pid "$caller_pid"
[[ "$suite_pid" =~ ^[1-9][0-9]*$ ]] || init_failed invalid-identity suite_pid "$suite_pid"

protected_pgid() {
  local pgid=$1
  [[ "$pgid" =~ ^[1-9][0-9]*$ && "$pgid" != "$own_pgid" &&
    "$pgid" != "$caller_pgid" && "$pgid" != "$suite_pgid" ]]
}

group_state() {
  local wanted=$1 snapshot line pid pgid state live=0 member=0
  [[ "$wanted" =~ ^[1-9][0-9]*$ && "$wanted" != "$own_pgid" &&
    "$wanted" != "$caller_pgid" && "$wanted" != "$suite_pgid" ]] || return 2
  snapshot=$(${REAL_PS:?} -eo pid=,pgid=,stat= 2>/dev/null) || return 2
  while read -r pid pgid state; do
    [[ -n "$pid" && -n "$pgid" && -n "$state" ]] || return 2
    [[ "$pgid" == "$wanted" ]] || continue
    member=1
    [[ "$state" == Z* ]] || live=1
  done <<<"$snapshot"
  (( live )) && return 0
  (( member )) && return 1
  return 1
}

target_state() {
  local pid=$1
  "${REAL_PS:?}" -o stat= -p "$pid" 2>/dev/null | "${REAL_TR:?}" -d '[:space:]' || true
}

read_marker() {
  local label=${1:-authority-read} line key value count=0 marker_stat
  local -a required=(phase lock_inode result_rc supervisor_pid supervisor_pgid
    supervisor_starttime business_pid business_pgid business_starttime)
  marker_seen=()
  MARKER_SERIAL=
  [[ -f "$supervisor_ready" && ! -L "$supervisor_ready" ]] || {
    authority_fail "$label-file"; return 1;
  }
  marker_stat=$(stat -Lc '%F %u %a' -- "$supervisor_ready" 2>/dev/null) || {
    authority_fail "$label-stat"; return 1;
  }
  [[ "$marker_stat" == "regular file $(id -u) 600" ]] || {
    authority_fail "$label-permissions"; return 1;
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" && "$line" != *$'\r' ]] || {
      authority_fail "$label-line"; return 1;
    }
    case "$line" in *=*=*) authority_fail "$label-duplicate-separator"; return 1 ;; esac
    [[ "$line" == *=* ]] || { authority_fail "$label-format"; return 1; }
    key=${line%%=*}
    value=${line#*=}
    [[ "$key" =~ ^[a-z_]+$ && -n "$value" ]] || {
      authority_fail "$label-field"; return 1;
    }
    [[ -z ${marker_seen[$key]+x} ]] || {
      authority_fail "$label-duplicate-field"; return 1;
    }
    marker_seen[$key]=1
    case "$key" in
      phase) RECOVERY_PHASE=$value ;;
      lock_inode) RECOVERY_LOCK_INODE=$value ;;
      result_rc) RECOVERY_RESULT_RC=$value ;;
      supervisor_pid) RECOVERY_SUPERVISOR_PID=$value ;;
      supervisor_pgid) RECOVERY_SUPERVISOR_PGID=$value ;;
      supervisor_starttime) RECOVERY_SUPERVISOR_STARTTIME=$value ;;
      business_pid) RECOVERY_BUSINESS_PID=$value ;;
      business_pgid) RECOVERY_BUSINESS_PGID=$value ;;
      business_starttime) RECOVERY_BUSINESS_STARTTIME=$value ;;
      *) authority_fail "$label-unknown-field"; return 1 ;;
    esac
    MARKER_SERIAL+="$line"$'\n'
    count=$((count + 1))
  done <"$supervisor_ready" || { authority_fail "$label-read"; return 1; }
  [[ "$count" == 9 ]] || { authority_fail "$label-field-count"; return 1; }
  for key in "${required[@]}"; do
    [[ -n ${marker_seen[$key]+x} ]] || {
      authority_fail "$label-missing-field"; return 1;
    }
  done
  # The parent barrier may observe business-ready only briefly.  body-running
  # remains an authenticated, non-terminal state with the same supervisor and
  # business identities, so it is equally safe for this signaler to consume.
  if ! [[ "$RECOVERY_PHASE" =~ ^(business-ready|body-running)$ &&
    "$RECOVERY_LOCK_INODE" =~ ^[1-9][0-9]*:[1-9][0-9]*$ &&
    "$RECOVERY_RESULT_RC" =~ ^(0|[1-9][0-9]*)$ &&
    "$RECOVERY_SUPERVISOR_PID" =~ ^[1-9][0-9]*$ &&
    "$RECOVERY_SUPERVISOR_PGID" =~ ^[1-9][0-9]*$ &&
    "$RECOVERY_SUPERVISOR_STARTTIME" =~ ^[1-9][0-9]*$ &&
    "$RECOVERY_BUSINESS_PID" =~ ^[1-9][0-9]*$ &&
    "$RECOVERY_BUSINESS_PGID" =~ ^[1-9][0-9]*$ &&
    "$RECOVERY_BUSINESS_STARTTIME" =~ ^[1-9][0-9]*$ ]]; then
    authority_fail "$label-values"
    return 1
  fi
  validate_marker_phase_values "$RECOVERY_PHASE" "$RECOVERY_RESULT_RC" \
    "$RECOVERY_BUSINESS_PID" "$RECOVERY_BUSINESS_PGID" \
    "$RECOVERY_BUSINESS_STARTTIME" || {
      authority_fail "$label-values"; return 1;
    }
}

write_diagnostic() {
  {
    printf 'signaler_timeout_or_target_exit\n'
    printf 'authority_fail_reason=%s\n' "${AUTHORITY_FAIL_REASON:-unclassified}"
    printf 'pid_file=%s\npgid_file=%s\n' "$pid_file" "$pgid_file"
    if [[ -s "$pid_file" ]]; then
      target=$(<"$pid_file")
      printf 'target_pid=%s\n' "$target"
      if [[ "$target" =~ ^[0-9]+$ ]]; then
      printf 'target_state=%s\n' "$(target_state "$target")"
        printf 'target_pgid=%s\n' "$("${REAL_PS:?}" -o pgid= -p "$target" 2>/dev/null | "${REAL_TR:?}" -d '[:space:]' || true)"
        if kill -0 "$target" 2>/dev/null; then
          printf 'target_alive=1\n'
        else
          printf 'target_alive=0\n'
        fi
      else
        printf 'target_state=invalid-pid\ntarget_alive=0\n'
      fi
    else
      printf 'target_pid=unpublished\ntarget_state=unpublished\ntarget_alive=0\n'
    fi
    printf 'target_pgid='
    if [[ -s "$pgid_file" ]]; then cat -- "$pgid_file"; else printf 'unpublished'; fi
    printf '\n'
    printf 'supervisor_ready=%s\n' "$supervisor_ready"
    if [[ -e "$supervisor_ready" ]]; then
      sed -n '1,16p' -- "$supervisor_ready"
    else
      printf 'supervisor_ready: missing\n'
    fi
    printf 'recovery_output=%s\n' "$recovery_output"
    if [[ -e "$recovery_output" ]]; then
      sed -n '1,240p' -- "$recovery_output"
    else
      printf 'recovery_output: missing\n'
    fi
    printf 'ready_files_begin\n'
    for file in "${ready_files[@]}"; do
      printf '%s: ' "$file"
      if [[ -e "$file" ]]; then
        sed -n '1,8p' -- "$file"
      else
        printf 'missing\n'
      fi
    done
    printf 'ready_files_end\n'
  } >"$diagnostic"
  printf '%s\n' 'signaler_diagnostic_begin' >&2
  sed -n '1,240p' -- "$diagnostic" >&2 || true
  printf '%s\n' 'signaler_diagnostic_end' >&2
}

fail_signal() {
  local reason=${1:-validation-failed}
  local authority_reason=${AUTHORITY_FAIL_REASON:-unclassified}
  printf 'signaler failure reason=%s authority_fail_reason=%s\n' \
    "$reason" "$authority_reason" >&2
  atomic_stage "failed:$reason"
  atomic_marker "$failure_marker" "failed signal=$signal reason=$reason authority_fail_reason=$authority_reason"
  write_diagnostic
  exit 1
}

stable_wrapper_identity() {
  local label=${1:-wrapper-identity}
  local target target_pgid target_starttime first second
  [[ -s "$pid_file" && -s "$pgid_file" && -s "$starttime_file" ]] || {
    authority_fail "$label-files"; return 1;
  }
  target=$(<"$pid_file"); target_pgid=$(<"$pgid_file"); target_starttime=$(<"$starttime_file")
  [[ "$target" =~ ^[1-9][0-9]*$ && "$target_pgid" =~ ^[1-9][0-9]*$ &&
    "$target_starttime" =~ ^[0-9]+$ && "$target" != "$$" &&
    "$target" != "$PPID" && "$target" != "$caller_pid" &&
    "$target" != "$suite_pid" ]] || { authority_fail "$label-fields"; return 1; }
  protected_pgid "$target_pgid" || { authority_fail "$label-protected-pgid"; return 1; }
  proc_snapshot "$target" || { authority_fail "$label-proc"; return 1; }
  # Process state is transient; identity stability is PID/PGID/starttime.
  first="$target:$PROC_PGID:$PROC_STARTTIME"
  [[ "$PROC_PGID" == "$target_pgid" && "$PROC_STARTTIME" == "$target_starttime" ]] || {
    authority_fail "$label-snapshot-1"; return 1;
  }
  /bin/sleep 0.01
  proc_snapshot "$target" || { authority_fail "$label-proc-2"; return 1; }
  second="$target:$PROC_PGID:$PROC_STARTTIME"
  [[ "$first" == "$second" && "$target_pgid" == "$PROC_PGID" &&
    "$target_starttime" == "$PROC_STARTTIME" ]] || { authority_fail "$label-unstable"; return 1; }
  WRAPPER_PID=$target
  WRAPPER_PGID=$target_pgid
  WRAPPER_STARTTIME=$target_starttime
}

stable_marker_identity() {
  local label=$1 pid=$2 expected_pgid=$3 expected_starttime=$4 first second
  proc_snapshot "$pid" || { authority_fail "$label-proc-1"; return 1; }
  [[ "$PROC_PGID" == "$expected_pgid" && "$PROC_STARTTIME" == "$expected_starttime" ]] || {
    authority_fail "$label-mismatch-1"; return 1;
  }
  # Process state is transient; identity stability is PID/PGID/starttime.
  first="$pid:$PROC_PGID:$PROC_STARTTIME"
  /bin/sleep 0.01
  proc_snapshot "$pid" || { authority_fail "$label-proc-2"; return 1; }
  second="$pid:$PROC_PGID:$PROC_STARTTIME"
  [[ "$first" == "$second" && "$PROC_PGID" == "$expected_pgid" &&
    "$PROC_STARTTIME" == "$expected_starttime" ]] || { authority_fail "$label-unstable"; return 1; }
}

validate_descendant_pid_file() {
  local file=$1 child_file=$2 grandchild_file=$3
  local line child grandchild count=0
  local -A seen=()
  [[ -f "$file" && ! -L "$file" && -f "$child_file" && ! -L "$child_file" &&
    -f "$grandchild_file" && ! -L "$grandchild_file" ]] || return 1
  child=$(<"$child_file") || return 1
  grandchild=$(<"$grandchild_file") || return 1
  [[ "$child" =~ ^[1-9][0-9]*$ && "$grandchild" =~ ^[1-9][0-9]*$ &&
    "$child" != "$grandchild" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ -z ${seen[$line]+x} ]] || return 1
    seen[$line]=1
    count=$((count + 1))
  done <"$file" || return 1
  [[ "$count" == 2 && -n ${seen[$child]+x} && -n ${seen[$grandchild]+x} ]]
}

AUTHORITY_FAIL_REASON=

authority_fail() {
  AUTHORITY_FAIL_REASON=$1
  return 1
}

marker_has_lock_fd() {
  local pass=${1:-validation-1} fd target lock_identity fd_identity
  if ! lock_identity=$(stat -Lc '%d:%i' -- "$lock_path" 2>/dev/null); then
    authority_fail "$pass-lock-fd-lock-stat"; return 1
  fi
  [[ "$lock_identity" =~ ^[1-9][0-9]*:[1-9][0-9]*$ ]] || {
    authority_fail "$pass-lock-fd-lock-identity"; return 1;
  }
  for fd in /proc/$RECOVERY_SUPERVISOR_PID/fd/*; do
    [[ -e "$fd" ]] || continue
    target=$(readlink -- "$fd" 2>/dev/null || true)
    fd_identity=$(stat -Lc '%d:%i' -- "$fd" 2>/dev/null || true)
    [[ "$fd_identity" == "$lock_identity" && "$target" == "$lock_path" ]] && return 0
  done
  authority_fail "$pass-lock-fd-not-held"
}

validate_marker_phase_values() {
  local phase=$1 result_rc=$2 business_pid=$3 business_pgid=$4 business_starttime=$5
  case "$phase" in
    supervisor-ready)
      [[ "$result_rc" == 0 && "$business_pid" == 0 &&
        "$business_pgid" == 0 && "$business_starttime" == 0 ]] ;;
    business-starting)
      [[ "$result_rc" == 0 && "$business_pid" =~ ^[1-9][0-9]*$ &&
        "$business_pgid" == 0 && "$business_starttime" =~ ^[1-9][0-9]*$ ]] ;;
    business-ready|body-running|body-success)
      [[ "$result_rc" == 0 && "$business_pid" =~ ^[1-9][0-9]*$ &&
        "$business_pgid" =~ ^[1-9][0-9]*$ &&
        "$business_starttime" =~ ^[1-9][0-9]*$ ]] ;;
    business-exited|body-failed)
      [[ "$result_rc" =~ ^[1-9][0-9]*$ &&
        "$business_pid" =~ ^[1-9][0-9]*$ &&
        "$business_pgid" =~ ^[1-9][0-9]*$ &&
        "$business_starttime" =~ ^[1-9][0-9]*$ ]] ;;
    timeout)
      [[ "$result_rc" == "$RECOVERY_RC_TIMEOUT" &&
        "$business_pid" =~ ^[1-9][0-9]*$ &&
        "$business_pgid" =~ ^[1-9][0-9]*$ &&
        "$business_starttime" =~ ^[1-9][0-9]*$ ]] ;;
    *) return 1 ;;
  esac
}

validate_authority_marker() {
  local pass=${1:-validation-1} lock_inode probe_fd probe_rc marker_serial
  read_marker "$pass-read-1" || return 1
  marker_serial=$MARKER_SERIAL
  /bin/sleep 0.01
  read_marker "$pass-read-2" || return 1
  [[ "$MARKER_SERIAL" == "$marker_serial" ]] || {
    authority_fail "$pass-serial-unstable"; return 1;
  }
  if ! lock_inode=$(stat -Lc '%d:%i' -- "$lock_path" 2>/dev/null); then
    authority_fail "$pass-lock-inode-stat"; return 1
  fi
  [[ "$lock_inode" == "$RECOVERY_LOCK_INODE" ]] || {
    authority_fail "$pass-lock-inode-mismatch"; return 1;
  }
  marker_has_lock_fd "$pass" || return 1
  if ! exec {probe_fd}<"$lock_path"; then
    authority_fail "$pass-flock-open"; return 1
  fi
  if /usr/bin/flock -E 75 -n "$probe_fd"; then probe_rc=0; else probe_rc=$?; fi
  exec {probe_fd}>&-
  [[ "$probe_rc" == 75 ]] || { authority_fail "$pass-flock-not-held"; return 1; }
  stable_marker_identity "$pass-supervisor-identity" "$RECOVERY_SUPERVISOR_PID" \
    "$RECOVERY_SUPERVISOR_PGID" "$RECOVERY_SUPERVISOR_STARTTIME" || return 1
  stable_marker_identity "$pass-business-identity" "$RECOVERY_BUSINESS_PID" \
    "$RECOVERY_BUSINESS_PGID" "$RECOVERY_BUSINESS_STARTTIME" || return 1
  [[ "$RECOVERY_BUSINESS_PGID" == "$RECOVERY_BUSINESS_PID" ]] || {
    authority_fail "$pass-business-leader-mismatch"; return 1;
  }
  protected_pgid "$RECOVERY_SUPERVISOR_PGID" || {
    authority_fail "$pass-protected-supervisor"; return 1;
  }
  protected_pgid "$RECOVERY_BUSINESS_PGID" || {
    authority_fail "$pass-protected-business"; return 1;
  }
  stable_wrapper_identity "$pass-wrapper-identity" || return 1
  [[ "$RECOVERY_SUPERVISOR_PID" != "$WRAPPER_PID" &&
    "$RECOVERY_SUPERVISOR_PGID" != "$WRAPPER_PGID" ]] || {
    authority_fail "$pass-wrapper-separation"; return 1;
  }
}

for ((i = 0; i < 1500; i++)); do
  target=
  if [[ -s "$pid_file" ]]; then
    target=$(<"$pid_file")
    if [[ ! "$target" =~ ^[1-9][0-9]*$ || "$target" == "$$" ||
      "$target" == "$PPID" || "$target" == "$caller_pid" ||
      "$target" == "$suite_pid" ]]; then
      fail_signal
    fi
    if ! kill -0 "$target" 2>/dev/null || [[ "$(target_state "$target")" == Z* ]]; then
      fail_signal
    fi
  fi
  if [[ -z "$target" ]]; then
    /bin/sleep 0.01
    continue
  fi

  all_ready=1
  for file in "${ready_files[@]}"; do
    [[ -s "$file" ]] || all_ready=0
  done
  AUTHORITY_FAIL_REASON=authority-prerequisites-not-ready
  if (( ! all_ready )); then
    AUTHORITY_FAIL_REASON=authority-prerequisite-files
  elif [[ ! -s "$supervisor_ready" ]]; then
    AUTHORITY_FAIL_REASON=authority-supervisor-marker-not-ready
  elif [[ ! $(<"${ready_files[0]}") =~ ^[0-9]+$ ]]; then
    AUTHORITY_FAIL_REASON=authority-prerequisite-hold-pid
  elif [[ $(<"${ready_files[1]}") != 0 ]]; then
    AUTHORITY_FAIL_REASON=authority-prerequisite-hold-fd
  elif ! validate_descendant_pid_file "${ready_files[2]}" \
      "${ready_files[3]}" "${ready_files[4]}"; then
    AUTHORITY_FAIL_REASON=authority-prerequisite-descendant
  elif [[ ! $(<"${ready_files[3]}") =~ ^[0-9]+$ ]]; then
    AUTHORITY_FAIL_REASON=authority-prerequisite-child
  elif [[ ! $(<"${ready_files[4]}") =~ ^[0-9]+$ ]]; then
    AUTHORITY_FAIL_REASON=authority-prerequisite-grandchild
  elif [[ $(<"${ready_files[5]}") != 0 ]]; then
    AUTHORITY_FAIL_REASON=authority-prerequisite-child-fd
  elif [[ $(<"${ready_files[6]}") != 0 ]]; then
    AUTHORITY_FAIL_REASON=authority-prerequisite-grandchild-fd
  elif [[ ! $(<"${ready_files[7]}") =~ ^[0-9]+$ ]]; then
    AUTHORITY_FAIL_REASON=authority-prerequisite-starttime
  fi
  if (( all_ready )) && [[ -s "$supervisor_ready" ]] &&
    validate_descendant_pid_file "${ready_files[2]}" \
      "${ready_files[3]}" "${ready_files[4]}" &&
    [[ $(<"${ready_files[0]}") =~ ^[0-9]+$ &&
      $(<"${ready_files[1]}") == 0 &&
      $(<"${ready_files[3]}") =~ ^[0-9]+$ &&
      $(<"${ready_files[4]}") =~ ^[0-9]+$ &&
      $(<"${ready_files[5]}") == 0 &&
      $(<"${ready_files[6]}") == 0 &&
      $(<"${ready_files[7]}") =~ ^[0-9]+$ ]]; then
    if validate_authority_marker validation-1; then
      target=$(<"$pid_file")
      target_pgid=$(<"$pgid_file")
      target_starttime=$(<"$starttime_file")
      # Shell validation cannot eliminate the final instruction-level TOCTOU;
      # it does ensure the last observed identity is live and outside every
      # protected group before the negative-PGID kill.
      if ! validate_authority_marker validation-2; then
        fail_signal authority-validation-failed
      fi
      atomic_stage authority-validated
      diagnostic_emit "event=kill-before phase=authority-validated signal=$signal target_pid=$target target_pgid=$target_pgid target_starttime=$target_starttime"
      diagnostic_emit "event=diagnostic-begin phase=authority-validated section=pre-kill-chain"
      diagnostic_chain pre-kill "$target"
      diagnostic_emit "event=diagnostic-end phase=authority-validated section=pre-kill-chain"
      diagnostic_emit "event=diagnostic-begin phase=authority-validated section=pre-kill-group"
      diagnostic_group pre-kill "$target_pgid"
      diagnostic_emit "event=diagnostic-end phase=authority-validated section=pre-kill-group"
      kill_rc=0
      kill_reason=sent
      if ! proc_snapshot "$target"; then
        kill_rc=1; kill_reason=leader-snapshot
      elif [[ "$PROC_STARTTIME" != "$target_starttime" ||
        "$PROC_PGID" != "$target_pgid" ]]; then
        kill_rc=1; kill_reason=leader-identity
      elif ! protected_pgid "$target_pgid"; then
        kill_rc=1; kill_reason=protected-pgid
      elif ! group_state "$target_pgid"; then
        kill_rc=1; kill_reason=group-state
      elif kill -"$signal" -- "-$target_pgid" 2>/dev/null; then
        :
      else
        kill_rc=$?
        kill_reason=kill
      fi
      diagnostic_emit "event=kill-after phase=authority-validated signal=$signal target_pid=$target target_pgid=$target_pgid result=$([[ $kill_rc == 0 ]] && printf sent || printf failed) rc=$kill_rc reason=$kill_reason"
      if (( kill_rc != 0 )); then
        fail_signal kill-failed
      fi
      /bin/sleep 0.05
      diagnostic_emit "event=diagnostic-begin phase=signal-sent section=post-kill-chain"
      diagnostic_chain post-kill "$target"
      diagnostic_emit "event=diagnostic-end phase=signal-sent section=post-kill-chain"
      diagnostic_emit "event=diagnostic-begin phase=signal-sent section=post-kill-group"
      diagnostic_group post-kill "$target_pgid"
      diagnostic_emit "event=diagnostic-end phase=signal-sent section=post-kill-group"
      atomic_marker "$marker" "sent signal=$signal target=$target starttime=$target_starttime pgid=$target_pgid"
      atomic_stage signal-sent
      exit 0
    fi
  fi
  /bin/sleep 0.01
done

printf 'signaler readiness timed out after 15 seconds authority_fail_reason=%s\n' \
  "${AUTHORITY_FAIL_REASON:-unclassified}" >&2
fail_signal
EOF
chmod 0755 -- "$int_signaler"

# Exercise the exact validator emitted into the signaler without embedding
# fixture setup in that runtime script.  The source block is extracted once
# so the directed tests cannot drift from the production helper.
descendant_validator_block=$(awk '
  /^validate_descendant_pid_file\(\)/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "${BASH_SOURCE[0]}")
[[ -n "$descendant_validator_block" ]]
if grep -Eq '(^|[^[:alnum:]_])TEST_DIR([^[:alnum:]_]|$)|(^|[;&|[:space:]])pass([[:space:]]|$)' \
  "$int_signaler"; then
  printf 'generated signaler contains parent fixture dependency or pass helper\n' >&2
  exit 1
fi
pass 'generated signaler is self-contained and excludes parent fixture tests'

descendant_validator_dir="$TEST_DIR/descendant-validator"
mkdir -- "$descendant_validator_dir"
descendant_validator_file="$descendant_validator_dir/descendants"
descendant_validator_child="$descendant_validator_dir/child.pid"
descendant_validator_grandchild="$descendant_validator_dir/grandchild.pid"
{
  printf '%s\n' 'set -Eeuo pipefail'
  printf '%s\n' "$descendant_validator_block"
  printf '%s\n' 'file=$1 child_file=$2 grandchild_file=$3'
  printf '%s\n' 'validate_descendant_pid_file "$file" "$child_file" "$grandchild_file"'
} >"$descendant_validator_dir/validator.sh"
bash -n -- "$descendant_validator_dir/validator.sh"
printf '2001\n' >"$descendant_validator_child"
printf '2002\n' >"$descendant_validator_grandchild"
printf '2002\n2001\n' >"$descendant_validator_file"
bash "$descendant_validator_dir/validator.sh" "$descendant_validator_file" \
  "$descendant_validator_child" "$descendant_validator_grandchild"
pass 'descendant PID validator accepts the expected two-PID set in either order'

printf '2001\n\n2002\n' >"$descendant_validator_file"
if bash "$descendant_validator_dir/validator.sh" "$descendant_validator_file" \
  "$descendant_validator_child" "$descendant_validator_grandchild"; then exit 1; fi
printf '2001\nnot-a-pid\n' >"$descendant_validator_file"
if bash "$descendant_validator_dir/validator.sh" "$descendant_validator_file" \
  "$descendant_validator_child" "$descendant_validator_grandchild"; then exit 1; fi
pass 'descendant PID validator rejects empty and non-numeric lines'

printf '2001\n2001\n' >"$descendant_validator_file"
if bash "$descendant_validator_dir/validator.sh" "$descendant_validator_file" \
  "$descendant_validator_child" "$descendant_validator_grandchild"; then exit 1; fi
printf '2001\n' >"$descendant_validator_file"
if bash "$descendant_validator_dir/validator.sh" "$descendant_validator_file" \
  "$descendant_validator_child" "$descendant_validator_grandchild"; then exit 1; fi
printf '2001\n2002\n2003\n' >"$descendant_validator_file"
if bash "$descendant_validator_dir/validator.sh" "$descendant_validator_file" \
  "$descendant_validator_child" "$descendant_validator_grandchild"; then exit 1; fi
pass 'descendant PID validator rejects duplicates, missing, and extra PIDs'

printf '2001\n2002\n' >"$descendant_validator_file"
printf '2999\n' >"$descendant_validator_child"
if bash "$descendant_validator_dir/validator.sh" "$descendant_validator_file" \
  "$descendant_validator_child" "$descendant_validator_grandchild"; then exit 1; fi
pass 'descendant PID validator rejects a set inconsistent with child.pid or grandchild.pid'

cat >"$int_watchdog" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

handshake_helper=$1
handshake_role=$2
handshake_token=$3
handshake_ready=$4
handshake_release=$5
handshake_abort=$6
source "$handshake_helper"
if [[ "$handshake_role" == pre-signal ]]; then
  # pre-signal uses a deliberately smaller, diagnostic-only argument layout:
  # authority marker is argv[16], followed by the three registered PID files
  # at argv[21..23].  Do not read the normal watchdog-only argv[24..28]; the
  # pre-signal caller does not provide those positions under set -u.
  authority_marker=${16:?missing pre-signal authority marker}
  registered_worker_pid_file=${21:?missing pre-signal worker PID file}
  registered_child_pid_file=${22:?missing pre-signal child PID file}
  registered_grandchild_pid_file=${23:?missing pre-signal grandchild PID file}
  target=
  target_pgid=
else
  pid_file=$7
  pgid_file=$8
  starttime_file=$9
  signal_marker=${10:?missing signal marker}
  failure_marker=${11:?missing failure marker}
  timeout_marker=${12:?missing timeout marker}
  term_sent_marker=${13:?missing TERM marker}
  kill_sent_marker=${14:?missing KILL marker}
  stage_marker=${15:?missing stage marker}
  fallback_pid=${16:?missing fallback PID}
  fallback_pgid=${17:?missing fallback PGID}
  caller_pgid=${18:?missing caller PGID}
  suite_pgid=${19:?missing suite PGID}
  signaler_pid=${20:?missing signaler PID}
  signaler_pgid=${21:?missing signaler PGID}
  signaler_starttime=${22:?missing signaler starttime}
  authority_marker=${23:?missing authority marker}
  caller_pid=${24:?missing caller PID}
  suite_pid=${25:?missing suite PID}
  registered_worker_pid_file=${26:?missing worker PID file}
  registered_child_pid_file=${27:?missing child PID file}
  registered_grandchild_pid_file=${28:?missing grandchild PID file}
  target=$fallback_pid
  target_pgid=$fallback_pgid
fi

# Failure-only evidence collector.  This runs in the independent watchdog
# immediately before its TERM fallback, while the marker and registered PID
# files still exist.  It deliberately reads only bounded /proc stat/status
# records: no cmdline, environ, or caller-controlled diagnostic path is used.
diagnostic_emit() {
  printf '%s\n' "$1" >&2 || :
  return 0
}

diagnostic_stat_snapshot() {
  local pid=${1:-} fd line rest
  local state ppid pgid sid starttime
  local IFS=$' \t\n'
  local -a fields=()
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  if ! { exec {fd}<"/proc/$pid/stat"; } 2>/dev/null; then
    return 1
  fi
  if ! IFS= read -r -t 0.05 -u "$fd" line; then
    exec {fd}<&-
    return 1
  fi
  exec {fd}<&-
  rest=${line##*') '}
  [[ "$rest" != "$line" ]] || return 1
  read -r -a fields <<<"$rest" || return 1
  state=${fields[0]-}
  ppid=${fields[1]-}
  pgid=${fields[2]-}
  sid=${fields[3]-}
  starttime=${fields[19]-}
  [[ "$state" =~ ^[A-Za-z]$ &&
    "$ppid" =~ ^[0-9]+$ && "$pgid" =~ ^[0-9]+$ &&
    "$sid" =~ ^[0-9]+$ && "$starttime" =~ ^[0-9]+$ ]] || return 1
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$state" "$ppid" "$pgid" "$sid" "$starttime"
}

diagnostic_signal_disposition() {
  local pid=${1:-} fd line value lines=0
  local ign=missing cgt=missing
  local IFS=$' \t\n'
  if ! { exec {fd}<"/proc/$pid/status"; } 2>/dev/null; then
    printf '%s\t%s\n' "$ign" "$cgt"
    return 0
  fi
  while (( lines < 96 )); do
    if ! IFS= read -r -t 0.005 -u "$fd" line; then
      break
    fi
    lines=$((lines + 1))
    case "$line" in
      SigIgn:*)
        value=${line#SigIgn:}
        value=${value#"${value%%[![:space:]]*}"}
        [[ "$value" =~ ^[0-9A-Fa-f]+$ ]] && ign=$value
        ;;
      SigCgt:*)
        value=${line#SigCgt:}
        value=${value#"${value%%[![:space:]]*}"}
        [[ "$value" =~ ^[0-9A-Fa-f]+$ ]] && cgt=$value
        ;;
    esac
    [[ "$ign" != missing && "$cgt" != missing ]] && break
  done
  exec {fd}<&-
  printf '%s\t%s\n' "$ign" "$cgt"
  return 0
}

diagnostic_process() {
  local role=$1 pid=$2 phase=${3:-before-watchdog-term}
  local snapshot disposition state ppid pgid sid starttime ign cgt
  local IFS=$' \t\n'
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || {
    diagnostic_emit "process phase=$phase role=$role pid=${pid:-missing} unavailable=invalid-pid"
    return 0
  }
  if ! snapshot=$(diagnostic_stat_snapshot "$pid"); then
    diagnostic_emit "process phase=$phase role=$role pid=$pid unavailable=proc-stat"
    return 0
  fi
  IFS=$'\t' read -r state ppid pgid sid starttime <<<"$snapshot" || {
    diagnostic_emit "process phase=$phase role=$role pid=$pid unavailable=proc-stat"
    return 0
  }
  disposition=$(diagnostic_signal_disposition "$pid") || disposition=$'missing\tmissing'
  IFS=$'\t' read -r ign cgt <<<"$disposition" || {
    ign=missing
    cgt=missing
  }
  diagnostic_emit "process phase=$phase role=$role pid=$pid ppid=$ppid pgid=$pgid sid=$sid starttime=$starttime state=$state SigIgn=$ign SigCgt=$cgt"
  return 0
}

diagnostic_pid_file() {
  local file=${1:-} value=
  local IFS=$' \t\n'
  [[ -f "$file" && ! -L "$file" ]] || return 1
  IFS= read -r value <"$file" || return 1
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$value"
}

diagnostic_registered_processes() {
  local phase=${1:-before-watchdog-term}
  local line key value supervisor_pid= business_pid=
  local worker_pid= child_pid= grandchild_pid=
  local IFS=$' \t\n'
  if [[ -f "$authority_marker" && ! -L "$authority_marker" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      key=${line%%=*}
      value=${line#*=}
      case "$key" in
        supervisor_pid) supervisor_pid=$value ;;
        business_pid) business_pid=$value ;;
      esac
    done <"$authority_marker"
  fi
  worker_pid=$(diagnostic_pid_file "$registered_worker_pid_file") || worker_pid=
  child_pid=$(diagnostic_pid_file "$registered_child_pid_file") || child_pid=
  grandchild_pid=$(diagnostic_pid_file "$registered_grandchild_pid_file") || grandchild_pid=
  diagnostic_emit "event=diagnostic-begin phase=$phase section=registered-processes"
  diagnostic_process inner-supervisor "$supervisor_pid" "$phase"
  diagnostic_process business-shell "$business_pid" "$phase"
  diagnostic_process udp-worker "$worker_pid" "$phase"
  diagnostic_process child "$child_pid" "$phase"
  diagnostic_process grandchild "$grandchild_pid" "$phase"
  diagnostic_emit "event=diagnostic-end phase=$phase section=registered-processes"
  return 0
}

# The parent starts this same bounded collector in pre-signal mode after all
# five registered identity files have been validated and before releasing the
# signaler.  It has no handshake side effects and never participates in
# signal delivery; the parent bounds it independently and proceeds on any
# timeout or failure.
if [[ "$handshake_role" == pre-signal ]]; then
  diagnostic_registered_processes before-signal || true
  exit 0
fi

validate_marker_phase_values() {
  local phase=$1 result_rc=$2 business_pid=$3 business_pgid=$4 business_starttime=$5
  case "$phase" in
    supervisor-ready)
      [[ "$result_rc" == 0 && "$business_pid" == 0 &&
        "$business_pgid" == 0 && "$business_starttime" == 0 ]] ;;
    business-starting)
      [[ "$result_rc" == 0 && "$business_pid" =~ ^[1-9][0-9]*$ &&
        "$business_pgid" == 0 && "$business_starttime" =~ ^[1-9][0-9]*$ ]] ;;
    business-ready|body-running|body-success)
      [[ "$result_rc" == 0 && "$business_pid" =~ ^[1-9][0-9]*$ &&
        "$business_pgid" =~ ^[1-9][0-9]*$ &&
        "$business_starttime" =~ ^[1-9][0-9]*$ ]] ;;
    business-exited|body-failed)
      [[ "$result_rc" =~ ^[1-9][0-9]*$ &&
        "$business_pid" =~ ^[1-9][0-9]*$ &&
        "$business_starttime" =~ ^[1-9][0-9]*$ ]] &&
        [[ "$business_pgid" =~ ^[1-9][0-9]*$ ]] ;;
    timeout)
      [[ "$result_rc" == "$RECOVERY_RC_TIMEOUT" &&
        "$business_pid" =~ ^[1-9][0-9]*$ &&
        "$business_pgid" =~ ^[1-9][0-9]*$ &&
        "$business_starttime" =~ ^[1-9][0-9]*$ ]] ;;
    *) return 1 ;;
  esac
}

hs_publish_ready "$handshake_role" "$handshake_token" "$handshake_ready" || exit 2
hs_wait_release "$handshake_ready" "$handshake_release" "$handshake_abort" "$handshake_token" "$handshake_role" || exit $?

atomic_stage() {
  local phase=$1 tmp stage_stat existing_token existing_role
  [[ "$phase" =~ ^[a-z][a-z0-9-]*(:[a-z0-9-]+)?$ ]] || return 1
  [[ -d "${stage_marker%/*}" && ! -L "${stage_marker%/*}" ]] || return 1
  if [[ -e "$stage_marker" || -L "$stage_marker" ]]; then
    [[ ! -L "$stage_marker" ]] || return 1
    stage_stat=$(stat -Lc '%F|%u|%h|%a' -- "$stage_marker" 2>/dev/null) || return 1
    [[ "$stage_stat" == "regular file|$(id -u)|1|600" ]] || return 1
    existing_token=$(awk -F= '$1 == "token" { print $2; exit }' "$stage_marker") || return 1
    existing_role=$(awk -F= '$1 == "role" { print $2; exit }' "$stage_marker") || return 1
    [[ "$existing_token" == "$handshake_token" && "$existing_role" == "$handshake_role" ]] || return 1
  fi
  tmp=$(mktemp -- "${stage_marker}.tmp.XXXXXX") || return 1
  printf 'token=%s\nrole=%s\nphase=%s\n' \
    "$handshake_token" "$handshake_role" "$phase" >"$tmp"
  chmod 0600 -- "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$stage_marker" || { rm -f -- "$tmp"; return 1; }
}
init_failed() {
  local reason=$1 field=${2:-unset} value=${3:-unset}
  atomic_stage "failed:$reason" || true
  printf 'token=%s role=%s phase=failed:%s field=%s value=%s\n' \
    "$handshake_token" "$handshake_role" "$reason" "$field" "$value" \
    >"$failure_marker"
  printf 'watchdog_timeout target_pid=%s term_sent=0 kill_sent=0 reason=%s field=%s value=%s\n' \
    "$target" "$reason" "$field" "$value" >"$timeout_marker"
  exit 1
}
atomic_stage release-consumed || init_failed stage-write release-consumed failed

trap 'exit 143' INT TERM HUP

proc_snapshot() {
  local pid=$1 line rest
  local -a fields=()
  [[ "$pid" =~ ^[0-9]+$ && "$pid" != 0 ]] || return 1
  [[ -r "/proc/$pid/stat" ]] || return 1
  line=$(<"/proc/$pid/stat") || return 1
  rest=${line#*') '}
  [[ "$rest" != "$line" ]] || return 1
  read -r -a fields <<<"$rest"
  PROC_STATE=${fields[0]-}
  PROC_PGID=${fields[2]-}
  PROC_STARTTIME=${fields[19]-}
  [[ "$PROC_STATE" =~ ^[A-Za-z]$ && "$PROC_STATE" != Z* &&
    "$PROC_PGID" =~ ^[1-9][0-9]*$ && "$PROC_STARTTIME" =~ ^[0-9]+$ ]]
}

group_state() {
  local wanted=$1 snapshot line pid pgid state live=0 member=0
  [[ "$wanted" =~ ^[1-9][0-9]*$ ]] || return 2
  snapshot=$(${REAL_PS:?} -eo pid=,pgid=,stat= 2>/dev/null) || return 2
  while read -r pid pgid state; do
    [[ -n "$pid" && -n "$pgid" && -n "$state" ]] || return 2
    [[ "$pgid" == "$wanted" ]] || continue
    member=1
    [[ "$state" == Z* ]] || live=1
  done <<<"$snapshot"
  (( live )) && return 0
  (( member )) && return 1
  return 1
}

own_pgid=$(${REAL_PS:?} -o pgid= -p "$$" 2>/dev/null | ${REAL_TR:?} -d '[:space:]')
[[ "$own_pgid" =~ ^[1-9][0-9]*$ ]] || init_failed invalid-identity own_pgid "$own_pgid"
[[ "$caller_pgid" =~ ^[1-9][0-9]*$ ]] || init_failed invalid-identity caller_pgid "$caller_pgid"
[[ "$suite_pgid" =~ ^[1-9][0-9]*$ ]] || init_failed invalid-identity suite_pgid "$suite_pgid"
[[ "$signaler_pid" =~ ^[1-9][0-9]*$ ]] || init_failed invalid-identity signaler_pid "$signaler_pid"
[[ "$signaler_pgid" =~ ^[1-9][0-9]*$ ]] || init_failed invalid-identity signaler_pgid "$signaler_pgid"
[[ "$signaler_starttime" =~ ^[0-9]+$ ]] || init_failed invalid-identity signaler_starttime "$signaler_starttime"
[[ "$caller_pid" =~ ^[1-9][0-9]*$ ]] || init_failed invalid-identity caller_pid "$caller_pid"
[[ "$suite_pid" =~ ^[1-9][0-9]*$ ]] || init_failed invalid-identity suite_pid "$suite_pid"
[[ "$fallback_pid" =~ ^[1-9][0-9]*$ ]] || init_failed invalid-identity fallback_pid "$fallback_pid"
[[ "$fallback_pgid" =~ ^[1-9][0-9]*$ ]] || init_failed invalid-identity fallback_pgid "$fallback_pgid"
[[ "$fallback_pid" != "$$" && "$fallback_pgid" != "$own_pgid" &&
  "$fallback_pid" != "$caller_pid" && "$fallback_pid" != "$suite_pid" &&
  "$fallback_pid" != "$signaler_pid" && "$fallback_pgid" != "$caller_pgid" &&
  "$fallback_pgid" != "$suite_pgid" && "$fallback_pgid" != "$signaler_pgid" ]] ||
  init_failed protected-identity fallback_pid "$fallback_pid"

authority_marker_valid() {
  local line key value count=0
  local -A seen=()
  [[ -f "$authority_marker" && ! -L "$authority_marker" ]] || return 1
  [[ "$(stat -Lc '%F %u %a' -- "$authority_marker" 2>/dev/null)" == \
    "regular file $(id -u) 600" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* && "$line" != *=*=* && "$line" != *$'\r' ]] || return 1
    key=${line%%=*}; value=${line#*=}
    [[ "$key" =~ ^[a-z_]+$ && -n "$value" && -z ${seen[$key]+x} ]] || return 1
    case "$key" in
      phase|lock_inode|result_rc|supervisor_pid|supervisor_pgid|supervisor_starttime|business_pid|business_pgid|business_starttime) ;;
      *) return 1 ;;
    esac
    seen[$key]=$value
    count=$((count + 1))
  done <"$authority_marker"
  [[ "$count" == 9 && ${seen[phase]-} =~ ^(business-ready|body-running)$ &&
    ${seen[result_rc]-} =~ ^(0|[1-9][0-9]*)$ &&
    ${seen[lock_inode]-} =~ ^[1-9][0-9]*:[1-9][0-9]*$ &&
    ${seen[supervisor_pid]-} =~ ^[1-9][0-9]*$ &&
    ${seen[supervisor_pgid]-} =~ ^[1-9][0-9]*$ &&
    ${seen[supervisor_starttime]-} =~ ^[1-9][0-9]*$ &&
    ${seen[business_pid]-} =~ ^[1-9][0-9]*$ &&
    ${seen[business_pgid]-} == ${seen[business_pid]} &&
    ${seen[business_starttime]-} =~ ^[1-9][0-9]*$ ]] || return 1
  validate_marker_phase_values "${seen[phase]}" "${seen[result_rc]}" \
    "${seen[business_pid]}" "${seen[business_pgid]}" \
    "${seen[business_starttime]}" || return 1
  proc_snapshot "${seen[supervisor_pid]}" || return 1
  [[ "$PROC_STARTTIME" == "${seen[supervisor_starttime]}" &&
    "$PROC_PGID" == "${seen[supervisor_pgid]}" ]] || return 1
  proc_snapshot "${seen[business_pid]}" || return 1
  [[ "$PROC_STARTTIME" == "${seen[business_starttime]}" &&
    "$PROC_PGID" == "${seen[business_pgid]}" ]] || return 1
  [[ "$target" != "${seen[supervisor_pid]}" &&
    "$target" != "${seen[business_pid]}" &&
    "$target_pgid" != "${seen[supervisor_pgid]}" &&
    "$target_pgid" != "${seen[business_pgid]}" ]]
}

refresh_target() {
  local value
  if [[ -s "$pid_file" ]]; then
    value=$(<"$pid_file")
    [[ "$value" =~ ^[1-9][0-9]*$ ]] && target=$value
  fi
  if [[ -s "$pgid_file" ]]; then
    value=$(<"$pgid_file")
    [[ "$value" =~ ^[1-9][0-9]*$ ]] && target_pgid=$value
  fi
}

target_valid() {
  local expected first second
  [[ "$target" =~ ^[1-9][0-9]*$ && "$target" != "1" && "$target" != "$$" &&
    "$target" != "$PPID" && "$target" != "$caller_pid" &&
    "$target" != "$suite_pid" && "$target" != "$signaler_pid" &&
    "$target_pgid" =~ ^[1-9][0-9]*$ && "$target_pgid" != "$own_pgid" &&
    "$target_pgid" != "$caller_pgid" && "$target_pgid" != "$suite_pgid" &&
    "$target_pgid" != "$signaler_pgid" ]] || return 1
  expected=$(<"$starttime_file")
  [[ "$expected" =~ ^[0-9]+$ ]] || return 1
  proc_snapshot "$target" || return 1
  [[ "$PROC_STARTTIME" == "$expected" && "$PROC_PGID" == "$target_pgid" ]] || return 1
  first="$target:$PROC_STARTTIME:$PROC_PGID"
  /bin/sleep 0.01
  proc_snapshot "$target" || return 1
  second="$target:$PROC_STARTTIME:$PROC_PGID"
  [[ "$first" == "$second" && "$PROC_STARTTIME" == "$expected" &&
    "$PROC_PGID" == "$target_pgid" ]] || return 1
  authority_marker_valid || return 1
  group_state "$target_pgid"
}

signaler_is_gone() {
  local line rest state
  local -a fields=()
  [[ -e "/proc/$signaler_pid" ]] || return 0
  [[ -r "/proc/$signaler_pid/stat" ]] || return 1
  line=$(<"/proc/$signaler_pid/stat") || return 1
  rest=${line#*') '}
  read -r -a fields <<<"$rest"
  state=${fields[0]-}
  PROC_PGID=${fields[2]-}
  PROC_STARTTIME=${fields[19]-}
  [[ "$PROC_PGID" == "$signaler_pgid" &&
    "$PROC_STARTTIME" == "$signaler_starttime" && "$state" != Z* ]] && return 1
  return 0
}

# The parent publishes a stable setsid PID/PGID/starttime before starting this
# watchdog.  A success marker from the signaler cancels the watchdog; a failure
# marker permits a bounded, identity-checked fallback only.
for ((i = 0; i < 2000; i++)); do
  refresh_target
  if [[ -e "$signal_marker" ]]; then
    diagnostic_registered_processes signal-sent || true
    exit 0
  fi
  if [[ -e "$failure_marker" ]] || signaler_is_gone; then
    break
  fi
  /bin/sleep 0.01
done

refresh_target
if [[ -e "$signal_marker" ]]; then
  diagnostic_registered_processes signal-sent || true
  exit 124
fi

# Preserve the process-chain evidence before any watchdog TERM/KILL fallback.
# This is intentionally after the success-marker check and before target
# validation or signal delivery, so normal successful INT paths are untouched.
diagnostic_registered_processes || true

if ! target_valid; then
  printf 'watchdog_timeout target_pid=%s term_sent=0 kill_sent=0 reason=identity\n' "$target" \
    >"$timeout_marker"
  exit 124
fi
atomic_stage timeout-actions
term_tmp="${term_sent_marker}.tmp.$$"
if ! target_valid || ! kill -TERM -- "-$target_pgid" 2>/dev/null; then
  printf 'watchdog_timeout target_pid=%s term_sent=0 kill_sent=0 reason=term-kill-failed\n' \
    "$target" >"$timeout_marker"
  exit 124
fi
printf 'term_sent target_pid=%s starttime=%s pgid=%s\n' "$target" "$(<"$starttime_file")" \
  "$target_pgid" >"$term_tmp"
mv -f -- "$term_tmp" "$term_sent_marker"
kill_sent=0
for ((i = 0; i < 200; i++)); do
  group_rc=0
  group_state "$target_pgid" || group_rc=$?
  if (( group_rc == 1 )); then
    printf 'watchdog_timeout target_pid=%s term_sent=1 kill_sent=0\n' "$target" \
      >"$timeout_marker"
    exit 124
  fi
  (( group_rc == 2 )) && {
    printf 'watchdog_timeout target_pid=%s term_sent=1 kill_sent=0 reason=group-unknown\n' \
      "$target" >"$timeout_marker"
    exit 124
  }
  /bin/sleep 0.01
done

if ! target_valid; then
  printf 'watchdog_timeout target_pid=%s term_sent=1 kill_sent=0 reason=identity\n' \
    "$target" >"$timeout_marker"
  exit 124
fi
if kill -KILL -- "-$target_pgid" 2>/dev/null; then
  kill_sent=1
  kill_tmp="${kill_sent_marker}.tmp.$$"
  printf 'kill_sent target_pid=%s starttime=%s pgid=%s\n' "$target" "$(<"$starttime_file")" \
    "$target_pgid" >"$kill_tmp"
  mv -f -- "$kill_tmp" "$kill_sent_marker"
else
  printf 'watchdog_timeout target_pid=%s term_sent=1 kill_sent=0 reason=kill-failed\n' \
    "$target" >"$timeout_marker"
  exit 124
fi
printf 'watchdog_timeout target_pid=%s term_sent=1 kill_sent=%s\n' \
  "$target" "$kill_sent" >"$timeout_marker"
exit 124
EOF
chmod 0755 -- "$int_watchdog"

INT_HELPERS=("$int_wrapper" "$int_signaler" "$int_watchdog")
[[ ${#INT_HELPERS[@]} == 3 ]] || {
  printf 'expected exactly 3 INT helper files, got %s\n' "${#INT_HELPERS[@]}" >&2
  exit 1
}
for generated_helper in "${INT_HELPERS[@]}"; do
  [[ -f "$generated_helper" && ! -L "$generated_helper" ]] || {
    printf 'INT helper is not an exact regular file: %s\n' "$generated_helper" >&2
    exit 1
  }
  bash -n -- "$generated_helper"
done
static_check_helper_symbols "${INT_HELPERS[@]}"
ALL_GENERATED_HELPERS=("${FAKE_HELPERS[@]}" "${INT_HELPERS[@]}")
[[ ${#ALL_GENERATED_HELPERS[@]} == 12 ]] || {
  printf 'expected exactly 12 generated helper files, got %s\n' \
    "${#ALL_GENERATED_HELPERS[@]}" >&2
  exit 1
}
for generated_helper in "${ALL_GENERATED_HELPERS[@]}"; do
  [[ -f "$generated_helper" && ! -L "$generated_helper" ]] || {
    printf 'generated helper is not an exact regular file: %s\n' "$generated_helper" >&2
    exit 1
  }
done
static_check_helper_symbols "${ALL_GENERATED_HELPERS[@]}"
grep -Fq 'diagnostic_registered_processes' "$int_watchdog"
! grep -Eq '/proc/\$pid/(cmdline|environ)' "$int_watchdog"
pass 'INT wrapper, authority signaler and watchdog helpers pass bash -n and self-contained function checks'

# Run INT with a fresh process registry. TERM has its own independently reaped
# fixture; no scenario is allowed to inherit marker files or registered PIDs.
reset_test_process_registry
int_checked 'INT fixture marker reset' clear_fixture_markers \
  "$int_outer_pid_file" "$int_outer_pgid_file" "$int_signaler_marker" "$int_signaler_diagnostic" \
  "$int_signaler_failed" "$int_signaler_stage" "$int_outer_starttime_file" "$int_watchdog_timeout_marker" \
  "$int_watchdog_term_sent" "$int_watchdog_stage" "$int_supervisor_ready" "$int_signaler_ready" "$int_signaler_release" \
  "$int_signaler_abort" "$int_watchdog_ready" "$int_watchdog_release" "$int_watchdog_abort" \
  "$int_sentinel_ready" "$int_caller_sentinel_signal" "$int_delivered_file" \
  "$int_process_diagnostic" \
  "$hold_pid_file" "$hold_starttime_file" "$hold_fd_file" "$hold_descendant_file" "$hold_child_file" \
  "$hold_grandchild_file" "$hold_child_fd_file" "$hold_grandchild_fd_file"

/usr/bin/setsid /bin/bash -c '
  ready=$1
  signal_file=$2
  printf ready >"$ready"
  on_signal() { printf signal >"$signal_file"; exit 143; }
  trap on_signal INT TERM HUP
  for ((i = 0; i < 6000; i++)); do /bin/sleep 0.05; done
' sh "$int_sentinel_ready" "$int_caller_sentinel_signal" &
int_sentinel=$!
if ! register_test_process_bounded "$int_sentinel" 'int-caller-sentinel'; then
  stop_test_processes || true
  exit 1
fi
int_sentinel_ready_rc=1
for ((i = 0; i < 300; i++)); do
  if [[ -s "$int_sentinel_ready" ]]; then
    int_sentinel_ready_rc=0
    break
  fi
  int_checked "INT sentinel readiness tick=$i" /bin/sleep 0.01
done
if (( int_sentinel_ready_rc != 0 )) || [[ ! -e "$int_sentinel_ready" || -e "$int_caller_sentinel_signal" ]]; then
  printf 'INT sentinel readiness check failed rc=1 ready=%s caller_signal=%s\n' \
    "$([[ -e "$int_sentinel_ready" ]] && printf yes || printf no)" \
    "$([[ -e "$int_caller_sentinel_signal" ]] && printf yes || printf no)" >&2
  int_fixture_diagnostics
  exit 1
fi

int_signaler_args=(
  "$int_handshake_helper" signaler "$int_signaler_token" "$int_signaler_ready" "$int_signaler_release" "$int_signaler_abort"
  INT "$int_outer_pid_file" "$int_outer_pgid_file" "$int_outer_starttime_file"
  "$int_signaler_marker" "$int_signaler_failed" "$int_signaler_diagnostic"
  "$int_signaler_stage" "$TEST_DIR/recovery-process-group-int.out" "$lock_root" "$int_supervisor_ready"
  "$TEST_CALLER_PGID" "$TEST_SHELL_PGID"
  "$PPID" "$$"
  "$hold_pid_file" "$hold_fd_file" "$hold_descendant_file"
  "$hold_child_file" "$hold_grandchild_file" "$hold_child_fd_file"
  "$hold_grandchild_fd_file" "$hold_starttime_file"
)

int_handshake_atomic() {
  local file=$1 content=$2 tmp
  tmp="${file}.tmp.$$"
  printf '%s\n' "$content" >"$tmp"
  chmod 0600 -- "$tmp"
  mv -f -- "$tmp" "$file"
}

validate_int_handshake() {
  local ready=$1 role=$2 token=$3 expected_pid=$4 line count=0 key value pid starttime pgid first second
  [[ -f "$ready" && ! -L "$ready" && "$(stat -Lc '%F|%u|%h|%a' -- "$ready" 2>/dev/null)" == "regular file|$(id -u)|1|600" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* && "$line" != *=*=* && "$line" != *$'\r' ]] || return 1
    key=${line%%=*}; value=${line#*=}
    case "$key" in token|role|pid|starttime|pgid) [[ -n "$value" ]] || return 1 ;; *) return 1 ;; esac
    count=$((count + 1))
  done <"$ready"
  [[ "$count" == 5 && "$(awk -F= '$1=="token"{print $2}' "$ready")" == "$token" && "$(awk -F= '$1=="role"{print $2}' "$ready")" == "$role" ]] || return 1
  pid=$(awk -F= '$1=="pid"{print $2}' "$ready"); starttime=$(awk -F= '$1=="starttime"{print $2}' "$ready"); pgid=$(awk -F= '$1=="pgid"{print $2}' "$ready")
  [[ "$pid" == "$expected_pid" && "$pid" =~ ^[1-9][0-9]*$ && "$pid" != 1 && "$starttime" =~ ^[0-9]+$ && "$pgid" =~ ^[1-9][0-9]*$ && "$pgid" != 1 ]] || return 1
  first="$(process_starttime "$pid" 2>/dev/null || true):$($REAL_PS -o pgid= -p "$pid" 2>/dev/null | $REAL_TR -d '[:space:]')"
  [[ "$first" == "$starttime:$pgid" ]] || return 1
  /bin/sleep 0.01
  second="$(process_starttime "$pid" 2>/dev/null || true):$($REAL_PS -o pgid= -p "$pid" 2>/dev/null | $REAL_TR -d '[:space:]')"
  [[ "$second" == "$first" ]]
}

int_pre_signal_identity_files_ready() {
  local file value phase
  [[ -f "$int_supervisor_ready" && ! -L "$int_supervisor_ready" &&
    "$(stat -Lc '%F|%u|%h|%a' -- "$int_supervisor_ready" 2>/dev/null)" == \
      "regular file|$(id -u)|1|600" ]] || return 1
  parse_authority_marker_file "$int_supervisor_ready" || return 1
  phase=$(awk -F= '$1 == "phase" { print $2; exit }' "$int_supervisor_ready")
  int_marker_phase_allows_signal "$phase" || return 1
  for file in "$hold_pid_file" "$hold_child_file" "$hold_grandchild_file"; do
    [[ -f "$file" && ! -L "$file" ]] || return 1
    value=$(head -n 1 -- "$file")
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
  done
  [[ -f "$hold_descendant_file" && ! -L "$hold_descendant_file" ]] || return 1
  [[ $(wc -l <"$hold_descendant_file") == 2 ]] || return 1
}

report_int_handshake_failure() {
  local label=$1 ready=$2 role=$3 token=$4 expected_pid=$5
  printf 'INT handshake validation failed label=%s role=%s token=%s expected_pid=%s\n' \
    "$label" "$role" "$token" "$expected_pid" >&2
  if [[ -e "$ready" ]]; then
    printf 'INT handshake ready=%s:\n' "$ready" >&2
    sed -n '1,20p' -- "$ready" >&2 || true
  else
    printf 'INT handshake ready=%s: missing\n' "$ready" >&2
  fi
  int_fixture_diagnostics
}

wait_for_int_helper_identity() {
  local pid_file=$1 pgid_file=$2 starttime_file=$3 launcher_pid=$4 label=$5
  local i pid pgid starttime
  for ((i = 0; i < 300; i++)); do
    if [[ -s "$pid_file" && -s "$pgid_file" && -s "$starttime_file" ]]; then
      pid=$(<"$pid_file"); pgid=$(<"$pgid_file"); starttime=$(<"$starttime_file")
      if [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != 1 && "$pgid" == "$pid" &&
        "$starttime" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$pid"
        return 0
      fi
    fi
    int_checked "$label identity readiness tick=$i" /bin/sleep 0.01 || return $?
  done
  printf '%s identity publication timed out launcher_pid=%s\n' "$label" "$launcher_pid" >&2
  return 1
}

declare -Ag INT_MARKER_DIRS_BEFORE=()
for int_marker_dir in /tmp/frp-xudp-recovery-marker.*; do
  [[ -d "$int_marker_dir" && ! -L "$int_marker_dir" ]] || continue
  INT_MARKER_DIRS_BEFORE["$int_marker_dir"]=1
done

# Run recovery in an independent setsid group. Publish both identifiers and
# validate that the group is distinct before starting helper processes.
# Bash starts asynchronous commands with SIGINT ignored. Reset the inherited
# dispositions before setsid/exec so the stable foreground wrapper can receive
# the signal sent by the registered signaler.
/usr/bin/env --default-signal=INT --default-signal=TERM --default-signal=HUP \
  "PATH=$FAKE_BIN:$PATH" "FAKE_DOCKER_LOG=$DOCKER_LOG" \
  "FAKE_TIMEOUT_LOG=$TIMEOUT_LOG" "FAKE_RM_LOG=$RM_LOG" "FAKE_STATE_DIR=$FAKE_STATE" \
  "REAL_MKTEMP=$REAL_MKTEMP" "REAL_RM=$REAL_RM" "REAL_STAT=$REAL_STAT" \
  "FAKE_BUILD_LOG=$FAKE_BUILD_LOG" "FAKE_LOCK_PATH=$lock_root" \
  "FAKE_UDP_HOLD_PID_FILE=$hold_pid_file" "FAKE_UDP_FD_FILE=$hold_fd_file" \
  "FAKE_UDP_HOLD_STARTTIME_FILE=$hold_starttime_file" \
  "FAKE_UDP_DESCENDANT_PID_FILE=$hold_descendant_file" \
  "FAKE_UDP_CHILD_PID_FILE=$hold_child_file" \
  "FAKE_UDP_GRANDCHILD_PID_FILE=$hold_grandchild_file" \
  "FAKE_UDP_CHILD_FD_FILE=$hold_child_fd_file" \
  "FAKE_UDP_GRANDCHILD_FD_FILE=$hold_grandchild_fd_file" \
  "FAKE_UDP_SIGNAL_DELIVERED_FILE=$int_delivered_file" "FAKE_UDP_INT_EXIT=130" \
  "FAKE_UDP_PROCESS_DIAGNOSTIC_FILE=$int_process_diagnostic" \
  "FRP_XUDP_INTERNAL_READY_FILE=$int_supervisor_ready" \
  "REAL_PS=$REAL_PS" "REAL_TR=$REAL_TR" \
  FRP_XUDP_RECOVERY_REPORT="$hold_report" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
  /usr/bin/setsid "$int_wrapper" "$int_outer_pid_file" "$int_outer_pgid_file" \
  "$int_outer_starttime_file" \
  "$RECOVERY" --existing >"$TEST_DIR/recovery-process-group-int.out" 2>&1 &
int_outer=$!
if ! register_test_process_bounded "$int_outer" 'int-foreground-wrapper'; then
  stop_test_processes || true
  exit 1
fi
int_outer_log="$TEST_DIR/recovery-process-group-int.out"
int_outer_ready_rc=1
for ((i = 0; i < 300; i++)); do
  if [[ -s "$int_outer_pgid_file" ]] && [[ $(<"$int_outer_pgid_file") == "$int_outer" ]]; then
    int_outer_ready_rc=0
    break
  fi
  int_checked "INT foreground readiness tick=$i" /bin/sleep 0.01
done
if (( int_outer_ready_rc != 0 )) || [[ ! -s "$int_outer_pid_file" || ! -s "$int_outer_pgid_file" ||
  $(<"$int_outer_pid_file") != "$int_outer" ||
  $(<"$int_outer_pgid_file") != "$int_outer" ]]; then
  printf 'INT foreground identity check failed rc=1 pid=%s\n' "$int_outer" >&2
  int_fixture_diagnostics
  printf 'foreground wrapper failed stable PID/PGID publication\n' >&2
  sed -n '1,240p' "$TEST_DIR/recovery-process-group-int.out" >&2 || true
  exit 1
fi
int_outer_pgid=$(<"$int_outer_pgid_file")

if ! wait_for_int_supervisor_ready; then
  stop_test_processes || true
  exit 1
fi
int_signaler_args[16]="$int_supervisor_ready"
pass 'INT starts signal helpers only after supervisor readiness'

set +e
env "REAL_PS=$REAL_PS" "REAL_TR=$REAL_TR" "REAL_STAT=$REAL_STAT" \
  "FRP_XUDP_INT_DIAGNOSTIC_FILE=$int_process_diagnostic" \
  "REAL_FLOCK=$(command -v flock)" /usr/bin/setsid "$int_signaler" "${int_signaler_args[@]}" &
int_sender=$!
set -e
if ! register_test_child_bounded "$int_sender" 'int-signaler'; then
  printf 'INT signaler registration failed pid=%s\n' "$int_sender" >&2
  report_int_handshake_failure 'register signaler' "$int_signaler_ready" signaler \
    "$int_signaler_token" "$int_sender"
  int_handshake_atomic "$int_signaler_abort" "token=$int_signaler_token role=signaler" || true
  stop_test_processes || true
  exit 1
fi
if ! validate_int_handshake "$int_signaler_ready" signaler "$int_signaler_token" "$int_sender"; then
  report_int_handshake_failure 'validate signaler' "$int_signaler_ready" signaler \
    "$int_signaler_token" "$int_sender"
  int_handshake_atomic "$int_signaler_abort" "token=$int_signaler_token role=signaler" || true
  stop_test_processes || true
  exit 1
fi
int_signaler_pgid=$(awk -F= '$1 == "pgid" { print $2 }' "$int_signaler_ready")
int_signaler_starttime=$(awk -F= '$1 == "starttime" { print $2 }' "$int_signaler_ready")
pass 'INT signaler publishes ready with the registered PID before release'

# All five role identities are already authenticated by the supervisor marker
# and the bounded worker/child/grandchild readiness barrier.  Reuse the
# watchdog's bounded collector in an independent, no-handshake mode before
# releasing the signaler.  This is best-effort only: a timeout or collector
# failure is reported on stderr and cannot delay or reorder the release.
# These values are consumed after the readiness branch as well.  Initialize
# them before the branch so the set -u test harness cannot lose their scope
# when the optional pre-signal snapshot is skipped.
int_pre_signal_token=
int_pre_signal_args=()
int_pre_signal_log="$TEST_DIR/recovery-int-pre-signal.log"
int_pre_signal_trace="$TEST_DIR/recovery-int-pre-signal.trace"
int_pre_signal_rc=0
int_pre_signal_tee_rc=0
if ! int_pre_signal_identity_files_ready; then
  printf 'INT pre-signal identity files are not complete; continuing without snapshot\n' >&2
else
  int_pre_signal_token="int-pre-signal-$RANDOM-$PPID"
  int_pre_signal_args=(
    "$int_handshake_helper" pre-signal "$int_pre_signal_token"
    "$TEST_DIR/recovery-int-pre-signal.ready"
    "$TEST_DIR/recovery-int-pre-signal.release"
    "$TEST_DIR/recovery-int-pre-signal.abort"
    "$int_outer_pid_file" "$int_outer_pgid_file" "$int_outer_starttime_file"
    "$int_signaler_marker" "$int_signaler_failed" "$int_signaler_diagnostic"
    "$int_signaler_stage" "$TEST_DIR/recovery-process-group-int.out" "$lock_root"
    "$int_supervisor_ready" "$TEST_CALLER_PGID" "$TEST_SHELL_PGID"
    "$PPID" "$$"
    "$hold_pid_file" "$hold_child_file" "$hold_grandchild_file"
  )
: >"$int_pre_signal_log"
printf 'event=pre-signal-dispatch phase=before-signal order=before-release\n' \
  >"$int_pre_signal_trace"
printf 'INT pre-signal collector begin log=%s trace=%s\n' \
  "$int_pre_signal_log" "$int_pre_signal_trace" >&2
set +e
/usr/bin/timeout --foreground 3 /usr/bin/setsid "$int_watchdog" \
  "${int_pre_signal_args[@]}" >"$int_pre_signal_log" 2>&1
int_pre_signal_rc=$?
set -e
if /usr/bin/tee -a "$int_pre_signal_trace" <"$int_pre_signal_log" >&2; then
  int_pre_signal_tee_rc=0
else
  int_pre_signal_tee_rc=$?
fi
printf 'event=pre-signal-dispatch phase=before-signal order=before-release rc=%s tee_rc=%s\n' \
  "$int_pre_signal_rc" "$int_pre_signal_tee_rc" >>"$int_pre_signal_trace"
printf 'INT pre-signal collector end rc=%s tee_rc=%s; release has not started\n' \
  "$int_pre_signal_rc" "$int_pre_signal_tee_rc" >&2
if (( int_pre_signal_tee_rc != 0 )); then
  printf 'INT pre-signal collector log publication failed rc=%s\n' \
    "$int_pre_signal_tee_rc" >&2
  exit 1
fi
case "$int_pre_signal_rc" in
    0) printf 'INT pre-signal snapshot completed before signaler release\n' >&2 ;;
    124) printf 'INT pre-signal snapshot timed out rc=124; continuing to release signaler\n' >&2 ;;
    *) printf 'INT pre-signal snapshot failed rc=%s; continuing to release signaler\n' \
      "$int_pre_signal_rc" >&2 ;;
  esac
fi
if ! wait_for_int_release_barrier; then
  printf 'INT signaler release refused: business PGID barrier was not satisfied\n' >&2
  int_fixture_diagnostics
  exit 1
fi
[[ "${int_release_released:-0}" == 1 ]] || {
  printf 'INT release barrier returned without publishing release\n' >&2
  int_fixture_diagnostics
  exit 1
}
printf 'event=signaler-release phase=release order=after-before-signal\n' \
  >>"$int_pre_signal_trace"

int_marker_reset_rc=0
int_checked 'INT watchdog marker reset' clear_fixture_markers \
  "$int_watchdog_timeout_marker" "$int_watchdog_term_sent" \
  "$int_watchdog_kill_sent" "$int_watchdog_stage"
int_marker_reset_rc=$?
if (( int_marker_reset_rc != 0 )); then
  printf 'INT watchdog marker reset failed rc=%s\n' "$int_marker_reset_rc" >&2
  int_fixture_diagnostics
  exit 1
fi
env "REAL_PS=$REAL_PS" "REAL_TR=$REAL_TR" \
  /usr/bin/setsid "$int_wrapper" "$int_watchdog_pid_file" \
  "$int_watchdog_pgid_file" "$int_watchdog_starttime_file" \
  "$int_watchdog" "$int_handshake_helper" watchdog "$int_watchdog_token" \
  "$int_watchdog_ready" "$int_watchdog_release" "$int_watchdog_abort" \
  "$int_outer_pid_file" "$int_outer_pgid_file" \
  "$int_outer_starttime_file" "$int_signaler_marker" "$int_signaler_failed" \
  "$int_watchdog_timeout_marker" "$int_watchdog_term_sent" "$int_watchdog_kill_sent" \
  "$int_watchdog_stage" \
  "$int_outer" "$int_outer_pgid" "$TEST_CALLER_PGID" "$TEST_SHELL_PGID" "$int_sender" \
  "$int_signaler_pgid" "$int_signaler_starttime" "$int_supervisor_ready" "${PPID}" "$$" \
  "$hold_pid_file" "$hold_child_file" "$hold_grandchild_file" &
int_watchdog_launcher=$!
set -e
if ! int_watchdog_pid=$(wait_for_int_helper_identity "$int_watchdog_pid_file" \
  "$int_watchdog_pgid_file" "$int_watchdog_starttime_file" \
  "$int_watchdog_launcher" 'INT watchdog'); then
  stop_test_processes || true
  exit 1
fi
if ! register_test_child_bounded "$int_watchdog_pid" 'int-watchdog'; then
  printf 'INT watchdog registration failed pid=%s\n' "$int_watchdog_pid" >&2
  report_int_handshake_failure 'register watchdog' "$int_watchdog_ready" watchdog \
    "$int_watchdog_token" "$int_watchdog_pid"
  int_handshake_atomic "$int_watchdog_abort" "token=$int_watchdog_token role=watchdog" || true
  stop_test_processes || true
  exit 1
fi
if ! validate_int_handshake "$int_watchdog_ready" watchdog "$int_watchdog_token" "$int_watchdog_pid"; then
  report_int_handshake_failure 'validate watchdog' "$int_watchdog_ready" watchdog \
    "$int_watchdog_token" "$int_watchdog_pid"
  int_handshake_atomic "$int_watchdog_abort" "token=$int_watchdog_token role=watchdog" || true
  stop_test_processes || true
  exit 1
fi
pass 'INT watchdog publishes ready with the registered PID before release'
int_handshake_atomic "$int_watchdog_release" "token=$int_watchdog_token role=watchdog"

set +e
wait_for_int_outer_bounded "$int_outer"
int_outer_rc=$?
set -e
if [[ "$int_outer_rc" == 124 ]]; then
  printf 'INT foreground did not reap within bounded wait; invoking registered cleanup identity=%s\n' \
    "$int_outer" >&2
  registered_pid_kill TERM "$int_outer" || true
  wait_for_process_exit "$int_outer" || true
  set +e
  wait "$int_outer"
  int_outer_rc=$?
  set -e
  TEST_CHILD_STATUS["$int_outer"]=$int_outer_rc
fi

# Cancel and reap the watchdog immediately after the foreground command
# returns. Its only normal-path outcomes are cancellation (143) or noticing
# that the target has already exited (0); either case must leave no timeout
# marker.
int_watchdog_state_rc=0
test_process_state "$int_watchdog_pid" || int_watchdog_state_rc=$?
case "$int_watchdog_state_rc" in
  0)
    int_watchdog_signal_rc=0
    registered_pid_kill TERM "$int_watchdog_pid" || int_watchdog_signal_rc=$?
    if (( int_watchdog_signal_rc != 0 )); then
      # The watchdog may finish naturally between the state snapshot above
      # and the authenticated kill.  Reclassify only a now-missing registered
      # PID as the expected teardown race; an alive, reused, or unreadable PID
      # remains a hard failure.
      int_watchdog_gone_rc=0
      test_process_state "$int_watchdog_pid" || int_watchdog_gone_rc=$?
      if (( int_watchdog_gone_rc != 1 )); then
        printf 'INT watchdog TERM failed rc=%s pid=%s\n' "$int_watchdog_signal_rc" \
          "$int_watchdog_pid" >&2
        int_fixture_diagnostics
        exit 1
      fi
    fi
    ;;
  1) ;;
  *)
    printf 'INT watchdog state unknown rc=%s pid=%s\n' "$int_watchdog_state_rc" \
      "$int_watchdog_pid" >&2
    int_fixture_diagnostics
    exit 1
    ;;
esac
set +e
wait "$int_watchdog_pid"
int_watchdog_rc=$?
set -e
TEST_CHILD_STATUS["$int_watchdog_pid"]=$int_watchdog_rc
if [[ ! -s "$int_outer_pid_file" ]]; then
  printf 'foreground wrapper PID file check failed rc=1\n' >&2
  int_fixture_diagnostics
  printf 'foreground wrapper did not publish its PID\n' >&2
  sed -n '1,240p' "$TEST_DIR/recovery-process-group-int.out" >&2 || true
  exit 1
fi
published_int_outer=$(<"$int_outer_pid_file")
if [[ "$published_int_outer" != "$int_outer" ]]; then
  printf 'INT foreground wrapper identity changed after startup: initial=%s published=%s\n' \
    "$int_outer" "$published_int_outer" >&2
  int_fixture_diagnostics
  exit 1
fi
int_outer=$published_int_outer
if [[ $int_watchdog_rc != 0 && $int_watchdog_rc != 143 ]]; then
  printf 'INT watchdog returned unexpected status: %s\n' "$int_watchdog_rc" >&2
  int_fixture_diagnostics
  exit 1
fi
if [[ -e "$int_watchdog_timeout_marker" ]]; then
  printf 'INT watchdog unexpectedly triggered:\n' >&2
  sed -n '1,40p' -- "$int_watchdog_timeout_marker" >&2
  int_fixture_diagnostics
  exit 1
fi
if [[ $int_outer_rc != 130 ]]; then
  wait_for_process_exit "$int_sender" || true
  set +e
  wait "$int_sender"
  int_sender_rc=$?
  set -e
  printf 'foreground recovery returned unexpected INT status: %s\n' "$int_outer_rc" >&2
  printf 'INT signaler rc=%s\n' "$int_sender_rc" >&2
  for file in "$int_signaler_marker" "$int_delivered_file" "$hold_pid_file" \
    "$hold_child_file" "$hold_grandchild_file"; do
    printf '%s: ' "$file" >&2
    if [[ -e "$file" ]]; then
      sed -n '1,40p' -- "$file" >&2
    else
      printf 'missing\n' >&2
    fi
  done
  sed -n '1,240p' "$int_signaler_diagnostic" >&2 || true
  sed -n '1,240p' "$TEST_DIR/recovery-process-group-int.out" >&2
  exit 1
fi
set +e
wait "$int_sender"
int_sender_rc=$?
set -e
if [[ $int_sender_rc != 0 || ! -s "$int_signaler_marker" ]]; then
  printf 'INT signaler failed: rc=%s\n' "$int_sender_rc" >&2
  sed -n '1,240p' "$int_signaler_diagnostic" >&2 || true
  sed -n '1,240p' "$TEST_DIR/recovery-process-group-int.out" >&2 || true
  int_fixture_diagnostics
  exit 1
fi
if ! kill -0 "$int_sentinel" 2>/dev/null; then
  printf 'INT caller sentinel was not alive rc=1 pid=%s\n' "$int_sentinel" >&2
  int_fixture_diagnostics
  exit 1
fi
if [[ -e "$int_caller_sentinel_signal" ]]; then
  printf 'INT caller sentinel received an unexpected signal rc=1\n' >&2
  int_fixture_diagnostics
  exit 1
fi
pass 'foreground recovery INT does not kill the caller sentinel'

report_int_delivery_failure() {
  local reason=$1 rc=${2:-unknown} file role
  printf 'INT delivery assertion failed reason=%s rc=%s int_outer_rc=%s int_sender_rc=%s\n' \
    "$reason" "$rc" "${int_outer_rc-unknown}" "${int_sender_rc-unknown}" >&2
  for role in worker child grandchild; do
    case "$role" in
      worker) file=$hold_pid_file ;;
      child) file=$hold_child_file ;;
      grandchild) file=$hold_grandchild_file ;;
    esac
    if [[ -e "$file" ]]; then
      printf 'INT role=%s pid_file=%s exists=1 content=\n' "$role" "$file" >&2
      sed -n '1,40p' -- "$file" >&2 || true
    else
      printf 'INT role=%s pid_file=%s exists=0\n' "$role" "$file" >&2
    fi
  done
  for file in "$int_delivered_file" "$int_signaler_marker" "$int_signaler_failed" \
    "$int_signaler_stage" "$int_outer_log" "$int_process_diagnostic" \
    "$int_pre_signal_log" "$int_pre_signal_trace"; do
    if [[ -e "$file" ]]; then
      printf 'INT marker=%s exists=1 content=\n' "$file" >&2
      sed -n '1,80p' -- "$file" >&2 || true
    else
      printf 'INT marker=%s exists=0\n' "$file" >&2
    fi
  done
}

for pid_file in "$hold_pid_file" "$hold_child_file" "$hold_grandchild_file"; do
  if [[ ! -f "$pid_file" || -L "$pid_file" ]]; then
    report_int_delivery_failure "missing-role-pid-file:$pid_file" 1
    exit 1
  fi
  if pid=$(head -n 1 -- "$pid_file"); then
    :
  else
    pid_read_rc=$?
    report_int_delivery_failure "role-pid-read:$pid_file" "$pid_read_rc"
    exit 1
  fi
  if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
    report_int_delivery_failure "invalid-role-pid:$pid_file" 1
    exit 1
  fi
  if wait_for_process_exit "$pid"; then
    wait_role_rc=0
  else
    wait_role_rc=$?
  fi
  if (( wait_role_rc != 0 )); then
    report_int_delivery_failure "role-not-reaped:$pid_file" "$wait_role_rc"
    exit 1
  fi
done
if [[ ! -f "$int_delivered_file" || -L "$int_delivered_file" ]]; then
  report_int_delivery_failure missing-int-marker 1
  exit 1
fi
if int_marker_count=$(grep -Ec '^INT:[0-9]+$' "$int_delivered_file"); then
  int_marker_grep_rc=0
else
  int_marker_grep_rc=$?
fi
if (( int_marker_grep_rc != 0 )) || [[ "$int_marker_count" != 3 ]]; then
  report_int_delivery_failure "int-marker-count:$int_marker_count" "$int_marker_grep_rc"
  exit 1
fi
if kill -0 "$int_sentinel" 2>/dev/null; then
  int_sentinel_alive_rc=0
else
  int_sentinel_alive_rc=$?
  report_int_delivery_failure caller-sentinel-not-alive "$int_sentinel_alive_rc"
  exit 1
fi
if [[ -e "$int_caller_sentinel_signal" ]]; then
  report_int_delivery_failure caller-sentinel-signaled 1
  exit 1
fi
pass 'INT exits 130, reaches the UDP worker and reaps its child and grandchild'
[[ $(<"$hold_fd_file") == 0 && $(<"$hold_child_fd_file") == 0 &&
  $(<"$hold_grandchild_fd_file") == 0 ]]
registered_pid_kill TERM "$int_sentinel"
set +e
wait "$int_sentinel"
int_sentinel_rc=$?
set -e
TEST_CHILD_STATUS["$int_sentinel"]=$int_sentinel_rc
[[ $int_sentinel_rc == 143 && -e "$int_caller_sentinel_signal" ]]
int_relock_report="$TEST_DIR/recovery-relock-after-int.log"
run_expect 0 "$TEST_DIR/recovery-relock-after-int.out" "${base_env[@]}" \
  FRP_XUDP_RECOVERY_REPORT="$int_relock_report" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
  bash "$RECOVERY" --existing
require_result_once "$int_relock_report" PASS 0
pass 'INT leaves all lock-FD counts at zero and permits immediate relock'

reset_test_process_registry
: >"$DOCKER_LOG"
hold_report="$TEST_DIR/recovery-process-group-hup.log"
hold_output_file="$TEST_DIR/recovery-process-group-hup.out"
hold_pid_file="$TEST_DIR/recovery-hup-hold.pid"
hold_fd_file="$TEST_DIR/recovery-hup-hold-fd-count"
hold_descendant_file="$TEST_DIR/recovery-hup-hold-descendants"
hold_child_file="$TEST_DIR/recovery-hup-hold-child.pid"
hold_grandchild_file="$TEST_DIR/recovery-hup-hold-grandchild.pid"
hold_child_fd_file="$TEST_DIR/recovery-hup-hold-child-fd-count"
hold_grandchild_fd_file="$TEST_DIR/recovery-hup-hold-grandchild-fd-count"
hup_delivered_file="$TEST_DIR/recovery-hup-delivered.log"
hup_sentinel_ready="$TEST_DIR/recovery-hup-sentinel.ready"
hup_caller_sentinel_signal="$TEST_DIR/recovery-hup-sentinel.signal"
hup_worker_wait_fifo="$TEST_DIR/recovery-hup-worker-wait.fifo"
hup_child_wait_fifo="$TEST_DIR/recovery-hup-child-wait.fifo"
hup_grandchild_wait_fifo="$TEST_DIR/recovery-hup-grandchild-wait.fifo"
mkfifo -m 600 -- "$hup_worker_wait_fifo" "$hup_child_wait_fifo" "$hup_grandchild_wait_fifo"
exec {hup_worker_wait_fd}<>"$hup_worker_wait_fifo"
exec {hup_child_wait_fd}<>"$hup_child_wait_fifo"
exec {hup_grandchild_wait_fd}<>"$hup_grandchild_wait_fifo"
clear_fixture_markers "$hup_delivered_file" "$hup_sentinel_ready" "$hup_caller_sentinel_signal" \
  "$hold_pid_file" "$hold_fd_file" "$hold_descendant_file" "$hold_child_file" \
  "$hold_grandchild_file" "$hold_child_fd_file" "$hold_grandchild_fd_file"
/usr/bin/setsid /bin/bash -c '
  ready=$1
  signal_file=$2
  printf ready >"$ready"
  on_signal() { printf signal >"$signal_file"; exit 143; }
  trap on_signal INT TERM HUP
  for ((i = 0; i < 6000; i++)); do /bin/sleep 0.05; done
' sh "$hup_sentinel_ready" "$hup_caller_sentinel_signal" &
hup_sentinel=$!
if ! register_test_process_bounded "$hup_sentinel" 'hup-caller-sentinel'; then
  stop_test_processes || true
  exit 1
fi
for ((i = 0; i < 300; i++)); do
  [[ -s "$hup_sentinel_ready" ]] && break
  /bin/sleep 0.01
done
[[ -s "$hup_sentinel_ready" && ! -e "$hup_caller_sentinel_signal" ]]
set +e
env "PATH=$FAKE_BIN:$PATH" "FAKE_DOCKER_LOG=$DOCKER_LOG" \
  "FAKE_TIMEOUT_LOG=$TIMEOUT_LOG" "FAKE_RM_LOG=$RM_LOG" "FAKE_STATE_DIR=$FAKE_STATE" \
  "REAL_MKTEMP=$REAL_MKTEMP" "REAL_RM=$REAL_RM" "REAL_STAT=$REAL_STAT" \
  "FAKE_BUILD_LOG=$FAKE_BUILD_LOG" "FAKE_LOCK_PATH=$lock_root" \
  "FAKE_UDP_HOLD_PID_FILE=$hold_pid_file" "FAKE_UDP_FD_FILE=$hold_fd_file" \
  "FAKE_UDP_DESCENDANT_PID_FILE=$hold_descendant_file" \
  "FAKE_UDP_CHILD_PID_FILE=$hold_child_file" \
  "FAKE_UDP_GRANDCHILD_PID_FILE=$hold_grandchild_file" \
  "FAKE_UDP_CHILD_FD_FILE=$hold_child_fd_file" \
  "FAKE_UDP_GRANDCHILD_FD_FILE=$hold_grandchild_fd_file" \
  "FAKE_UDP_SIGNAL_DELIVERED_FILE=$hup_delivered_file" \
  "FAKE_UDP_WAIT_FD=$hup_worker_wait_fd" \
  "FAKE_UDP_CHILD_WAIT_FD=$hup_child_wait_fd" \
  "FAKE_UDP_GRANDCHILD_WAIT_FD=$hup_grandchild_wait_fd" \
  FRP_XUDP_RECOVERY_REPORT="$hold_report" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
  /usr/bin/setsid bash "$RECOVERY" --existing >"$hold_output_file" 2>&1 &
hup_outer=$!
# wait_for_hold_ready and its diagnostics use the shared hold_outer identity.
# Bind it to this scenario's direct child before invoking the shared helper;
# signal delivery and wait below continue to use the explicit hup_outer name.
hold_outer=$hup_outer
set -e
if ! register_test_process_bounded "$hup_outer" 'hup-recovery-outer'; then
  stop_test_processes || true
  exit 1
fi
if ! wait_for_hold_ready; then
  stop_test_processes || true
  exit 1
fi
pass 'real recovery HUP process group reaches complete readiness before teardown'
for pid_file in "$hold_pid_file" "$hold_child_file" "$hold_grandchild_file"; do
  register_test_process "$(head -n 1 "$pid_file")"
done
report_hup_delivery_failure() {
  local reason=$1 rc=${2:-unknown} file
  printf 'HUP delivery assertion failed reason=%s rc=%s hup_outer_rc=%s\n' \
    "$reason" "$rc" "${hup_outer_rc-unknown}" >&2
  for file in "$hold_output_file" "$hold_report" "$hup_delivered_file" \
    "$hold_pid_file" "$hold_child_file" "$hold_grandchild_file" \
    "$hold_fd_file" "$hold_child_fd_file" "$hold_grandchild_fd_file"; do
    if [[ -e "$file" ]]; then
      printf 'HUP evidence=%s exists=1 content=\n' "$file" >&2
      sed -n '1,160p' -- "$file" >&2 || true
    else
      printf 'HUP evidence=%s exists=0\n' "$file" >&2
    fi
  done
  dump_process_cleanup_diagnostics
}
registered_pid_kill HUP "$hup_outer"
set +e
wait "$hup_outer"
hup_outer_rc=$?
set -e
TEST_CHILD_STATUS["$hup_outer"]=$hup_outer_rc
if [[ $hup_outer_rc != 129 ]]; then
  report_hup_delivery_failure unexpected-outer-status "$hup_outer_rc"
  exit 1
fi
for pid_file in "$hold_pid_file" "$hold_child_file" "$hold_grandchild_file"; do
  pid=$(head -n 1 "$pid_file")
  if ! wait_for_process_exit "$pid"; then
    report_hup_delivery_failure "role-not-reaped:$pid_file" 1
    exit 1
  fi
done
if [[ ! -f "$hup_delivered_file" || -L "$hup_delivered_file" ]]; then
  report_hup_delivery_failure missing-hup-marker 1
  exit 1
fi
if hup_marker_count=$(grep -Ec '^HUP:[0-9]+$' "$hup_delivered_file"); then
  hup_marker_grep_rc=0
else
  hup_marker_grep_rc=$?
fi
if (( hup_marker_grep_rc != 0 )) || [[ "$hup_marker_count" != 3 ]]; then
  report_hup_delivery_failure "hup-marker-count:$hup_marker_count" "$hup_marker_grep_rc"
  exit 1
fi
if ! kill -0 "$hup_sentinel" 2>/dev/null; then
  report_hup_delivery_failure caller-sentinel-not-alive 1
  exit 1
fi
if [[ -e "$hup_caller_sentinel_signal" ]]; then
  report_hup_delivery_failure caller-sentinel-signaled 1
  exit 1
fi
pass 'HUP reaches worker, child and grandchild without killing the caller sentinel'
exec {hup_worker_wait_fd}>&-
exec {hup_child_wait_fd}>&-
exec {hup_grandchild_wait_fd}>&-
[[ $(<"$hold_fd_file") == 0 && $(<"$hold_child_fd_file") == 0 &&
  $(<"$hold_grandchild_fd_file") == 0 ]]
registered_pid_kill HUP "$hup_sentinel"
set +e
wait "$hup_sentinel"
hup_sentinel_rc=$?
set -e
TEST_CHILD_STATUS["$hup_sentinel"]=$hup_sentinel_rc
[[ $hup_sentinel_rc == 143 && -e "$hup_caller_sentinel_signal" ]]
hup_relock_report="$TEST_DIR/recovery-relock-after-hup.log"
run_expect 0 "$TEST_DIR/recovery-relock-after-hup.out" "${base_env[@]}" \
  FRP_XUDP_RECOVERY_REPORT="$hup_relock_report" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
  bash "$RECOVERY" --existing
require_result_once "$hup_relock_report" PASS 0
pass 'HUP keeps lock FD counts at zero and permits immediate relock'

rm -f -- "$FAKE_STATE/recovery-replaced"
recovery_replaced="$TEST_DIR/recovery-replaced.log"
run_expect 0 "$TEST_DIR/recovery-replaced.out" "${base_env[@]}" \
  FAKE_REPLACE_RECOVERY_REPORT=1 FRP_XUDP_RECOVERY_REPORT="$recovery_replaced" \
  FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" bash "$RECOVERY" --existing
require_contains "$recovery_replaced.opened" '^packet=existing-3 result=PASS'
require_result_once "$recovery_replaced.opened" PASS 0
require_contains "$recovery_replaced" '^replacement-path-content$'
require_not_contains "$recovery_replaced" 'packet=|RESULT='
pass 'recovery keeps writing the opened inode after leaf replacement'

: >"$DOCKER_LOG"
malicious_report="$TEST_DIR/recovery-malicious.log"
run_expect 2 "$TEST_DIR/recovery-malicious.out" "${base_env[@]}" \
  FRP_XUDP_RECOVERY_REPORT="$malicious_report" FRP_XUDP_SERVER_CONTAINER=outside \
  bash "$RECOVERY" --relay --recreate
[[ ! -s "$DOCKER_LOG" ]]
require_result_once "$malicious_report" FAIL 2
pass 'recreate rejects non-fixed names before Docker'

: >"$DOCKER_LOG"
network_report="$TEST_DIR/recovery-network.log"
run_expect 2 "$TEST_DIR/recovery-network.out" "${base_env[@]}" \
  FRP_XUDP_RECOVERY_REPORT="$network_report" FRP_XUDP_NETWORK=-bad-network \
  FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" bash "$RECOVERY" --existing
[[ ! -s "$DOCKER_LOG" ]]
require_result_once "$network_report" FAIL 2
pass 'leading-dash Docker network input is rejected'

: >"$DOCKER_LOG"
empty_report="$TEST_DIR/recovery-empty.log"
run_expect 2 "$TEST_DIR/recovery-empty.out" "${base_env[@]}" \
  FRP_XUDP_RECOVERY_REPORT="$empty_report" FRP_XUDP_VISITOR_CONTAINER= \
  FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" bash "$RECOVERY" --existing
[[ ! -s "$DOCKER_LOG" ]]
require_result_once "$empty_report" FAIL 2
pass 'explicitly empty Docker container input is rejected'

: >"$DOCKER_LOG"
: >"$RM_LOG"
staged_tamper_report="$TEST_DIR/recovery-staged-tamper.log"
staged_tamper_events="$TEST_DIR/recovery-staged-tamper.events"
: >"$staged_tamper_events"
run_expect 74 "$TEST_DIR/recovery-staged-tamper.out" "${base_env[@]}" \
  "${recreate_binary_prebuilt_env[@]}" \
  FAKE_STAGED_TAMPER=1 FAKE_ORDER_REPORT="$staged_tamper_report" \
  FAKE_ORDER_EVENTS="$staged_tamper_events" \
  FRP_XUDP_RECOVERY_REPORT="$staged_tamper_report" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
  FRP_XUDP_UDP_ECHO="$FAKE_BIN/udp_echo" bash "$RECOVERY" --p2p --recreate
require_contains "$staged_tamper_report" '^ERROR: staged runtime preflight failed; refusing to remove old containers$'
require_result_once "$staged_tamper_report" FAIL 74
[[ ! -s "$staged_tamper_events" && $(grep -c -- '^docker rm -f -- frpsA frpcB frpC$' "$DOCKER_LOG" || true) == 0 ]]
staged_tamper_runtime=$(sed -n 's/^runtime_dir=\([^ ]*\) container_start_attempted=0$/\1/p' "$staged_tamper_report")
remove_runtime_fixture "$staged_tamper_runtime"
pass 'staged runtime tampering is rejected before Docker rm'

staged_order_report="$TEST_DIR/recovery-staged-order.log"
staged_order_events="$TEST_DIR/recovery-staged-order.events"
: >"$staged_order_events"
run_expect 0 "$TEST_DIR/recovery-staged-order.out" "${base_env[@]}" \
  "${recreate_binary_prebuilt_env[@]}" \
  FAKE_ORDER_REPORT="$staged_order_report" FAKE_ORDER_EVENTS="$staged_order_events" \
  FRP_XUDP_RECOVERY_REPORT="$staged_order_report" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
  FRP_XUDP_UDP_ECHO="$FAKE_BIN/udp_echo" bash "$RECOVERY" --p2p --recreate
require_contains "$staged_order_report" '^staged_runtime_preflight=PASS$'
require_contains "$staged_order_report" '^live_runtime_preflight=PASS container=frpsA$'
require_contains "$staged_order_report" '^live_runtime_preflight=PASS container=frpcB$'
require_contains "$staged_order_report" '^live_runtime_preflight=PASS container=frpC$'
require_result_once "$staged_order_report" PASS 0
[[ $(sed -n '1p' "$staged_order_events") == docker-rm &&
  $(sed -n '2p' "$staged_order_events") == docker-run:frpsA &&
  $(sed -n '3p' "$staged_order_events") == docker-run:frpcB &&
  $(sed -n '4p' "$staged_order_events") == docker-run:frpC ]]
staged_order_runtime=$(sed -n 's/^runtime_dir=\([^ ]*\) container_start_attempted=3$/\1/p' "$staged_order_report")
remove_runtime_fixture "$staged_order_runtime"
pass 'staged pass precedes Docker rm/create and each live preflight'

: >"$DOCKER_LOG"
: >"$RM_LOG"
old_runtime_dir=$($REAL_MKTEMP -d /tmp/frp-xudp-smoke.XXXXXX)
old_runtime_identity=$(prepare_labeled_old_runtime "$old_runtime_dir")
uncontrolled_runtime_dir="$TEST_DIR/not-controlled-runtime"
mkdir -p -- "$uncontrolled_runtime_dir"
printf 'keep-outside-runtime\n' >"$uncontrolled_runtime_dir/keep"
recreate_pass="$TEST_DIR/recovery-recreate-pass.log"
run_expect 0 "$TEST_DIR/recovery-recreate-pass.out" "${base_env[@]}" \
  "${recreate_binary_prebuilt_env[@]}" \
  FAKE_OLD_RUNTIME_DIR="$old_runtime_dir" FAKE_OLD_RUNTIME_PATH_LABEL="$old_runtime_dir" \
  FAKE_OLD_RUNTIME_IDENTITY="$old_runtime_identity" FAKE_UNCONTROLLED_RUNTIME_DIR="$uncontrolled_runtime_dir" \
  LC_ALL=zh_CN.utf8 LANG=zh_CN.utf8 \
  FRP_XUDP_RECOVERY_REPORT="$recreate_pass" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
  FRP_XUDP_UDP_ECHO="$FAKE_BIN/udp_echo" bash "$RECOVERY" --p2p --recreate
require_contains "$recreate_pass" '^runtime_dir=/tmp/frp-xudp-smoke\.[A-Za-z0-9]{6} container_start_attempted=3$'
require_contains "$recreate_pass" '^old_runtime_cleanup_status=PASS old_runtime_cleanup_exit_code=0 old_runtime_cleanup_detail=removed:'
require_contains "$recreate_pass" '^current_runtime_cleanup_status=RETAINED_AFTER_CONTAINER_START_ATTEMPT current_runtime_cleanup_exit_code=0 current_runtime_cleanup_detail=retained:'
require_contains "$recreate_pass" '^cleanup_status=PASS cleanup_exit_code=0 cleanup_detail=old:PASS,current:RETAINED_AFTER_CONTAINER_START_ATTEMPT$'
require_contains "$recreate_pass" "^old_runtime_cleanup=REMOVED runtime_dir=$old_runtime_dir$"
require_result_once "$recreate_pass" PASS 0
require_contains "$recreate_pass" '^build_source=explicit-prebuilt$'
require_contains "$recreate_pass" '^prebuilt_artifact_mode=1$'
require_not_contains "$DOCKER_LOG" '^docker (exec|cp) '
require_contains "$DOCKER_LOG" '^docker rm -f -- frpsA frpcB frpC$'
require_contains "$DOCKER_LOG" '^docker run '
require_contains "$DOCKER_LOG" '^docker logs -- frpC$'
recreate_rm_count=$(wc -l <"$RM_LOG")
if [[ "$recreate_rm_count" != 14 || -e "$old_runtime_dir" ]]; then
  printf 'successful recreate cleanup assertion failed rm_count=%s old_runtime_exists=%s\n' \
    "$recreate_rm_count" "$([[ -e "$old_runtime_dir" ]] && printf yes || printf no)" >&2
  sed -n '1,80p' "$RM_LOG" >&2
  sed -n '1,240p' "$recreate_pass" >&2
  exit 1
fi
runtime_dir=$(sed -n 's/^runtime_dir=\([^ ]*\) container_start_attempted=3$/\1/p' "$recreate_pass")
recreate_identity_count=$(grep -Eoc -- '--label frp.xudp.runtime.identity=[^ ]+' "$DOCKER_LOG" || true)
recreate_path_count=$(grep -Eoc -- '--label frp.xudp.runtime.path=/tmp/frp-xudp-smoke\.[A-Za-z0-9]{6}' "$DOCKER_LOG" || true)
recreate_unique_identity_count=$(grep -Eo -- '--label frp.xudp.runtime.identity=[^ ]+' "$DOCKER_LOG" | sort -u | wc -l)
recreate_unique_path_count=$(grep -Eo -- '--label frp.xudp.runtime.path=[^ ]+' "$DOCKER_LOG" | sort -u | wc -l)
if ! [[ "$runtime_dir" =~ ^/tmp/frp-xudp-smoke\.[A-Za-z0-9]{6}$ && -d "$runtime_dir" &&
  $(<"$uncontrolled_runtime_dir/keep") == keep-outside-runtime &&
  "$recreate_identity_count" == 3 && "$recreate_path_count" == 3 &&
  "$recreate_unique_identity_count" == 1 && "$recreate_unique_path_count" == 1 ]]; then
  printf 'successful recreate identity assertion failed runtime=%q runtime_exists=%s identity_count=%s path_count=%s unique_identity_count=%s unique_path_count=%s\n' \
    "$runtime_dir" "$([[ -d "$runtime_dir" ]] && printf yes || printf no)" \
    "$recreate_identity_count" "$recreate_path_count" \
    "$recreate_unique_identity_count" "$recreate_unique_path_count" >&2
  sed -n '1,160p' "$DOCKER_LOG" >&2
  sed -n '1,240p' "$recreate_pass" >&2
  exit 1
fi
pass 'successful recreate removes only the old common runtime and retains the active runtime'
remove_runtime_fixture "$runtime_dir"

unicode_runtime_dir=$($REAL_MKTEMP -d /tmp/frp-xudp-smoke.XXXXXX)
unicode_runtime_identity=$(prepare_labeled_old_runtime "$unicode_runtime_dir")
: >"$RM_LOG"
unicode_path_report="$TEST_DIR/recovery-non-c-locale-path.log"
run_expect 0 "$TEST_DIR/recovery-non-c-locale-path.out" "${base_env[@]}" \
  "${recreate_binary_prebuilt_env[@]}" \
  FAKE_OLD_RUNTIME_DIR="$unicode_runtime_dir" \
  FAKE_OLD_RUNTIME_PATH_LABEL='/tmp/frp-xudp-smoke.é23456' \
  FAKE_OLD_RUNTIME_IDENTITY="$unicode_runtime_identity" \
  LC_ALL=zh_CN.UTF-8 LANG=zh_CN.UTF-8 \
  FRP_XUDP_RECOVERY_REPORT="$unicode_path_report" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
  FRP_XUDP_UDP_ECHO="$FAKE_BIN/udp_echo" bash "$RECOVERY" --p2p --recreate
require_contains "$unicode_path_report" '^old_runtime_cleanup_status=SAFELY_SKIPPED old_runtime_cleanup_exit_code=0 old_runtime_cleanup_detail=retained-legacy-runtime:'
[[ -d "$unicode_runtime_dir" && $(rm_log_runtime_count) == 0 ]]
unicode_current=$(sed -n 's/^runtime_dir=\([^ ]*\) container_start_attempted=3$/\1/p' "$unicode_path_report")
[[ -d "$unicode_current" ]]
remove_runtime_fixture "$unicode_runtime_dir"
remove_runtime_fixture "$unicode_current"

assert_legacy_label_case() {
  local scenario=$1 root alternate report identity alternate_identity current
  root=$($REAL_MKTEMP -d /tmp/frp-xudp-smoke.XXXXXX)
  identity=$(prepare_labeled_old_runtime "$root")
  : >"$DOCKER_LOG"
  : >"$RM_LOG"
  case "$scenario" in
    mismatch)
      alternate=$($REAL_MKTEMP -d /tmp/frp-xudp-smoke.XXXXXX)
      alternate_identity=$(prepare_labeled_old_runtime "$alternate")
      ;;
    disk-drift) chmod 755 -- "$root/config" ;;
  esac
  report="$TEST_DIR/recovery-label-$scenario.log"
  local expected_rc=0
  [[ "$scenario" == disk-drift ]] && expected_rc=74
  run_expect "$expected_rc" "$TEST_DIR/recovery-label-$scenario.out" "${base_env[@]}" \
    "${recreate_binary_prebuilt_env[@]}" \
    FAKE_LABEL_SCENARIO="$scenario" FAKE_OLD_RUNTIME_DIR="$root" \
    FAKE_OLD_RUNTIME_PATH_LABEL="$root" FAKE_OLD_RUNTIME_IDENTITY="$identity" \
    FAKE_OLD_RUNTIME_PATH_LABEL_MISMATCH="${alternate:-}" \
    FAKE_OLD_RUNTIME_IDENTITY_MISMATCH="${alternate_identity:-}" \
    FRP_XUDP_RECOVERY_REPORT="$report" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
    FRP_XUDP_UDP_ECHO="$FAKE_BIN/udp_echo" bash "$RECOVERY" --p2p --recreate
  if [[ "$scenario" == disk-drift ]]; then
    require_contains "$report" '^old_runtime_cleanup_status=FAIL old_runtime_cleanup_exit_code=74 old_runtime_cleanup_detail=retained:.*identity-or-allowlist-drift-or-cleanup-failed$'
    require_result_once "$report" FAIL 74
  else
    require_contains "$report" '^old_runtime_cleanup_status=SAFELY_SKIPPED old_runtime_cleanup_exit_code=0 old_runtime_cleanup_detail=retained-legacy-runtime:'
    require_result_once "$report" PASS 0
  fi
  [[ -d "$root" ]]
  if [[ "$scenario" == disk-drift ]]; then
    ! grep -Fq -- "$root/" "$RM_LOG"
  else
    [[ $(rm_log_runtime_count) == 0 ]]
    current=$(sed -n 's/^runtime_dir=\([^ ]*\) container_start_attempted=3$/\1/p' "$report")
    [[ -d "$current" ]]
    remove_runtime_fixture "$current"
  fi
  remove_runtime_fixture "$root"
  [[ -z ${alternate:-} ]] || remove_runtime_fixture "$alternate"
}

assert_legacy_label_case missing
assert_legacy_label_case bad
assert_legacy_label_case mismatch
assert_legacy_label_case disk-drift

# These cases are intentionally assertions without pass() calls: they extend
# the fake-Docker truth table while preserving the ordinary103/isolated107
# contract.  The normal single-line record must pass; empty records, NUL,
# CR, missing final LF, and extra lines must retain the old runtime and leave
# it available for diagnosis.
assert_strict_inspect_case() {
  local kind=$1 root identity report current
  root=$($REAL_MKTEMP -d /tmp/frp-xudp-smoke.XXXXXX)
  identity=$(prepare_labeled_old_runtime "$root")
  : >"$DOCKER_LOG"
  : >"$RM_LOG"
  report="$TEST_DIR/recovery-strict-inspect-$kind.log"
  run_expect 0 "$TEST_DIR/recovery-strict-inspect-$kind.out" "${base_env[@]}" \
    "${recreate_binary_prebuilt_env[@]}" \
    FAKE_MOUNT_SCENARIO="$kind" FAKE_LABEL_SCENARIO="$kind" \
    FAKE_OLD_RUNTIME_DIR="$root" FAKE_OLD_RUNTIME_PATH_LABEL="$root" \
    FAKE_OLD_RUNTIME_IDENTITY="$identity" \
    FRP_XUDP_RECOVERY_REPORT="$report" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
    FRP_XUDP_UDP_ECHO="$FAKE_BIN/udp_echo" bash "$RECOVERY" --p2p --recreate
  current=$(sed -n 's/^runtime_dir=\([^ ]*\) container_start_attempted=3$/\1/p' "$report")
  if [[ "$kind" == normal ]]; then
    require_contains "$report" '^old_runtime_cleanup_status=PASS old_runtime_cleanup_exit_code=0 old_runtime_cleanup_detail=removed:'
    [[ ! -e "$root" && -d "$current" && $(rm_log_runtime_count) == 13 ]]
  else
    require_contains "$report" '^old_runtime_cleanup_status=SAFELY_SKIPPED old_runtime_cleanup_exit_code=0 old_runtime_cleanup_detail=retained-legacy-runtime:'
    [[ -d "$root" && -d "$current" && $(rm_log_runtime_count) == 0 ]]
  fi
  remove_runtime_fixture "$root"
  remove_runtime_fixture "$current"
}

assert_strict_inspect_case normal
assert_strict_inspect_case multiline
assert_strict_inspect_case cr
assert_strict_inspect_case one-nul-no-final-lf
assert_strict_inspect_case nul-middle
assert_strict_inspect_case nul-end
assert_strict_inspect_case no-final-lf

symlink_target="$TEST_DIR/build-symlink-target"
printf 'must-not-be-followed\n' >"$symlink_target"
symlink_report="$TEST_DIR/recovery-build-symlink.log"
: >"$DOCKER_LOG"
run_expect 1 "$TEST_DIR/recovery-build-symlink.out" "${base_env[@]}" \
  FAKE_BUILD_SYMLINK=1 FAKE_BUILD_SYMLINK_TARGET="$symlink_target" \
  FRP_XUDP_RECOVERY_REPORT="$symlink_report" bash "$RECOVERY" --p2p --recreate
[[ $(<"$symlink_target") == must-not-be-followed ]]
require_build_guard_docker_calls
require_contains "$symlink_report" '^current_runtime_cleanup_status=PASS current_runtime_cleanup_exit_code=0 '
require_contains "$symlink_report" '^cleanup_status=PASS cleanup_exit_code=0 '
[[ -e "$symlink_report" && $(grep -c -- '^RESULT=FAIL exit_code=1' "$symlink_report") == 1 ]]
rm -f -- /tmp/xudp-build.ABCDEF
pass 'container build rejects a pre-existing symlink without Docker side effects'

: >"$RM_LOG"
rm -f -- "$FAKE_STATE/rm-call-count" "$FAKE_STATE/last-retained"
old_runtime_remove_fail=$($REAL_MKTEMP -d /tmp/frp-xudp-smoke.XXXXXX)
old_runtime_remove_fail_identity=$(prepare_labeled_old_runtime "$old_runtime_remove_fail")
old_remove_fail_report="$TEST_DIR/recovery-old-remove-fail.log"
run_expect 74 "$TEST_DIR/recovery-old-remove-fail.out" "${base_env[@]}" \
  "${recreate_binary_prebuilt_env[@]}" \
  FAKE_OLD_RUNTIME_DIR="$old_runtime_remove_fail" FAKE_OLD_RUNTIME_PATH_LABEL="$old_runtime_remove_fail" \
  FAKE_OLD_RUNTIME_IDENTITY="$old_runtime_remove_fail_identity" FAKE_RM_FAIL_ON_CALL=1 \
  FRP_XUDP_RECOVERY_REPORT="$old_remove_fail_report" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
  FRP_XUDP_UDP_ECHO="$FAKE_BIN/udp_echo" bash "$RECOVERY" --p2p --recreate
require_contains "$old_remove_fail_report" '^runtime_dir=/tmp/frp-xudp-smoke\.[A-Za-z0-9]{6} container_start_attempted=0$'
require_contains "$old_remove_fail_report" '^old_runtime_cleanup_status=FAIL old_runtime_cleanup_exit_code=74 old_runtime_cleanup_detail=retained:.*identity-or-allowlist-drift-or-cleanup-failed$'
require_contains "$old_remove_fail_report" '^current_runtime_cleanup_status=PASS current_runtime_cleanup_exit_code=0 current_runtime_cleanup_detail=removed:'
require_contains "$old_remove_fail_report" '^cleanup_status=FAIL cleanup_exit_code=74 cleanup_detail=old:FAIL,current:PASS$'
require_result_once "$old_remove_fail_report" FAIL 74
old_fail_current_dir=$(sed -n 's/^runtime_dir=\([^ ]*\) container_start_attempted=0$/\1/p' "$old_remove_fail_report")
old_fail_retained=$(<"$FAKE_STATE/last-retained")
[[ ! -e "$old_fail_current_dir" && -d "$old_runtime_remove_fail" &&
  -f "$old_fail_retained" && $(wc -l <"$RM_LOG") -ge 2 ]]
pass 'old runtime removal failure survives current pre-start cleanup and fails the result'
"$REAL_RM" -f -- "$old_fail_retained"
remove_runtime_fixture "$old_runtime_remove_fail"

: >"$RM_LOG"
mount_mismatch_a=$($REAL_MKTEMP -d /tmp/frp-xudp-smoke.XXXXXX)
mount_mismatch_b=$($REAL_MKTEMP -d /tmp/frp-xudp-smoke.XXXXXX)
mount_mismatch_report="$TEST_DIR/recovery-mount-mismatch.log"
run_expect 0 "$TEST_DIR/recovery-mount-mismatch.out" "${base_env[@]}" \
  "${recreate_binary_prebuilt_env[@]}" \
  FAKE_MOUNT_SCENARIO=mismatch FAKE_OLD_RUNTIME_DIR="$mount_mismatch_a" \
  FAKE_OLD_RUNTIME_DIR_2="$mount_mismatch_b" FRP_XUDP_RECOVERY_REPORT="$mount_mismatch_report" \
  FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" FRP_XUDP_UDP_ECHO="$FAKE_BIN/udp_echo" \
  bash "$RECOVERY" --p2p --recreate
require_contains "$mount_mismatch_report" '^old_runtime_cleanup_status=SAFELY_SKIPPED old_runtime_cleanup_exit_code=0 old_runtime_cleanup_detail=retained-legacy-runtime:runtime-dir-not-common$'
require_contains "$mount_mismatch_report" '^cleanup_status=PASS cleanup_exit_code=0 cleanup_detail=old:SAFELY_SKIPPED,current:RETAINED_AFTER_CONTAINER_START_ATTEMPT$'
mount_mismatch_current=$(sed -n 's/^runtime_dir=\([^ ]*\) container_start_attempted=3$/\1/p' "$mount_mismatch_report")
[[ -d "$mount_mismatch_a" && -d "$mount_mismatch_b" && -d "$mount_mismatch_current" && $(rm_log_runtime_count) == 0 ]]
pass 'different controlled mount roots are not deleted'
remove_runtime_fixture "$mount_mismatch_a"
remove_runtime_fixture "$mount_mismatch_b"
remove_runtime_fixture "$mount_mismatch_current"

: >"$RM_LOG"
mount_missing=$($REAL_MKTEMP -d /tmp/frp-xudp-smoke.XXXXXX)
mount_missing_report="$TEST_DIR/recovery-mount-missing.log"
run_expect 0 "$TEST_DIR/recovery-mount-missing.out" "${base_env[@]}" \
  "${recreate_binary_prebuilt_env[@]}" \
  FAKE_MOUNT_SCENARIO=missing FAKE_OLD_RUNTIME_DIR="$mount_missing" \
  FRP_XUDP_RECOVERY_REPORT="$mount_missing_report" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
  FRP_XUDP_UDP_ECHO="$FAKE_BIN/udp_echo" bash "$RECOVERY" --p2p --recreate
require_contains "$mount_missing_report" '^old_runtime_cleanup_status=SAFELY_SKIPPED old_runtime_cleanup_exit_code=0 old_runtime_cleanup_detail=retained-legacy-runtime:no-controlled-runtime-dir:frpC$'
mount_missing_current=$(sed -n 's/^runtime_dir=\([^ ]*\) container_start_attempted=3$/\1/p' "$mount_missing_report")
[[ -d "$mount_missing" && -d "$mount_missing_current" && $(rm_log_runtime_count) == 0 ]]
pass 'a container missing the controlled mount prevents old runtime deletion'
remove_runtime_fixture "$mount_missing"
remove_runtime_fixture "$mount_missing_current"

: >"$RM_LOG"
mount_multiple_a=$($REAL_MKTEMP -d /tmp/frp-xudp-smoke.XXXXXX)
mount_multiple_b=$($REAL_MKTEMP -d /tmp/frp-xudp-smoke.XXXXXX)
mount_multiple_report="$TEST_DIR/recovery-mount-multiple.log"
run_expect 0 "$TEST_DIR/recovery-mount-multiple.out" "${base_env[@]}" \
  "${recreate_binary_prebuilt_env[@]}" \
  FAKE_MOUNT_SCENARIO=multiple FAKE_OLD_RUNTIME_DIR="$mount_multiple_a" \
  FAKE_OLD_RUNTIME_DIR_2="$mount_multiple_b" FRP_XUDP_RECOVERY_REPORT="$mount_multiple_report" \
  FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" FRP_XUDP_UDP_ECHO="$FAKE_BIN/udp_echo" \
  bash "$RECOVERY" --p2p --recreate
require_contains "$mount_multiple_report" '^old_runtime_cleanup_status=SAFELY_SKIPPED old_runtime_cleanup_exit_code=0 old_runtime_cleanup_detail=retained-legacy-runtime:multiple-controlled-runtime-dirs:frpsA$'
mount_multiple_current=$(sed -n 's/^runtime_dir=\([^ ]*\) container_start_attempted=3$/\1/p' "$mount_multiple_report")
[[ -d "$mount_multiple_a" && -d "$mount_multiple_b" && -d "$mount_multiple_current" && $(rm_log_runtime_count) == 0 ]]
pass 'multiple controlled roots on one container prevent old runtime deletion'
remove_runtime_fixture "$mount_multiple_a"
remove_runtime_fixture "$mount_multiple_b"
remove_runtime_fixture "$mount_multiple_current"

: >"$RM_LOG"
old_runtime_rm_failed=$($REAL_MKTEMP -d /tmp/frp-xudp-smoke.XXXXXX)
old_runtime_rm_failed_identity=$(prepare_labeled_old_runtime "$old_runtime_rm_failed")
recreate_rm_failed="$TEST_DIR/recovery-docker-rm-failed.log"
run_expect 0 "$TEST_DIR/recovery-docker-rm-failed.out" "${base_env[@]}" \
  "${recreate_binary_prebuilt_env[@]}" \
  FAKE_OLD_RUNTIME_DIR="$old_runtime_rm_failed" FAKE_OLD_RUNTIME_PATH_LABEL="$old_runtime_rm_failed" \
  FAKE_OLD_RUNTIME_IDENTITY="$old_runtime_rm_failed_identity" FAKE_DOCKER_FAIL_RM=1 \
  FRP_XUDP_RECOVERY_REPORT="$recreate_rm_failed" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
  FRP_XUDP_UDP_ECHO="$FAKE_BIN/udp_echo" bash "$RECOVERY" --p2p --recreate
require_contains "$recreate_rm_failed" '^old_runtime_cleanup=SKIPPED reason=docker-rm-failed$'
require_contains "$recreate_rm_failed" '^old_runtime_cleanup_status=SAFELY_SKIPPED old_runtime_cleanup_exit_code=0 old_runtime_cleanup_detail=docker-rm-failed$'
require_contains "$recreate_rm_failed" '^current_runtime_cleanup_status=RETAINED_AFTER_CONTAINER_START_ATTEMPT '
require_contains "$recreate_rm_failed" '^cleanup_status=PASS cleanup_exit_code=0 cleanup_detail=old:SAFELY_SKIPPED,current:RETAINED_AFTER_CONTAINER_START_ATTEMPT$'
require_result_once "$recreate_rm_failed" PASS 0
rm_failed_runtime_dir=$(sed -n 's/^runtime_dir=\([^ ]*\) container_start_attempted=3$/\1/p' "$recreate_rm_failed")
[[ -d "$old_runtime_rm_failed" && -d "$rm_failed_runtime_dir" && $(rm_log_runtime_count) == 0 ]]
pass 'old runtime is not deleted when docker rm fails'
remove_runtime_fixture "$old_runtime_rm_failed"
remove_runtime_fixture "$rm_failed_runtime_dir"

: >"$RM_LOG"
recreate_runtime_fail="$TEST_DIR/recovery-runtime-fail.log"
run_expect 9 "$TEST_DIR/recovery-runtime-fail.out" "${base_env[@]}" \
  "${recreate_binary_prebuilt_env[@]}" \
  FAKE_UDP_FAIL=1 FRP_XUDP_RECOVERY_REPORT="$recreate_runtime_fail" \
  FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" FRP_XUDP_UDP_ECHO="$FAKE_BIN/udp_echo" \
  bash "$RECOVERY" --p2p --recreate
require_contains "$recreate_runtime_fail" '^runtime_dir=/tmp/frp-xudp-smoke\.[A-Za-z0-9]{6} container_start_attempted=3$'
require_contains "$recreate_runtime_fail" '^old_runtime_cleanup_status=NOT_APPLICABLE '
require_contains "$recreate_runtime_fail" '^current_runtime_cleanup_status=RETAINED_AFTER_CONTAINER_START_ATTEMPT '
require_contains "$recreate_runtime_fail" '^cleanup_status=PASS cleanup_exit_code=0 cleanup_detail=old:NOT_APPLICABLE,current:RETAINED_AFTER_CONTAINER_START_ATTEMPT$'
require_result_once "$recreate_runtime_fail" FAIL 9
failed_runtime_dir=$(sed -n 's/^runtime_dir=\([^ ]*\) container_start_attempted=3$/\1/p' "$recreate_runtime_fail")
[[ -d "$failed_runtime_dir" && $(rm_log_runtime_count) == 0 ]]
pass 'post-start packet failure retains the active runtime and original rc'
remove_runtime_fixture "$failed_runtime_dir"

: >"$RM_LOG"
recreate_prestart_fail="$TEST_DIR/recovery-prestart-fail.log"
run_expect 1 "$TEST_DIR/recovery-prestart-fail.out" "${base_env[@]}" \
  FAKE_DOCKER_FAIL_EXEC=1 FRP_XUDP_RECOVERY_REPORT="$recreate_prestart_fail" \
  bash "$RECOVERY" --p2p --recreate
require_contains "$recreate_prestart_fail" '^runtime_dir=/tmp/frp-xudp-smoke\.[A-Za-z0-9]{6} container_start_attempted=0$'
require_contains "$recreate_prestart_fail" '^old_runtime_cleanup_status=NOT_APPLICABLE '
require_contains "$recreate_prestart_fail" '^current_runtime_cleanup_status=PASS current_runtime_cleanup_exit_code=0 current_runtime_cleanup_detail=removed:'
require_contains "$recreate_prestart_fail" '^cleanup_status=PASS cleanup_exit_code=0 cleanup_detail=old:NOT_APPLICABLE,current:PASS$'
require_result_once "$recreate_prestart_fail" FAIL 1
prestart_runtime_dir=$(sed -n 's/^runtime_dir=\([^ ]*\) container_start_attempted=0$/\1/p' "$recreate_prestart_fail")
[[ ! -e "$prestart_runtime_dir" && $(rm_log_runtime_count) == 13 ]]
pass 'failure before the first docker run cleans the new temporary runtime'

: >"$RM_LOG"
recreate_first_run_fail="$TEST_DIR/recovery-first-run-fail.log"
run_expect 1 "$TEST_DIR/recovery-first-run-fail.out" "${base_env[@]}" \
  "${recreate_binary_prebuilt_env[@]}" \
  FAKE_DOCKER_FAIL_RUN=1 FRP_XUDP_RECOVERY_REPORT="$recreate_first_run_fail" \
  FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" FRP_XUDP_UDP_ECHO="$FAKE_BIN/udp_echo" \
  bash "$RECOVERY" --p2p --recreate
require_contains "$recreate_first_run_fail" '^current_runtime_cleanup_status=RETAINED_AFTER_CONTAINER_START_ATTEMPT current_runtime_cleanup_exit_code=0 current_runtime_cleanup_detail=retained:'
require_contains "$recreate_first_run_fail" '^cleanup_status=PASS cleanup_exit_code=0 cleanup_detail=old:NOT_APPLICABLE,current:RETAINED_AFTER_CONTAINER_START_ATTEMPT$'
require_result_once "$recreate_first_run_fail" FAIL 1
first_run_runtime_dir=$(sed -n 's/^runtime_dir=\([^ ]*\) container_start_attempted=1$/\1/p' "$recreate_first_run_fail")
[[ -d "$first_run_runtime_dir" && $(rm_log_runtime_count) == 0 ]]
pass 'attempting the first docker run switches the runtime to retained state'
remove_runtime_fixture "$first_run_runtime_dir"

: >"$RM_LOG"
recreate_first_run_rc_fail="$TEST_DIR/recovery-first-run-rc-fail.log"
run_expect 42 "$TEST_DIR/recovery-first-run-rc-fail.out" "${base_env[@]}" \
  "${recreate_binary_prebuilt_env[@]}" \
  FAKE_DOCKER_FAIL_RUN_RC=42 FRP_XUDP_RECOVERY_REPORT="$recreate_first_run_rc_fail" \
  FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" FRP_XUDP_UDP_ECHO="$FAKE_BIN/udp_echo" \
  bash "$RECOVERY" --p2p --recreate
require_contains "$recreate_first_run_rc_fail" '^runtime_dir=/tmp/frp-xudp-smoke\.[A-Za-z0-9]{6} container_start_attempted=1$'
require_contains "$recreate_first_run_rc_fail" '^current_runtime_cleanup_status=RETAINED_AFTER_CONTAINER_START_ATTEMPT '
require_contains "$recreate_first_run_rc_fail" '^cleanup_status=PASS cleanup_exit_code=0 cleanup_detail=old:NOT_APPLICABLE,current:RETAINED_AFTER_CONTAINER_START_ATTEMPT$'
require_result_once "$recreate_first_run_rc_fail" FAIL 42
first_run_rc_runtime_dir=$(sed -n 's/^runtime_dir=\([^ ]*\) container_start_attempted=1$/\1/p' "$recreate_first_run_rc_fail")
[[ -d "$first_run_rc_runtime_dir" && $(rm_log_runtime_count) == 0 ]]
remove_runtime_fixture "$first_run_rc_runtime_dir"

run_static_runtime_truth_case() {
  local mode expected_runs expected_rc id report runtime
  mode=$1
  expected_runs=$2
  expected_rc=$3
  id="static-$mode"
  : >"$DOCKER_LOG"
  report="$TEST_DIR/recovery-static-$mode.log"
  run_expect "$expected_rc" "$TEST_DIR/recovery-static-$mode.out" "${base_env[@]}" \
    "${recreate_binary_prebuilt_env[@]}" \
    FAKE_RUNTIME_MUTATION="$mode" FAKE_RUNTIME_MUTATION_ID="$id" \
    FRP_XUDP_RECOVERY_REPORT="$report" FRP_XUDP_UDP_SEND="$FAKE_BIN/udp_send" \
    FRP_XUDP_UDP_ECHO="$FAKE_BIN/udp_echo" bash "$RECOVERY" --p2p --recreate
  [[ $(grep -c -- '^docker run ' "$DOCKER_LOG" || true) == "$expected_runs" ]]
  require_contains "$report" "^runtime_dir=/tmp/frp-xudp-smoke\\.[A-Za-z0-9]{6} container_start_attempted=$expected_runs$"
  if (( expected_rc == 0 )); then
    require_result_once "$report" PASS 0
  else
    require_result_once "$report" FAIL 74
  fi
  runtime=$(sed -n "s/^runtime_dir=\\([^ ]*\\) container_start_attempted=$expected_runs$/\\1/p" "$report")
  if [[ -n "$runtime" && -d "$runtime/bin/frpc" ]]; then
    "$REAL_RMDIR" -- "$runtime/bin/frpc" 2>/dev/null || true
  fi
  "$REAL_RM" -f -- "/tmp/xudp-static-hardlink-$id" 2>/dev/null || true
  remove_runtime_fixture "$runtime"
  "$REAL_RMDIR" -- "/tmp/xudp-static-old-log-$id" 2>/dev/null || true
}

for static_before_mode in before-first before-first-frps before-first-frpc \
  before-first-frps-config before-first-frpc-config before-first-visitor-config \
  before-first-mode same-content-new-inode content-in-place symlink \
  nlink2 owner type missing; do
  run_static_runtime_truth_case "$static_before_mode" 0 74
done
run_static_runtime_truth_case after-first-frpc 1 74
run_static_runtime_truth_case after-second-visitor 2 74
run_static_runtime_truth_case config-directory 1 74
run_static_runtime_truth_case log-directory 1 74
run_static_runtime_truth_case log-content 3 0

[[ $(<"$FAKE_TMP_CONTRACT_RC_FILE") == 0 &&
   $(<"$FAKE_TMP_CONTRACT_DURATION_FILE") =~ ^[0-9]+$ &&
   $(<"$FAKE_TMP_CONTRACT_STATE/marker-removed") == '' ]]
pass 'fake recovery marker has an exact private create/remove contract'

[[ -e "$FAKE_TMP_CONTRACT_STATE/symlink-rejected" &&
   -e "$FAKE_TMP_CONTRACT_STATE/hardlink-rejected" &&
   -e "$FAKE_TMP_CONTRACT_STATE/invalid-rejected" &&
   -e "$FAKE_TMP_CONTRACT_STATE/failure-visible" ]]
pass 'fake recovery-marker cleanup rejects symlink, hardlink and path-shape anomalies'

if [[ $(wc -l <"$FAKE_TMP_CONTRACT_STATE/rm.log") != 5 ]] ||
   ! cmp -s "$FAKE_TMP_CONTRACT_STATE/rm.expected" "$FAKE_TMP_CONTRACT_STATE/rm.log"; then
  printf 'xudp-init-assertion-failed reason=fake_tmp_contract_rm_log\n' >&2
  exit 1
fi
if [[ $(wc -l <"$FAKE_TMP_CONTRACT_STATE/rmdir.log") != 1 ]] ||
   ! cmp -s "$FAKE_TMP_CONTRACT_STATE/rmdir.expected" "$FAKE_TMP_CONTRACT_STATE/rmdir.log"; then
  printf 'xudp-init-assertion-failed reason=fake_tmp_contract_rmdir_log\n' >&2
  exit 1
fi
pass 'fake recovery-marker removal failures are visible and never silently accepted'

pmtud_report="$TEST_DIR/pmtud-pass.log"
run_expect 0 "$TEST_DIR/pmtud-pass.out" "${base_env[@]}" \
  XUDP_PMTUD_REPORT="$pmtud_report" bash "$PMTUD"
require_contains "$pmtud_report" '^variant=default result=PASS$'
require_contains "$pmtud_report" '^variant=xudp_pmtud_experiment result=PASS$'
require_result_once "$pmtud_report" PASS 0
pass 'PMTUD records both fake loopback variants and one PASS'

pmtud_fail="$TEST_DIR/pmtud-fail.log"
run_expect 1 "$TEST_DIR/pmtud-fail.out" "${base_env[@]}" \
  FAKE_DOCKER_FAIL_EXEC=1 XUDP_PMTUD_REPORT="$pmtud_fail" bash "$PMTUD"
require_result_once "$pmtud_fail" FAIL 1
pass 'PMTUD EXIT trap writes one FAIL'

cp -- "$pmtud_report" "$TEST_DIR/pmtud-before.log"
run_expect 1 "$TEST_DIR/pmtud-existing.out" "${base_env[@]}" \
  XUDP_PMTUD_REPORT="$pmtud_report" bash "$PMTUD"
cmp -- "$pmtud_report" "$TEST_DIR/pmtud-before.log"
pass 'PMTUD refuses an existing report leaf'

printf 'symlink-target-unchanged\n' >"$TEST_DIR/pmtud-symlink-target.log"
ln -s -- "$TEST_DIR/pmtud-symlink-target.log" "$TEST_DIR/pmtud-link.log"
run_expect 1 "$TEST_DIR/pmtud-symlink.out" "${base_env[@]}" \
  XUDP_PMTUD_REPORT="$TEST_DIR/pmtud-link.log" bash "$PMTUD"
[[ $(<"$TEST_DIR/pmtud-symlink-target.log") == symlink-target-unchanged ]]
pass 'PMTUD refuses a symlink report leaf'

: >"$FAKE_BUILD_LOG"
pmtud_concurrent_a="$TEST_DIR/pmtud-concurrent-a.log"
pmtud_concurrent_b="$TEST_DIR/pmtud-concurrent-b.log"
set +e
(env "PATH=$FAKE_BIN:$PATH" "FAKE_DOCKER_LOG=$DOCKER_LOG" "FAKE_TIMEOUT_LOG=$TIMEOUT_LOG" \
  "FAKE_RM_LOG=$RM_LOG" "FAKE_STATE_DIR=$FAKE_STATE" "REAL_MKTEMP=$REAL_MKTEMP" \
  "REAL_RM=$REAL_RM" "FAKE_BUILD_LOG=$TEST_DIR/build.log" \
  XUDP_PMTUD_REPORT="$pmtud_concurrent_a" bash "$PMTUD" >"$TEST_DIR/pmtud-concurrent-a.out" 2>&1) &
pmtud_pid_a=$!
(env "PATH=$FAKE_BIN:$PATH" "FAKE_DOCKER_LOG=$DOCKER_LOG" "FAKE_TIMEOUT_LOG=$TIMEOUT_LOG" \
  "FAKE_RM_LOG=$RM_LOG" "FAKE_STATE_DIR=$FAKE_STATE" "REAL_MKTEMP=$REAL_MKTEMP" \
  "REAL_RM=$REAL_RM" "FAKE_BUILD_LOG=$TEST_DIR/build.log" \
  XUDP_PMTUD_REPORT="$pmtud_concurrent_b" bash "$PMTUD" >"$TEST_DIR/pmtud-concurrent-b.out" 2>&1) &
pmtud_pid_b=$!
wait "$pmtud_pid_a"; pmtud_rc_a=$?
wait "$pmtud_pid_b"; pmtud_rc_b=$?
set -e
[[ $pmtud_rc_a == 0 && $pmtud_rc_b == 0 ]]
[[ $(wc -l <"$TEST_DIR/build.log") == 4 ]]
[[ $(sort -u "$TEST_DIR/build.log" | wc -l) == 4 ]]
while IFS= read -r build_path; do [[ ! -e "$build_path" && ! -L "$build_path" ]]; done <"$TEST_DIR/build.log"
pass 'concurrent PMTUD builds use isolated private directories and clean all outputs'

rm -f -- "$FAKE_STATE/pmtud-replaced"
pmtud_replaced="$TEST_DIR/pmtud-replaced.log"
run_expect 0 "$TEST_DIR/pmtud-replaced.out" "${base_env[@]}" \
  FAKE_REPLACE_PMTUD_REPORT=1 XUDP_PMTUD_REPORT="$pmtud_replaced" bash "$PMTUD"
require_contains "$pmtud_replaced.opened" '^fake-docker-exec-output$'
require_result_once "$pmtud_replaced.opened" PASS 0
require_contains "$pmtud_replaced" '^replacement-path-content$'
require_not_contains "$pmtud_replaced" 'fake-docker-exec-output|RESULT='
pass 'PMTUD keeps writing the opened inode after leaf replacement'

: >"$DOCKER_LOG"
pmtud_malicious="$TEST_DIR/pmtud-malicious.log"
run_expect 2 "$TEST_DIR/pmtud-malicious.out" "${base_env[@]}" \
  FRP_DEV_CONTAINER=-outside XUDP_PMTUD_REPORT="$pmtud_malicious" bash "$PMTUD"
[[ ! -s "$DOCKER_LOG" ]]
require_result_once "$pmtud_malicious" FAIL 2
pass 'PMTUD rejects malicious container input before Docker'

summary_p2p="$TEST_DIR/summary-p2p.log"
summary_relay="$TEST_DIR/summary-relay.log"
summary_pmtud="$TEST_DIR/summary-pmtud.log"
summary_json="$TEST_DIR/xudp-release-summary.json"
write_eligible_report "$summary_p2p" p2p
write_eligible_report "$summary_relay" relay
write_eligible_report "$summary_pmtud" pmtud
run_expect 0 "$TEST_DIR/summary-pass.out" bash "$SUMMARY" \
  --output "$summary_json" --p2p "$summary_p2p" --relay "$summary_relay" --pmtud "$summary_pmtud"
validate_json "$summary_json"
require_contains "$summary_json" '^  "release_eligible": true,$'
require_contains "$summary_json" '"supersedes": \[\]'
pass 'release summary selects matching PASS provenance and writes valid JSON'

summary_bad_p2p="$TEST_DIR/summary-bad-p2p.log"
sed 's/^release_eligible=true$/release_eligible=false/' "$summary_p2p" >"$summary_bad_p2p"
summary_bad_json="$TEST_DIR/xudp-release-summary-bad.json"
run_expect 1 "$TEST_DIR/summary-fail.out" bash "$SUMMARY" \
  --output "$summary_bad_json" --p2p "$summary_bad_p2p" --relay "$summary_relay" --pmtud "$summary_pmtud"
validate_json "$summary_bad_json"
require_contains "$summary_bad_json" '^  "release_eligible": false,$'
require_contains "$summary_bad_json" 'report-not-release-eligible'
pass 'release summary rejects a non-eligible report without promoting it'

summary_unavailable_p2p="$TEST_DIR/summary-unavailable-p2p.log"
summary_unavailable_relay="$TEST_DIR/summary-unavailable-relay.log"
summary_unavailable_pmtud="$TEST_DIR/summary-unavailable-pmtud.log"
sed -e 's/^git_head=.*/git_head=unavailable/' \
  -e 's/^git_tree=.*/git_tree=unavailable/' \
  -e 's/^worktree_dirty=.*/worktree_dirty=unknown/' \
  -e 's/^status_digest=.*/status_digest=unavailable/' \
  -e 's/^status_entries=.*/status_entries=unavailable/' \
  -e 's/^release_eligible=.*/release_eligible=false/' \
  -e 's/^frpc_sha256=.*/frpc_sha256=unavailable/' \
  -e 's/^frps_sha256=.*/frps_sha256=unavailable/' \
  -e 's/^frpc_config_sha256=.*/frpc_config_sha256=unavailable/' \
  -e 's/^frps_config_sha256=.*/frps_config_sha256=unavailable/' \
  -e 's/^visitor_config_sha256=.*/visitor_config_sha256=unavailable/' \
  "$summary_p2p" >"$summary_unavailable_p2p"
sed -e 's/^git_head=.*/git_head=unavailable/' \
  -e 's/^git_tree=.*/git_tree=unavailable/' \
  -e 's/^worktree_dirty=.*/worktree_dirty=unknown/' \
  -e 's/^status_digest=.*/status_digest=unavailable/' \
  -e 's/^status_entries=.*/status_entries=unavailable/' \
  -e 's/^release_eligible=.*/release_eligible=false/' \
  -e 's/^frpc_sha256=.*/frpc_sha256=unavailable/' \
  -e 's/^frps_sha256=.*/frps_sha256=unavailable/' \
  -e 's/^frpc_config_sha256=.*/frpc_config_sha256=unavailable/' \
  -e 's/^frps_config_sha256=.*/frps_config_sha256=unavailable/' \
  -e 's/^visitor_config_sha256=.*/visitor_config_sha256=unavailable/' \
  "$summary_relay" >"$summary_unavailable_relay"
sed -e 's/^git_head=.*/git_head=unavailable/' \
  -e 's/^git_tree=.*/git_tree=unavailable/' \
  -e 's/^worktree_dirty=.*/worktree_dirty=unknown/' \
  -e 's/^status_digest=.*/status_digest=unavailable/' \
  -e 's/^status_entries=.*/status_entries=unavailable/' \
  -e 's/^release_eligible=.*/release_eligible=false/' \
  -e 's/^default_frpc_sha256=.*/default_frpc_sha256=unavailable/' \
  -e 's/^default_frps_sha256=.*/default_frps_sha256=unavailable/' \
  -e 's/^experiment_frpc_sha256=.*/experiment_frpc_sha256=unavailable/' \
  -e 's/^experiment_frps_sha256=.*/experiment_frps_sha256=unavailable/' \
  -e 's/^docker_image_id=.*/docker_image_id=unavailable/' \
  "$summary_pmtud" >"$summary_unavailable_pmtud"
summary_unavailable_json="$TEST_DIR/summary-unavailable.json"
run_expect 1 "$TEST_DIR/summary-unavailable.out" bash "$SUMMARY" \
  --output "$summary_unavailable_json" --p2p "$summary_unavailable_p2p" \
  --relay "$summary_unavailable_relay" --pmtud "$summary_unavailable_pmtud"
validate_json "$summary_unavailable_json"
require_contains "$summary_unavailable_json" '^  "release_eligible": false,$'
require_contains "$summary_unavailable_json" 'incomplete-provenance'
pass 'unavailable or unknown provenance produces a valid ineligible summary'

summary_dirty="$TEST_DIR/summary-dirty-p2p.log"
sed -e 's/^worktree_dirty=.*/worktree_dirty=true/' \
  -e 's/^release_eligible=.*/release_eligible=false/' \
  "$summary_p2p" >"$summary_dirty"
run_expect 1 "$TEST_DIR/summary-dirty.out" bash "$SUMMARY" \
  --output "$TEST_DIR/summary-dirty.json" --p2p "$summary_dirty" \
  --relay "$summary_relay" --pmtud "$summary_pmtud"
require_contains "$TEST_DIR/summary-dirty.json" 'dirty-worktree'
pass 'dirty worktree evidence cannot become release eligible'

summary_missing="$TEST_DIR/summary-missing-field.log"
sed '/^git_tree=/d' "$summary_p2p" >"$summary_missing"
run_expect 2 "$TEST_DIR/summary-missing.out" bash "$SUMMARY" \
  --output "$TEST_DIR/summary-missing.json" --p2p "$summary_missing" \
  --relay "$summary_relay" --pmtud "$summary_pmtud"
[[ ! -e "$TEST_DIR/summary-missing.json" ]]
pass 'missing provenance fields are rejected as malformed input'

summary_invalid_hash="$TEST_DIR/summary-invalid-hash.log"
sed 's/^frpc_sha256=.*/frpc_sha256=not-a-sha256/' "$summary_p2p" >"$summary_invalid_hash"
run_expect 2 "$TEST_DIR/summary-invalid-hash.out" bash "$SUMMARY" \
  --output "$TEST_DIR/summary-invalid-hash.json" --p2p "$summary_invalid_hash" \
  --relay "$summary_relay" --pmtud "$summary_pmtud"
pass 'invalid artifact hashes are rejected'

summary_hash_mismatch="$TEST_DIR/summary-hash-mismatch-relay.log"
sed 's/^frpc_sha256=.*/frpc_sha256=9999999999999999999999999999999999999999999999999999999999999999/' \
  "$summary_relay" >"$summary_hash_mismatch"
run_expect 1 "$TEST_DIR/summary-hash-mismatch.out" bash "$SUMMARY" \
  --output "$TEST_DIR/summary-hash-mismatch.json" --p2p "$summary_p2p" \
  --relay "$summary_hash_mismatch" --pmtud "$summary_pmtud"
require_contains "$TEST_DIR/summary-hash-mismatch.json" 'artifact-provenance-mismatch'
pass 'matching Git provenance cannot hide mismatched P2P and Relay artifacts'

summary_cross="$TEST_DIR/summary-cross-provenance-relay.log"
sed 's/^git_head=.*/git_head=9999999999999999999999999999999999999999/' \
  "$summary_relay" >"$summary_cross"
run_expect 1 "$TEST_DIR/summary-cross.out" bash "$SUMMARY" \
  --output "$TEST_DIR/summary-cross.json" --p2p "$summary_p2p" \
  --relay "$summary_cross" --pmtud "$summary_pmtud"
require_contains "$TEST_DIR/summary-cross.json" 'provenance-mismatch'
pass 'cross-provenance reports are rejected from eligibility'

summary_nonpass="$TEST_DIR/summary-nonpass-p2p.log"
sed -e 's/^release_eligible=.*/release_eligible=false/' \
  -e 's/^RESULT=PASS /RESULT=FAIL /' \
  -e 's/exit_code=0/exit_code=9/' \
  "$summary_p2p" >"$summary_nonpass"
run_expect 1 "$TEST_DIR/summary-nonpass.out" bash "$SUMMARY" \
  --output "$TEST_DIR/summary-nonpass.json" --p2p "$summary_nonpass" \
  --relay "$summary_relay" --pmtud "$summary_pmtud"
require_contains "$TEST_DIR/summary-nonpass.json" 'report-result-not-pass'
pass 'non-PASS scenario reports cannot become eligible'

special_report="$TEST_DIR/summary \"quoted\"\\path.log"
cp -- "$summary_p2p" "$special_report"
special_output="$TEST_DIR/summary-special.json"
run_expect 0 "$TEST_DIR/summary-special.out" bash "$SUMMARY" \
  --output "$special_output" --p2p "$special_report" --relay "$summary_relay" --pmtud "$summary_pmtud"
validate_json "$special_output" quoted "$special_report"
pass 'JSON escaping preserves special report output paths'

run_expect 1 "$TEST_DIR/summary-atomic-fail.out" bash "$SUMMARY" \
  --output /proc/xudp-release-summary.json --p2p "$summary_p2p" \
  --relay "$summary_relay" --pmtud "$summary_pmtud"
pass 'summary atomic creation failure is surfaced without a partial output'

[[ $(grep -Ec -- 'docker rm -f -- "\$SERVER" "\$PROXY" "\$VISITOR"' "$RECOVERY" || true) == 1 ]]
require_not_contains "$RECOVERY" 'docker rm .*(\$DEV_CONTAINER|\$NETWORK)'
pass 'real script removal remains limited to three validated names'

whitespace_files=(
  "$ROOT/dev/test/FRAGMENTATION_DECISION.md"
  "$ROOT/dev/test/README.md"
  "$ROOT/dev/test/reports/.gitignore"
  "$RECOVERY"
  "$PMTUD"
  "$ROOT/dev/test/xudp-provenance.sh"
  "$SUMMARY"
  "$ROOT/dev/test/test-xudp-docker-scripts.sh"
)
for file in "${whitespace_files[@]}"; do
  set +e
  whitespace_output=$(git diff --no-index --check -- /dev/null "$file" 2>&1)
  whitespace_rc=$?
  set -e
  [[ -z "$whitespace_output" && ( $whitespace_rc == 0 || $whitespace_rc == 1 ) ]] || {
    printf 'whitespace check failed for %s (rc=%s):\n%s\n' "$file" "$whitespace_rc" "$whitespace_output" >&2
    exit 1
  }
done
pass 'all untracked step-6 files pass no-index whitespace checks'

if (( ISOLATED_MODE )); then
  EXPECTED_PASS_COUNT=$EXPECTED_ISOLATED_PASS_COUNT
else
  EXPECTED_PASS_COUNT=$EXPECTED_ORDINARY_PASS_COUNT
fi
if (( PASS_COUNT != EXPECTED_PASS_COUNT )); then
  printf 'expected exactly %d hardening checks, got %d\n' \
    "$EXPECTED_PASS_COUNT" "$PASS_COUNT" >&2
  exit 1
fi

printf 'PASS: %d script hardening checks\n' "$PASS_COUNT"
