#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

# Docker-only XUDP P2P/Relay smoke test. The default mode uses the existing
# frpsA/frpcB/frpC lab and never changes container lifecycle state.

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
. "$ROOT/dev/test/xudp-provenance.sh"
SCRIPT_PATH=$ROOT/dev/test/run-xudp-recovery-docker.sh
INTERNAL_MARKER=__frp_xudp_recovery_internal_lock_v1
ORIGINAL_ARGS=("$@")
INTERNAL_MODE=0
SHOW_HELP=0
if [[ ${1:-} == "$INTERNAL_MARKER" ]]; then
  INTERNAL_MODE=1
  shift
fi
DEV_CONTAINER=${FRP_DEV_CONTAINER-frp-dev}
DEV_WORKDIR=${FRP_DEV_WORKDIR-/workspace/src}
NETWORK=${FRP_XUDP_NETWORK-frp-test-net}
SERVER=${FRP_XUDP_SERVER_CONTAINER-frpsA}
PROXY=${FRP_XUDP_PROXY_CONTAINER-frpcB}
VISITOR=${FRP_XUDP_VISITOR_CONTAINER-frpC}
UDP_SEND=${FRP_XUDP_UDP_SEND-}
UDP_ECHO=${FRP_XUDP_UDP_ECHO-}
PREBUILT_FRPS=${FRP_XUDP_FRPS-}
PREBUILT_FRPC=${FRP_XUDP_FRPC-}
HOST_UID=$(id -u)
HOST_GID=$(id -g)
PREBUILT_ARTIFACT_COUNT=0
PREBUILT_ARTIFACT_MODE=0
FRPS_SOURCE_PATH=unavailable
FRPC_SOURCE_PATH=unavailable
UDP_SEND_SOURCE_PATH=unavailable
UDP_ECHO_SOURCE_PATH=unavailable
FRPS_SOURCE_SHA256=unavailable
FRPC_SOURCE_SHA256=unavailable
UDP_SEND_SOURCE_SHA256=unavailable
UDP_ECHO_SOURCE_SHA256=unavailable
if [[ ${FRP_XUDP_RECOVERY_REPORT+x} ]]; then
  REPORT=$FRP_XUDP_RECOVERY_REPORT
else
  REPORT="$ROOT/dev/test/reports/xudp-recovery-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
fi
MODE=existing
RECREATE=0
REPORT_FD=
CONSOLE_OUT_FD=
CONSOLE_ERR_FD=
REPORT_READY=0
FINAL_DETAIL=unexpected-exit
ACTIVE_TMP_DIR=
OLD_RUNTIME_DIR=
OLD_RUNTIME_IDENTITY=
OLD_RUNTIME_CLEANUP_STATUS=NOT_APPLICABLE
OLD_RUNTIME_CLEANUP_RC=0
OLD_RUNTIME_CLEANUP_DETAIL=not-evaluated
CURRENT_RUNTIME_CLEANUP_STATUS=NOT_REQUIRED
CURRENT_RUNTIME_CLEANUP_RC=0
CURRENT_RUNTIME_CLEANUP_DETAIL=not-required
RUNTIME_IDENTITY_LABEL_KEY=frp.xudp.runtime.identity
RUNTIME_PATH_LABEL_KEY=frp.xudp.runtime.path
CURRENT_RUNTIME_IDENTITY=
CURRENT_RUNTIME_ROOT_REALPATH=
CURRENT_RUNTIME_ROOT_DEVINO=
CURRENT_RUNTIME_ROOT_KIND=
CURRENT_RUNTIME_ROOT_UID=
CURRENT_RUNTIME_ROOT_MODE=
CURRENT_RUNTIME_BIN_REALPATH=
CURRENT_RUNTIME_BIN_DEVINO=
CURRENT_RUNTIME_BIN_KIND=
CURRENT_RUNTIME_BIN_UID=
CURRENT_RUNTIME_BIN_MODE=
CURRENT_RUNTIME_CONFIG_REALPATH=
CURRENT_RUNTIME_CONFIG_DEVINO=
CURRENT_RUNTIME_CONFIG_KIND=
CURRENT_RUNTIME_CONFIG_UID=
CURRENT_RUNTIME_CONFIG_MODE=
CURRENT_RUNTIME_LOG_REALPATH=
CURRENT_RUNTIME_LOG_DEVINO=
CURRENT_RUNTIME_LOG_KIND=
CURRENT_RUNTIME_LOG_UID=
CURRENT_RUNTIME_LOG_MODE=
declare -a CURRENT_RUNTIME_STATIC_KEYS=(
  frps frpc udp_send udp_echo frps_config frpc_config visitor_config
)
declare -Ag CURRENT_RUNTIME_STATIC_PATH=()
declare -Ag CURRENT_RUNTIME_STATIC_REALPATH=()
declare -Ag CURRENT_RUNTIME_STATIC_DEVINO=()
declare -Ag CURRENT_RUNTIME_STATIC_KIND=()
declare -Ag CURRENT_RUNTIME_STATIC_UID=()
declare -Ag CURRENT_RUNTIME_STATIC_NLINK=()
declare -Ag CURRENT_RUNTIME_STATIC_MODE=()
declare -Ag CURRENT_RUNTIME_STATIC_SHA256=()
CURRENT_RUNTIME_STATIC_SNAPSHOT_READY=0
SCENARIO=existing
BUILD_STARTED_AT_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
XUDP_GIT_HEAD=unavailable
XUDP_GIT_TREE=unavailable
XUDP_WORKTREE_DIRTY=unknown
XUDP_STATUS_DIGEST=unavailable
XUDP_STATUS_ENTRIES=unavailable
FRPC_SHA256=unavailable
FRPS_SHA256=unavailable
UDP_SEND_SHA256=unavailable
UDP_ECHO_SHA256=unavailable
FRPC_CONFIG_SHA256=unavailable
FRPS_CONFIG_SHA256=unavailable
VISITOR_CONFIG_SHA256=unavailable
DOCKER_IMAGE_SERVER=unavailable
DOCKER_IMAGE_PROXY=unavailable
DOCKER_IMAGE_VISITOR=unavailable
PROVENANCE_VALID=0
# This is intentionally not configurable.  The fixed path is part of the
# same-UID trust boundary used by the process-group lock wrapper.
RECOVERY_LOCK_PATH=/tmp/frp-xudp-recovery-uid-$(id -u)
INNER_PID=0
INNER_PGID=0
INNER_STARTTIME=0
INNER_JOB_REGISTERED=0
INNER_REAPED=0
OUTER_ABORT_FAILED=0
declare -a OUTER_PENDING_SIGNALS=()
OUTER_CHILD_WAIT_RC=74
RECOVERY_RC_INTERNAL=74
RECOVERY_RC_TIMEOUT=124
RECOVERY_SUPERVISOR_MAX_SECONDS=900
RECOVERY_IDENTITY_MAX_SECONDS=30
export RECOVERY_RC_INTERNAL
export RECOVERY_RC_TIMEOUT
export RECOVERY_SUPERVISOR_MAX_SECONDS
export RECOVERY_IDENTITY_MAX_SECONDS

proc_snapshot() {
  local pid=${1:-} line rest state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime cutime cstime priority nice num_threads itrealvalue starttime proc_stat_fd
  [[ "$pid" =~ ^[0-9]+$ && "$pid" != 0 ]] || return 3
  [[ -e "/proc/$pid" ]] || return 2
  [[ -r "/proc/$pid/stat" ]] || {
    [[ ! -e "/proc/$pid/stat" ]] && return 2
    return 3
  }
  if ! { exec {proc_stat_fd}<"/proc/$pid/stat"; } 2>/dev/null; then
    [[ ! -e "/proc/$pid/stat" ]] && return 2
    return 3
  fi
  if ! { IFS= read -r -u "$proc_stat_fd" line; } 2>/dev/null; then
    exec {proc_stat_fd}<&-
    if [[ ! -e "/proc/$pid/stat" ]] || ! kill -0 "$pid" 2>/dev/null; then
      return 2
    fi
    return 3
  fi
  exec {proc_stat_fd}<&-
  if [[ "$line" != *") "* ]]; then
    if ! { exec {proc_stat_fd}<"/proc/$pid/stat"; } 2>/dev/null; then
      [[ ! -e "/proc/$pid/stat" ]] && return 2
      return 3
    fi
    if ! { IFS= read -r -u "$proc_stat_fd" line; } 2>/dev/null; then
      exec {proc_stat_fd}<&-
      if [[ ! -e "/proc/$pid/stat" ]] || ! kill -0 "$pid" 2>/dev/null; then
        return 2
      fi
      return 3
    fi
    exec {proc_stat_fd}<&-
    [[ "$line" == *") "* ]] || {
      [[ ! -e "/proc/$pid/stat" ]] && return 2
      return 3
    }
  fi
  rest=${line##*) }
  read -r state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime cutime cstime priority nice num_threads itrealvalue starttime _ <<<"$rest" || return 3
  [[ -n "$state" && -n "$pgrp" && -n "$starttime" ]] || {
    [[ ! -e "/proc/$pid/stat" ]] && return 2
    return 3
  }
  PROC_STATE=$state
  PROC_PGID=$pgrp
  PROC_STARTTIME=$starttime
  return 0
}

classify_process() {
  local pid=${1:-} snapshot_rc proc_dir_identity
  PROC_STATE=unknown
  [[ "$pid" =~ ^[0-9]+$ && "$pid" != 0 ]] || return 3
  if [[ ! -d "/proc/$pid" ]]; then
    # A process that has already disappeared is a known terminal state. The
    # caller still verifies the process group before declaring teardown safe.
    return 2
  fi
  proc_dir_identity=$(stat -Lc '%d:%i' -- "/proc/$pid" 2>/dev/null) || {
    [[ ! -d "/proc/$pid" ]] && return 2
    return 3
  }
  [[ "$proc_dir_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 3
  if proc_snapshot "$pid"; then
    [[ "$PROC_STATE" == Z* ]] && return 1
    return 0
  else
    snapshot_rc=$?
  fi
  [[ "$snapshot_rc" == 3 ]] && return 3
  [[ "$snapshot_rc" == 2 ]] && return 2
  return 3
}

job_state_for_pid() {
  local pid=${1:-} all running stopped
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 3
  if [[ "$pid" == "$INNER_PID" ]]; then
    (( INNER_JOB_REGISTERED )) || return 3
  fi
  all=$(jobs -p 2>/dev/null) || return 3
  [[ $'\n'"$all"$'\n' == *$'\n'"$pid"$'\n'* ]] || return 3
  running=$(jobs -pr 2>/dev/null) || return 3
  [[ $'\n'"$running"$'\n' == *$'\n'"$pid"$'\n'* ]] && return 0
  stopped=$(jobs -ps 2>/dev/null) || return 3
  [[ $'\n'"$stopped"$'\n' == *$'\n'"$pid"$'\n'* ]] && return 1
  return 2
}

outer_queue_signal() {
  OUTER_PENDING_SIGNALS+=("$1")
}

outer_flush_pending_signals() {
  local signal group_rc=0
  while ((${#OUTER_PENDING_SIGNALS[@]} > 0)); do
    signal=${OUTER_PENDING_SIGNALS[0]}
    (( INNER_PID > 0 && INNER_PGID > 0 && INNER_STARTTIME > 0 )) || return 1
    if ! proc_snapshot "$INNER_PID" ||
       [[ "$PROC_PGID" != "$INNER_PGID" || "$PROC_STARTTIME" != "$INNER_STARTTIME" ||
          "$PROC_STATE" == Z* ]]; then
      return 1
    fi
    outer_group_state "$INNER_PGID" || group_rc=$?
    (( group_rc == 0 )) || return 1
    # The group scan is only a membership snapshot.  Revalidate the
    # authenticated leader immediately before the negative-PGID signal so a
    # disappearing or recycled leader cannot turn the snapshot into authority.
    if ! proc_snapshot "$INNER_PID" ||
       [[ "$PROC_PGID" != "$INNER_PGID" || "$PROC_STARTTIME" != "$INNER_STARTTIME" ||
          "$PROC_STATE" == Z* ]]; then
      return 1
    fi
    if ! kill -"$signal" -- "-$INNER_PGID" 2>/dev/null; then
      return 1
    fi
    OUTER_PENDING_SIGNALS=("${OUTER_PENDING_SIGNALS[@]:1}")
  done
  return 0
}

usage() {
  cat <<'EOF'
Usage: run-xudp-recovery-docker.sh [--existing|--p2p|--relay] [--recreate] [--report PATH]

  --existing       Inspect and probe existing named containers (default).
                   Set FRP_XUDP_UDP_SEND and FRP_XUDP_UDP_ECHO to helpers
                   from the prepared runtime. udp_echo is only needed when
                   creating a new runtime.
  --p2p            Build current worktree binaries and run the P2P scenario.
  --relay          Build current worktree binaries and force STUN unreachable
                   to exercise the Relay fallback scenario.
                   For recreate, set all four of FRP_XUDP_FRPS, FRP_XUDP_FRPC,
                   FRP_XUDP_UDP_SEND and FRP_XUDP_UDP_ECHO to consume
                   prebuilt artifacts without using the dev container.
  --recreate       Required for --p2p/--relay; permits replacing only
                   frpsA, frpcB and frpC.
  --report PATH    Write a new, persistent report at PATH. Existing paths and
                   symbolic links are refused. The default is under
                   dev/test/reports/.

This Docker bridge test does not cover public NAT, CGNAT, VPN, 5G, Wi-Fi or a
live in-session P2P-to-Relay path fault.
EOF
}

while (($# > 0)); do
  case "$1" in
    --existing) MODE=existing ;;
    --p2p) MODE=p2p ;;
    --relay) MODE=relay ;;
    --recreate) RECREATE=1 ;;
    --report)
      (($# >= 2)) || { echo "--report requires a path" >&2; exit 2; }
      REPORT=$2
      shift
      ;;
    -h|--help) SHOW_HELP=1; break ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# Reject an incomplete prebuilt-artifact selection before report creation,
# traps, recovery locks, markers, supervisors, or runtime staging can begin.
# The deeper mode/path/canonical/SHA checks remain below; this is only the
# single shared 0-or-4 completeness gate.
validate_prebuilt_artifact_selection_early() {
  local name value count=0
  if [[ "$MODE" == existing ]]; then
    if [[ -n "$PREBUILT_FRPS" || -n "$PREBUILT_FRPC" ]]; then
      printf 'FRP_XUDP_FRPS and FRP_XUDP_FRPC are not valid with --existing; use --p2p/--relay --recreate\n' >&2
      exit 2
    fi
    PREBUILT_ARTIFACT_COUNT=0
    PREBUILT_ARTIFACT_MODE=0
    return 0
  fi
  for name in PREBUILT_FRPS PREBUILT_FRPC UDP_SEND UDP_ECHO; do
    value=${!name-}
    [[ -n "$value" ]] && count=$((count + 1))
  done
  PREBUILT_ARTIFACT_COUNT=$count
  if [[ "$MODE" == p2p || "$MODE" == relay ]] && (( RECREATE )) &&
    [[ "$count" != 0 && "$count" != 4 ]]; then
      printf 'prebuilt artifact selection requires either none or all four paths: FRP_XUDP_FRPS, FRP_XUDP_FRPC, FRP_XUDP_UDP_SEND, FRP_XUDP_UDP_ECHO\n' >&2
      exit 2
  fi
  if [[ "$MODE" == p2p || "$MODE" == relay ]] && (( RECREATE )) && [[ "$count" == 4 ]]; then
    PREBUILT_ARTIFACT_MODE=1
  else
    PREBUILT_ARTIFACT_MODE=0
  fi
}
validate_prebuilt_artifact_selection_early

SCENARIO=$MODE
create_report() {
  local parent old_umask had_noclobber=0
  [[ -n "$REPORT" ]] || { echo "report path must not be empty" >&2; return 2; }
  [[ "$REPORT" != *$'\n'* && "$REPORT" != *$'\r'* ]] || {
    echo "report path contains a newline" >&2
    return 2
  }
  parent=$(dirname -- "$REPORT")
  mkdir -p -- "$parent" || return 1
  [[ -d "$parent" ]] || { echo "report parent is not a directory: $parent" >&2; return 1; }
  if [[ -e "$REPORT" || -L "$REPORT" ]]; then
    echo "refusing to overwrite existing report path: $REPORT" >&2
    return 1
  fi

  old_umask=$(umask)
  umask 077
  [[ $- == *C* ]] && had_noclobber=1
  set -C
  if ! exec {REPORT_FD}>"$REPORT"; then
    (( had_noclobber )) || set +C
    umask "$old_umask"
    echo "unable to create report exclusively: $REPORT" >&2
    return 1
  fi
  (( had_noclobber )) || set +C
  umask "$old_umask"
}

validate_recovery_lock_dir() {
  local old_umask current_uid lock_stat lock_kind lock_owner lock_mode
  current_uid=$(id -u)
  old_umask=$(umask)
  umask 077
  if [[ ! -e "$RECOVERY_LOCK_PATH" && ! -L "$RECOVERY_LOCK_PATH" ]]; then
    if ! mkdir -- "$RECOVERY_LOCK_PATH" 2>/dev/null; then
      [[ -e "$RECOVERY_LOCK_PATH" || -L "$RECOVERY_LOCK_PATH" ]] || {
        umask "$old_umask"
        printf 'unable to atomically create recovery lock directory: %s\n' \
          "$RECOVERY_LOCK_PATH" >&2
        exit "$RECOVERY_RC_INTERNAL"
      }
    fi
  fi
  umask "$old_umask"

  [[ ! -L "$RECOVERY_LOCK_PATH" && -d "$RECOVERY_LOCK_PATH" ]] || {
    umask "$old_umask"
    printf 'recovery lock path is not a non-symlink directory: %s\n' \
      "$RECOVERY_LOCK_PATH" >&2
    exit "$RECOVERY_RC_INTERNAL"
  }
  lock_stat=$(stat -Lc '%d:%i %F %u %a' -- "$RECOVERY_LOCK_PATH" 2>/dev/null) || {
    printf 'unable to stat recovery lock directory: %s\n' "$RECOVERY_LOCK_PATH" >&2
    exit "$RECOVERY_RC_INTERNAL"
  }
  read -r path_dev_inode lock_kind lock_owner lock_mode <<<"$lock_stat" || {
    printf 'unable to parse recovery lock metadata\n' >&2
    exit "$RECOVERY_RC_INTERNAL"
  }
  [[ "$lock_kind" == directory && "$lock_owner" == "$current_uid" &&
     "$lock_mode" == 700 ]] || {
    printf 'recovery lock directory must be uid-owned mode 0700: %s\n' \
      "$RECOVERY_LOCK_PATH" >&2
    exit "$RECOVERY_RC_INTERNAL"
  }

}

validate_internal_lock_holder() {
  local marker=${FRP_XUDP_INTERNAL_READY_FILE-} probe_fd probe_rc marker_stat lock_inode
  [[ -n "$marker" ]] || exit 75
  read_recovery_state "$marker" || {
    printf 'internal marker is missing, unsafe or malformed\n' >&2
    exit "$RECOVERY_RC_INTERNAL"
  }
  lock_inode=$(stat -Lc '%d:%i' -- "$RECOVERY_LOCK_PATH" 2>/dev/null) || exit "$RECOVERY_RC_INTERNAL"
  [[ "$lock_inode" == "$RECOVERY_STATE_LOCK_INODE" ]] || exit "$RECOVERY_RC_INTERNAL"
  proc_snapshot "$RECOVERY_STATE_SUPERVISOR_PID" || exit "$RECOVERY_RC_INTERNAL"
  [[ "$PROC_STATE" != Z* && "$PROC_PGID" == "$RECOVERY_STATE_SUPERVISOR_PGID" &&
     "$PROC_STARTTIME" == "$RECOVERY_STATE_SUPERVISOR_STARTTIME" &&
     "$RECOVERY_STATE_SUPERVISOR_PID" == "$PPID" ]] || {
    printf 'internal marker supervisor identity mismatch\n' >&2
    exit "$RECOVERY_RC_INTERNAL"
  }
  validate_recovery_lock_dir
  exec {probe_fd}<"$RECOVERY_LOCK_PATH" || exit "$RECOVERY_RC_INTERNAL"
  marker_stat=$(stat -Lc '%d:%i' -- "/proc/$$/fd/$probe_fd" 2>/dev/null) || {
    exec {probe_fd}>&-
    exit "$RECOVERY_RC_INTERNAL"
  }
  [[ "$marker_stat" == "$lock_inode" ]] || {
    exec {probe_fd}>&-
    printf 'internal marker lock identity mismatch\n' >&2
    exit "$RECOVERY_RC_INTERNAL"
  }
  if /usr/bin/flock -E 75 -n "$probe_fd"; then
    probe_rc=0
  else
    probe_rc=$?
  fi
  exec {probe_fd}>&-
  [[ $probe_rc == 75 ]] || {
    printf 'internal marker requires the authenticated lock to remain held\n' >&2
    exit "$RECOVERY_RC_INTERNAL"
  }
}

forward_inner_signal() {
  outer_queue_signal "$1"
  if ! outer_flush_pending_signals; then
    outer_abort_inner signal-forward-failed || true
  fi
}

outer_group_state() {
  local wanted_pgid=${1:-} entry pid snapshot_rc
  local live=0 zombie=0
  [[ "$wanted_pgid" =~ ^[0-9]+$ && "$wanted_pgid" -gt 0 ]] || return 3
  for entry in /proc/[0-9]*; do
    [[ -d "$entry" ]] || continue
    pid=${entry##*/}
    [[ -e "$entry/stat" ]] || continue
    if proc_snapshot "$pid"; then
      :
    else
      snapshot_rc=$?
      [[ $snapshot_rc == 2 ]] && continue
      printf 'outer group state unknown: pid=%s pgid=%s\n' "$pid" "$wanted_pgid" >&2
      return 3
    fi
    [[ "$PROC_PGID" == "$wanted_pgid" ]] || continue
    if [[ "$PROC_STATE" == Z* ]]; then
      zombie=1
    else
      live=1
    fi
  done
  if (( live )); then
    return 0
  fi
  if (( zombie )); then
    return 1
  fi
  return 2
}

validate_recovery_marker_phase() {
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

read_recovery_state() {
  local state_file=${1:-} key value seen=0 current_uid state_stat
  RECOVERY_STATE_PHASE=
  RECOVERY_STATE_LOCK_INODE=
  RECOVERY_STATE_RESULT_RC=
  RECOVERY_STATE_SUPERVISOR_PID=
  RECOVERY_STATE_SUPERVISOR_PGID=
  RECOVERY_STATE_SUPERVISOR_STARTTIME=
  RECOVERY_STATE_BUSINESS_PID=
  RECOVERY_STATE_BUSINESS_PGID=
  RECOVERY_STATE_BUSINESS_STARTTIME=
  [[ -n "$state_file" && ! -L "$state_file" && -f "$state_file" ]] || return 1
  current_uid=$(id -u)
  state_stat=$(stat -Lc '%F %u %a' -- "$state_file" 2>/dev/null) || return 1
  [[ "$state_stat" == "regular file $current_uid 600" ]] || return 1
  while IFS='=' read -r key value; do
    [[ -n "$key" && -n "$value" ]] || return 1
    case "$key" in
      phase) [[ -z "$RECOVERY_STATE_PHASE" ]] || return 1; RECOVERY_STATE_PHASE=$value ;;
      lock_inode) [[ -z "$RECOVERY_STATE_LOCK_INODE" ]] || return 1; RECOVERY_STATE_LOCK_INODE=$value ;;
      result_rc) [[ -z "$RECOVERY_STATE_RESULT_RC" ]] || return 1; RECOVERY_STATE_RESULT_RC=$value ;;
      supervisor_pid) [[ -z "$RECOVERY_STATE_SUPERVISOR_PID" ]] || return 1; RECOVERY_STATE_SUPERVISOR_PID=$value ;;
      supervisor_pgid) [[ -z "$RECOVERY_STATE_SUPERVISOR_PGID" ]] || return 1; RECOVERY_STATE_SUPERVISOR_PGID=$value ;;
      supervisor_starttime) [[ -z "$RECOVERY_STATE_SUPERVISOR_STARTTIME" ]] || return 1; RECOVERY_STATE_SUPERVISOR_STARTTIME=$value ;;
      business_pid) [[ -z "$RECOVERY_STATE_BUSINESS_PID" ]] || return 1; RECOVERY_STATE_BUSINESS_PID=$value ;;
      business_pgid) [[ -z "$RECOVERY_STATE_BUSINESS_PGID" ]] || return 1; RECOVERY_STATE_BUSINESS_PGID=$value ;;
      business_starttime) [[ -z "$RECOVERY_STATE_BUSINESS_STARTTIME" ]] || return 1; RECOVERY_STATE_BUSINESS_STARTTIME=$value ;;
      *) return 1 ;;
    esac
    seen=$((seen + 1))
  done <"$state_file"
  [[ $seen == 9 && "$RECOVERY_STATE_PHASE" =~ ^(supervisor-ready|business-starting|business-ready|business-exited|body-running|body-success|body-failed|timeout)$ ]] || return 1
  [[ "$RECOVERY_STATE_LOCK_INODE" =~ ^[1-9][0-9]*:[1-9][0-9]*$ &&
     "$RECOVERY_STATE_RESULT_RC" =~ ^(0|[1-9][0-9]*)$ &&
     "$RECOVERY_STATE_SUPERVISOR_PID" =~ ^[0-9]+$ && "$RECOVERY_STATE_SUPERVISOR_PID" != 0 &&
     "$RECOVERY_STATE_SUPERVISOR_PGID" =~ ^[0-9]+$ && "$RECOVERY_STATE_SUPERVISOR_PGID" != 0 &&
     "$RECOVERY_STATE_SUPERVISOR_STARTTIME" =~ ^[1-9][0-9]*$ &&
     "$RECOVERY_STATE_BUSINESS_PID" =~ ^[0-9]+$ &&
     "$RECOVERY_STATE_BUSINESS_PGID" =~ ^[0-9]+$ &&
     "$RECOVERY_STATE_BUSINESS_STARTTIME" =~ ^[0-9]+$ ]] || return 1
  validate_recovery_marker_phase "$RECOVERY_STATE_PHASE" "$RECOVERY_STATE_RESULT_RC" \
    "$RECOVERY_STATE_BUSINESS_PID" "$RECOVERY_STATE_BUSINESS_PGID" \
    "$RECOVERY_STATE_BUSINESS_STARTTIME"
}

recover_unpublished_business() {
  local state_file=$1 phase=$2 pid=$3 pgid=$4 starttime=$5
  local process_rc=0 group_rc=0 ticks=0 term_sent=0 kill_sent=0
  printf 'inner supervisor exited before stable business PGID: phase=%s pid=%s pgid=%s\n' \
    "$phase" "$pid" "$pgid" >&2
  [[ "$pid" =~ ^[0-9]+$ && "$pgid" =~ ^[0-9]+$ && "$starttime" =~ ^[0-9]*$ ]] || {
    printf 'early business identity is incomplete; refusing signal delivery\n' >&2
    return "$RECOVERY_RC_INTERNAL"
  }
  (( pid > 0 )) || return 0
  if [[ -n "$starttime" && "$starttime" != 0 ]]; then
    if proc_snapshot "$pid"; then
      [[ "$PROC_STARTTIME" == "$starttime" && "$PROC_STATE" != Z* ]] || {
        printf 'early business identity no longer matches; refusing signal delivery\n' >&2
        return "$RECOVERY_RC_INTERNAL"
      }
      [[ "$pgid" == 0 || "$PROC_PGID" == "$pgid" ]] || {
        printf 'early business PGID identity mismatch; refusing signal delivery\n' >&2
        return "$RECOVERY_RC_INTERNAL"
      }
      pgid=$PROC_PGID
    else
      process_rc=$?
      (( process_rc == 1 || process_rc == 2 )) || {
        printf 'early business identity is unknown; refusing signal delivery\n' >&2
        return "$RECOVERY_RC_INTERNAL"
      }
    fi
  fi
  (( pgid > 0 )) || return 0
  while (( ticks < 300 )); do
    group_rc=0
    outer_group_state "$pgid" || group_rc=$?
    (( group_rc == 3 )) && {
      printf 'early business group identity became unknown\n' >&2
      return "$RECOVERY_RC_INTERNAL"
    }
    (( group_rc == 2 || group_rc == 1 )) && return 0
    if proc_snapshot "$pid"; then
      [[ "$PROC_STATE" != Z* && "$PROC_STARTTIME" == "$starttime" &&
         "$PROC_PGID" == "$pgid" ]] || {
        printf 'early business identity changed before signal delivery\n' >&2
        return "$RECOVERY_RC_INTERNAL"
      }
    else
      process_rc=$?
      return "$RECOVERY_RC_INTERNAL"
    fi
    if (( ! term_sent )); then
      kill -TERM -- "-$pgid" 2>/dev/null || return "$RECOVERY_RC_INTERNAL"
      term_sent=1
    elif (( ! kill_sent && ticks >= 150 )); then
      kill -KILL -- "-$pgid" 2>/dev/null || true
      kill_sent=1
    fi
    /bin/sleep 0.01
    ticks=$((ticks + 1))
  done
  printf 'early business group did not clear within bounded teardown\n' >&2
  return "$RECOVERY_RC_INTERNAL"
}

terminate_inner_bounded() {
  local reason=${1:-teardown} ticks=0 process_rc=0 group_rc=0 job_rc=0
  local term_sent=0 kill_sent=0
  printf 'outer bounded inner teardown reason=%s pid=%s pgid=%s\n' \
    "$reason" "$INNER_PID" "$INNER_PGID" >&2 || true
  [[ "$INNER_PID" =~ ^[0-9]+$ && "$INNER_PGID" =~ ^[0-9]+$ &&
     "$INNER_STARTTIME" =~ ^[0-9]+$ && "$INNER_PID" -gt 0 &&
     "$INNER_PGID" -gt 0 && "$INNER_STARTTIME" -gt 0 ]] || {
    printf 'inner teardown identity is incomplete; refusing signal delivery\n' >&2
    return "$RECOVERY_RC_INTERNAL"
  }
  while (( ticks < 300 )); do
    job_rc=0
    job_state_for_pid "$INNER_PID" || job_rc=$?
    if (( job_rc == 2 )); then
      group_rc=0
      outer_group_state "$INNER_PGID" || group_rc=$?
      (( group_rc == 2 )) && return 0
      printf 'inner supervisor job exited without proving group teardown: pgid=%s state=%s\n' "$INNER_PGID" "$group_rc" >&2
      return "$RECOVERY_RC_INTERNAL"
    fi
    (( job_rc == 3 )) && return "$RECOVERY_RC_INTERNAL"
    if proc_snapshot "$INNER_PID"; then
      [[ "$PROC_STATE" != Z* && "$PROC_STARTTIME" == "$INNER_STARTTIME" &&
         "$PROC_PGID" == "$INNER_PGID" ]] || return "$RECOVERY_RC_INTERNAL"
    else
      process_rc=$?
      (( process_rc == 1 )) || return "$RECOVERY_RC_INTERNAL"
      outer_group_state "$INNER_PGID" || group_rc=$?
      (( group_rc == 1 || group_rc == 2 )) && return 0
      return "$RECOVERY_RC_INTERNAL"
    fi
    group_rc=0
    outer_group_state "$INNER_PGID" || group_rc=$?
    (( group_rc == 3 )) && return "$RECOVERY_RC_INTERNAL"
    (( group_rc == 1 || group_rc == 2 )) && return 0
    # Revalidate the leader immediately before every group signal.  If the
    # leader identity is gone or reused, fail closed instead of signalling a
    # recycled PGID.
    job_rc=0
    job_state_for_pid "$INNER_PID" || job_rc=$?
    (( job_rc == 2 )) && continue
    (( job_rc == 3 )) && return "$RECOVERY_RC_INTERNAL"
    if proc_snapshot "$INNER_PID"; then
      :
    else
      process_rc=$?
      return "$RECOVERY_RC_INTERNAL"
    fi
    [[ "$PROC_STATE" != Z* && "$PROC_STARTTIME" == "$INNER_STARTTIME" &&
       "$PROC_PGID" == "$INNER_PGID" ]] || return "$RECOVERY_RC_INTERNAL"
    if (( ! term_sent )); then
      kill -TERM -- "-$INNER_PGID" 2>/dev/null || return "$RECOVERY_RC_INTERNAL"
      term_sent=1
    elif (( ! kill_sent && ticks >= 150 )); then
      kill -KILL -- "-$INNER_PGID" 2>/dev/null || return "$RECOVERY_RC_INTERNAL"
      kill_sent=1
    fi
    /bin/sleep 0.01
    ticks=$((ticks + 1))
  done
  printf 'inner supervisor bounded teardown timed out\n' >&2
  return "$RECOVERY_RC_INTERNAL"
}

reap_inner_if_finished() {
  local wait_rc=0 process_rc=0 job_rc=0
  (( INNER_REAPED )) && return 0
  job_state_for_pid "$INNER_PID" || job_rc=$?
  case "$job_rc" in
    0|1) return 1 ;;
    2) : ;;
    3)
      classify_process "$INNER_PID" || process_rc=$?
      case "$process_rc" in
        0) return 1 ;;
        1) : ;;
        *) return 3 ;;
      esac
      ;;
    *) return 3 ;;
  esac
  if wait "$INNER_PID"; then
    wait_rc=0
  else
    wait_rc=$?
  fi
  OUTER_CHILD_WAIT_RC=$wait_rc
  INNER_REAPED=1
  return 0
}

outer_abort_inner() {
  local reason=${1:-outer-abort} teardown_rc=0 reap_rc=0 group_rc=0
  (( INNER_PID > 0 )) || return 1
  if (( ! INNER_REAPED && INNER_PID > 0 && INNER_PGID > 0 && INNER_STARTTIME > 0 )); then
    terminate_inner_bounded "$reason" || teardown_rc=$?
    (( teardown_rc == 0 )) || return "$teardown_rc"
  fi
  reap_inner_if_finished || reap_rc=$?
  if (( reap_rc != 0 )); then
    printf 'outer abort could not prove inner death/reap: pid=%s rc=%s\n' "$INNER_PID" "$reap_rc" >&2
    return "$RECOVERY_RC_INTERNAL"
  fi
  if (( INNER_PGID > 0 )); then
    outer_group_state "$INNER_PGID" || group_rc=$?
    case "$group_rc" in
      2) return 0 ;;
      *)
        printf 'outer abort could not prove inner group reaped: pgid=%s state=%s\n' "$INNER_PGID" "$group_rc" >&2
        return "$RECOVERY_RC_INTERNAL"
        ;;
    esac
  fi
  return 0
}

abort_inner_checked() {
  local reason=${1:-outer-abort} abort_rc=0
  outer_abort_inner "$reason" || abort_rc=$?
  if (( abort_rc != 0 )); then
    printf 'outer abort failed; preserving recovery markers: reason=%s rc=%s\n' "$reason" "$abort_rc" >&2
    return "$RECOVERY_RC_INTERNAL"
  fi
  return 0
}

run_locked_child() {
  local group_ready=0 process_rc group_rc reap_rc wait_status=$RECOVERY_RC_INTERNAL marker_dir ready_file child_script
  local outer_deadline identity_deadline identity_published=0
  local marker_dir_realpath marker_dir_dev_inode marker_dir_uid marker_dir_mode marker_dir_kind marker_dir_stat
  local marker_dir_pre_chmod_realpath marker_dir_pre_chmod_dev_inode marker_dir_pre_chmod_uid
  local marker_dir_pre_chmod_kind marker_dir_pre_chmod_stat marker_dir_pre_chmod_entries
  local marker_dir_current_realpath marker_dir_current_dev_inode marker_dir_current_kind marker_dir_current_uid marker_dir_current_stat
  command -v id >/dev/null 2>&1 || { printf 'id is required\n' >&2; return "$RECOVERY_RC_INTERNAL"; }
  [[ -x /usr/bin/setsid && -x /usr/bin/flock ]] || {
    printf 'setsid and /usr/bin/flock are required for the recovery lock\n' >&2
    return "$RECOVERY_RC_INTERNAL"
  }
  marker_dir=$(mktemp -d /tmp/frp-xudp-recovery-marker.XXXXXX) || return "$RECOVERY_RC_INTERNAL"
  marker_dir_pre_chmod_realpath=$(realpath -- "$marker_dir" 2>/dev/null) || return "$RECOVERY_RC_INTERNAL"
  marker_dir_pre_chmod_stat=$(stat -Lc '%d:%i %F %u' -- "$marker_dir" 2>/dev/null) || return "$RECOVERY_RC_INTERNAL"
  read -r marker_dir_pre_chmod_dev_inode marker_dir_pre_chmod_kind marker_dir_pre_chmod_uid <<<"$marker_dir_pre_chmod_stat"
  [[ "$marker_dir_pre_chmod_realpath" == "$marker_dir" &&
     ! -L "$marker_dir" && -d "$marker_dir" &&
     "$marker_dir_pre_chmod_dev_inode" =~ ^[0-9]+:[0-9]+$ &&
     "$marker_dir_pre_chmod_kind" == directory &&
     "$marker_dir_pre_chmod_uid" == "$(id -u)" ]] || return "$RECOVERY_RC_INTERNAL"
  chmod 700 -- "$marker_dir" || {
    marker_dir_pre_chmod_entries=
    if marker_dir_current_realpath=$(realpath -- "$marker_dir" 2>/dev/null) &&
       [[ "$marker_dir_current_realpath" == "$marker_dir_pre_chmod_realpath" ]] &&
       [[ ! -L "$marker_dir" && -d "$marker_dir" ]] &&
       marker_dir_current_stat=$(stat -Lc '%d:%i %F %u' -- "$marker_dir" 2>/dev/null) &&
       read -r marker_dir_current_dev_inode marker_dir_current_kind marker_dir_current_uid <<<"$marker_dir_current_stat" &&
       [[ "$marker_dir_current_dev_inode" == "$marker_dir_pre_chmod_dev_inode" &&
          "$marker_dir_current_kind" == "$marker_dir_pre_chmod_kind" &&
          "$marker_dir_current_uid" == "$(id -u)" ]] &&
       marker_dir_pre_chmod_entries=$(find "$marker_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) &&
       [[ -z "$marker_dir_pre_chmod_entries" ]] &&
       rmdir -- "$marker_dir"; then
      :
    fi
    return "$RECOVERY_RC_INTERNAL"
  }
  marker_dir_realpath=$(realpath -- "$marker_dir" 2>/dev/null) || return "$RECOVERY_RC_INTERNAL"
  marker_dir_stat=$(stat -Lc '%d:%i %F %u %a' -- "$marker_dir" 2>/dev/null) || return "$RECOVERY_RC_INTERNAL"
  read -r marker_dir_dev_inode marker_dir_kind marker_dir_uid marker_dir_mode <<<"$marker_dir_stat"
  [[ "$marker_dir_realpath" == "$marker_dir" &&
     "$marker_dir_dev_inode" =~ ^[0-9]+:[0-9]+$ &&
     "$marker_dir_kind" == directory &&
     "$marker_dir_uid" == "$(id -u)" && "$marker_dir_mode" == 700 ]] || {
    return "$RECOVERY_RC_INTERNAL"
  }
  ready_file="$marker_dir/ready"
  outer_deadline=$((SECONDS + RECOVERY_SUPERVISOR_MAX_SECONDS))
  identity_deadline=$((SECONDS + RECOVERY_IDENTITY_MAX_SECONDS))
  marker_dir_identity_matches() {
    local current_realpath current_stat current_dev_inode current_kind current_uid current_mode
    [[ "$marker_dir" =~ ^/tmp/frp-xudp-recovery-marker\.[A-Za-z0-9]{6}$ ]] || return "$RECOVERY_RC_INTERNAL"
    [[ ! -L "$marker_dir" && -d "$marker_dir" ]] || return "$RECOVERY_RC_INTERNAL"
    current_realpath=$(realpath -- "$marker_dir" 2>/dev/null) || return "$RECOVERY_RC_INTERNAL"
    [[ "$current_realpath" == "$marker_dir_realpath" ]] || return "$RECOVERY_RC_INTERNAL"
    current_stat=$(stat -Lc '%d:%i %F %u %a' -- "$marker_dir" 2>/dev/null) || return "$RECOVERY_RC_INTERNAL"
    read -r current_dev_inode current_kind current_uid current_mode <<<"$current_stat"
    [[ "$current_dev_inode" == "$marker_dir_dev_inode" &&
       "$current_kind" == "$marker_dir_kind" &&
       "$current_uid" == "$marker_dir_uid" &&
       "$current_mode" == "$marker_dir_mode" &&
       "$current_kind" == directory && "$current_uid" == "$(id -u)" &&
       "$current_mode" == 700 ]] || return "$RECOVERY_RC_INTERNAL"
    return 0
  }
  marker_entry_is_safe() {
    local entry=$1 name entry_stat entry_kind entry_uid entry_links
    [[ "$entry" == "$marker_dir/"* ]] || return "$RECOVERY_RC_INTERNAL"
    name=${entry##*/}
    [[ "$name" == ready ||
       "$name" =~ ^ready\.tmp\.[1-9][0-9]*$ ||
       "$name" =~ ^ready\.body\.[1-9][0-9]*$ ]] || return "$RECOVERY_RC_INTERNAL"
    [[ ! -L "$entry" && -e "$entry" ]] || return "$RECOVERY_RC_INTERNAL"
    # %F may contain spaces (for example, "regular file"); keep the
    # fail-closed type/owner/link-count checks field-stable.
    entry_stat=$(stat -Lc '%F|%u|%h' -- "$entry" 2>/dev/null) || return "$RECOVERY_RC_INTERNAL"
    IFS='|' read -r entry_kind entry_uid entry_links <<<"$entry_stat"
    [[ "$entry_kind" == 'regular file' && "$entry_uid" == "$(id -u)" &&
       "$entry_links" == 1 ]] || return "$RECOVERY_RC_INTERNAL"
    return 0
  }
  cleanup_marker_dir() {
    local entry name
    local -a marker_entries=()
    marker_dir_identity_matches || return "$RECOVERY_RC_INTERNAL"
    for entry in "$marker_dir"/* "$marker_dir"/.[!.]* "$marker_dir"/..?*; do
      [[ -e "$entry" || -L "$entry" ]] || continue
      marker_entries+=("$entry")
    done
    for entry in "${marker_entries[@]}"; do
      marker_entry_is_safe "$entry" || return "$RECOVERY_RC_INTERNAL"
    done
    for entry in "${marker_entries[@]}"; do
      marker_dir_identity_matches || return "$RECOVERY_RC_INTERNAL"
      [[ -e "$entry" || -L "$entry" ]] || continue
      marker_entry_is_safe "$entry" || return "$RECOVERY_RC_INTERNAL"
      rm -f -- "$entry" || return "$RECOVERY_RC_INTERNAL"
      [[ ! -e "$entry" && ! -L "$entry" ]] || return "$RECOVERY_RC_INTERNAL"
    done
    marker_dir_identity_matches || return "$RECOVERY_RC_INTERNAL"
    rmdir -- "$marker_dir" || return "$RECOVERY_RC_INTERNAL"
    [[ ! -e "$marker_dir" && ! -L "$marker_dir" ]] || return "$RECOVERY_RC_INTERNAL"
  }
  cleanup_marker_dir_checked() {
    local cleanup_rc=0
    cleanup_marker_dir || cleanup_rc=$?
    if (( cleanup_rc != 0 )); then
      printf 'recovery marker cleanup could not be proved: dir=%s rc=%s\n' \
        "$marker_dir" "$cleanup_rc" >&2
      return "$RECOVERY_RC_INTERNAL"
    fi
    return 0
  }
  abort_inner_before_cleanup() {
    local reason=${1:-outer-abort} abort_rc=0
    abort_inner_checked "$reason" || abort_rc=$?
    trap - INT TERM HUP
    if (( abort_rc != 0 )); then
      return "$RECOVERY_RC_INTERNAL"
    fi
    cleanup_marker_dir_checked || return "$RECOVERY_RC_INTERNAL"
    return 0
  }
  finish_with_marker_cleanup() {
    trap - INT TERM HUP
    cleanup_marker_dir_checked || return "$RECOVERY_RC_INTERNAL"
    return 0
  }
  trap 'forward_inner_signal INT' INT
  trap 'forward_inner_signal TERM' TERM
  trap 'forward_inner_signal HUP' HUP
  # The outer supervisor never falls through to the report body.  It starts
  # one authenticated internal invocation; only that invocation reaches the
  # body below after validating the marker and the same held lock.
  read -r -d '' child_script <<'FRP_XUDP_RECOVERY_CHILD' || :
    set -Eeuo pipefail
    lock_path=$1
    ready_file=$2
    shift 2
    validate_lock_fd() {
      local before after fd_stat kind owner mode
      [[ ! -L "$lock_path" && -d "$lock_path" ]] || return 74
      before=$(stat -Lc '%d:%i %F %u %a' -- "$lock_path" 2>/dev/null) || return 74
      read -r _ kind owner mode <<<"$before"
      [[ "$kind" == directory && "$owner" == "$(id -u)" && "$mode" == 700 ]] || return 74
      exec 9<"$lock_path" || return 74
      fd_stat=$(stat -Lc '%d:%i %F %u %a' -- /proc/self/fd/9 2>/dev/null) || return 74
      after=$(stat -Lc '%d:%i %F %u %a' -- "$lock_path" 2>/dev/null) || return 74
      [[ "$before" == "$after" && "$before" == "$fd_stat" ]] || return 74
      LOCK_FD_STAT=$fd_stat
    }
    validate_lock_fd || {
      printf 'recovery lock path/fd identity validation failed\n' >&2
      exit "$RECOVERY_RC_INTERNAL"
    }
    if /usr/bin/flock -E 75 -n 9; then
      :
    else
      lock_rc=$?
      if (( lock_rc == 75 )); then
        exit 75
      fi
      exit "$RECOVERY_RC_INTERNAL"
    fi
    # FD9 remains bound to this inode.  A same-UID rename after validation is
    # outside the trust boundary; it cannot make FD9 follow a replacement.
    printf 'recovery_lock_binding=fd9:%s same_uid_rename_boundary=present\n' "$LOCK_FD_STAT" >&2
    business_pid=0
    business_pgid=0
    business_starttime=0
    business_reaped=0
    business_job_registered=0
    business_wait_rc=$RECOVERY_RC_INTERNAL
    successful_signal_rc=0
    supervisor_starttime=
    teardown=0
    term_sent=0
    kill_sent=0
    phase_ticks=0
    business_deadline=$((SECONDS + RECOVERY_SUPERVISOR_MAX_SECONDS))
    declare -a pending_signals=()

    child_exit_code() {
      local teardown_rc=$1 successful_signal_rc=$2 business_reaped=$3
      local business_wait_rc=$4 fallback_rc=$5 internal_rc=$6
      if (( teardown_rc != 0 )); then
        return "$internal_rc"
      fi
      if (( successful_signal_rc > 0 )); then
        return "$successful_signal_rc"
      fi
      if (( business_reaped )); then
        return "$business_wait_rc"
      fi
      return "$fallback_rc"
    }

    exit_child_with_code() {
      local exit_rc=0
      child_exit_code "$@" || exit_rc=$?
      exit "$exit_rc"
    }

    proc_snapshot() {
      local pid=${1:-} line rest state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime cutime cstime priority nice num_threads itrealvalue starttime proc_stat_fd
      [[ "$pid" =~ ^[0-9]+$ && "$pid" != 0 ]] || return 3
      [[ -e "/proc/$pid" ]] || return 2
      [[ -r "/proc/$pid/stat" ]] || {
        [[ ! -e "/proc/$pid/stat" ]] && return 2
        return 3
      }
      if ! { exec {proc_stat_fd}<"/proc/$pid/stat"; } 2>/dev/null; then
        [[ ! -e "/proc/$pid/stat" ]] && return 2
        return 3
      fi
      if ! { IFS= read -r -u "$proc_stat_fd" line; } 2>/dev/null; then
        exec {proc_stat_fd}<&-
        if [[ ! -e "/proc/$pid/stat" ]] || ! kill -0 "$pid" 2>/dev/null; then
          return 2
        fi
        return 3
      fi
      exec {proc_stat_fd}<&-
      if [[ "$line" != *") "* ]]; then
        if ! { exec {proc_stat_fd}<"/proc/$pid/stat"; } 2>/dev/null; then
          [[ ! -e "/proc/$pid/stat" ]] && return 2
          return 3
        fi
        if ! { IFS= read -r -u "$proc_stat_fd" line; } 2>/dev/null; then
          exec {proc_stat_fd}<&-
          if [[ ! -e "/proc/$pid/stat" ]] || ! kill -0 "$pid" 2>/dev/null; then
            return 2
          fi
          return 3
        fi
        exec {proc_stat_fd}<&-
        [[ "$line" == *") "* ]] || {
          [[ ! -e "/proc/$pid/stat" ]] && return 2
          return 3
        }
      fi
      rest=${line##*) }
      read -r state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime cutime cstime priority nice num_threads itrealvalue starttime _ <<<"$rest" || return 3
      [[ -n "$state" && -n "$pgrp" && -n "$starttime" ]] || {
        [[ ! -e "/proc/$pid/stat" ]] && return 2
        return 3
      }
      PROC_STATE=$state
      PROC_PGID=$pgrp
      PROC_STARTTIME=$starttime
      return 0
    }

    classify_process() {
      local pid=${1:-} snapshot_rc proc_dir_identity
      PROC_STATE=unknown
      [[ "$pid" =~ ^[0-9]+$ && "$pid" != 0 ]] || return 3
    if [[ ! -d "/proc/$pid" ]]; then
      # A process that has already disappeared is a known terminal state. The
      # caller still verifies the process group before declaring teardown safe.
      return 2
    fi
    proc_dir_identity=$(stat -Lc '%d:%i' -- "/proc/$pid" 2>/dev/null) || {
      [[ ! -d "/proc/$pid" ]] && return 2
      return 3
    }
      [[ "$proc_dir_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 3
      if proc_snapshot "$pid"; then
        [[ "$PROC_STATE" == Z* ]] && return 1
        return 0
      else
        snapshot_rc=$?
      fi
      [[ "$snapshot_rc" == 3 ]] && return 3
      [[ "$snapshot_rc" == 2 ]] && return 2
      return 3
    }

    job_state_for_pid() {
      local pid=${1:-} all running stopped
      [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 3
      [[ "$pid" == "$business_pid" && "$business_job_registered" == 1 ]] || return 3
      all=$(jobs -p 2>/dev/null) || return 3
      [[ $'\n'"$all"$'\n' == *$'\n'"$pid"$'\n'* ]] || return 3
      running=$(jobs -pr 2>/dev/null) || return 3
      [[ $'\n'"$running"$'\n' == *$'\n'"$pid"$'\n'* ]] && return 0
      stopped=$(jobs -ps 2>/dev/null) || return 3
      [[ $'\n'"$stopped"$'\n' == *$'\n'"$pid"$'\n'* ]] && return 1
      return 2
    }

    classify_group() {
      local entry pid snapshot_rc wanted_pgid=$1
      local live=0 zombie=0
      [[ "$wanted_pgid" =~ ^[0-9]+$ && "$wanted_pgid" -gt 0 ]] || return 3
      for entry in /proc/[0-9]*; do
        [[ -d "$entry" ]] || continue
        pid=${entry##*/}
        [[ -e "$entry/stat" ]] || continue
        if proc_snapshot "$pid"; then
          :
        else
          snapshot_rc=$?
          [[ $snapshot_rc == 2 ]] && continue
          GROUP_DIAGNOSTIC_PID=$pid
          return 3
        fi
        [[ "$PROC_PGID" == "$wanted_pgid" ]] || continue
        if [[ "$PROC_STATE" == Z* ]]; then
          zombie=1
        else
          live=1
        fi
      done
      if (( live )); then
        return 0
      fi
      if (( zombie )); then
        return 1
      fi
      return 2
    }

    supervisor_pid=$BASHPID
    proc_snapshot "$supervisor_pid" || exit "$RECOVERY_RC_INTERNAL"
    supervisor_pgid=$PROC_PGID
    supervisor_starttime=$PROC_STARTTIME
    publish_state() {
      local phase=$1 result_rc=${2:-0} tmp lock_inode fd_inode
      local tmp_umask tmp_noclobber=0 tmp_create_rc
      validate_recovery_marker_phase "$phase" "$result_rc" "$business_pid" \
        "$business_pgid" "$business_starttime" || return "$RECOVERY_RC_INTERNAL"
      lock_inode=$(stat -Lc '%d:%i' -- "$lock_path" 2>/dev/null) || return "$RECOVERY_RC_INTERNAL"
      fd_inode=$(stat -Lc '%d:%i' -- /proc/self/fd/9 2>/dev/null) || return "$RECOVERY_RC_INTERNAL"
      [[ "$lock_inode" == "$fd_inode" && "$lock_inode" == "${LOCK_FD_STAT%% *}" ]] || return "$RECOVERY_RC_INTERNAL"
      tmp="${ready_file}.tmp.${BASHPID}"
      tmp_umask=$(umask)
      case "$-" in *C*) tmp_noclobber=1 ;; esac
      umask 077
      set -C
      if : >"$tmp" 2>/dev/null; then
        tmp_create_rc=0
      else
        tmp_create_rc=$?
      fi
      (( tmp_noclobber )) || set +C
      umask "$tmp_umask"
      (( tmp_create_rc == 0 )) || return "$RECOVERY_RC_INTERNAL"
      {
        printf 'phase=%s\n' "$phase"
        printf 'lock_inode=%s\n' "$lock_inode"
        printf 'result_rc=%s\n' "$result_rc"
        printf 'supervisor_pid=%s\n' "$supervisor_pid"
        printf 'supervisor_pgid=%s\n' "$supervisor_pgid"
        printf 'supervisor_starttime=%s\n' "$supervisor_starttime"
        printf 'business_pid=%s\n' "$business_pid"
        printf 'business_pgid=%s\n' "$business_pgid"
        printf 'business_starttime=%s\n' "$business_starttime"
      } >"$tmp" || { rm -f -- "$tmp"; return "$RECOVERY_RC_INTERNAL"; }
      mv -f -- "$tmp" "$ready_file" || return "$RECOVERY_RC_INTERNAL"
      [[ -f "$ready_file" && ! -L "$ready_file" ]] || return "$RECOVERY_RC_INTERNAL"
    }
    publish_state supervisor-ready || {
      printf 'unable to publish authenticated recovery marker\n' >&2
      exit "$RECOVERY_RC_INTERNAL"
    }

    reap_business_if_finished() {
      local process_rc=0 job_rc=0
      (( business_reaped )) && return 0
      job_state_for_pid "$business_pid" || job_rc=$?
      case "$job_rc" in
        0|1) return 1 ;;
        2) : ;;
        3)
          classify_process "$business_pid" || process_rc=$?
          case "$process_rc" in
            0) return 1 ;;
            1) : ;;
            *) return 3 ;;
          esac
          ;;
        *) return 3 ;;
      esac
      if wait "$business_pid"; then
        business_wait_rc=0
      else
        business_wait_rc=$?
      fi
      business_reaped=1
      return 0
    }

    queue_signal() {
      case "$1" in
        INT|TERM|HUP) : ;;
        *) return 2 ;;
      esac
      pending_signals+=("$1")
      teardown=1
    }

    validate_business_group_identity() {
      local process_rc=0 group_rc=0
      (( business_pid > 0 && business_pgid > 0 )) || return 1
      proc_snapshot "$business_pid" || {
        process_rc=$?
        return 1
      }
      [[ "$PROC_STATE" != Z* &&
         "$PROC_STARTTIME" == "$business_starttime" &&
         "$PROC_PGID" == "$business_pgid" &&
         "$business_pgid" == "$business_pid" ]] || return 1
      classify_group "$business_pgid" || group_rc=$?
      (( group_rc == 0 )) || return 1
      # classify_group is a snapshot over /proc.  Revalidate the authenticated
      # leader after that scan and immediately before callers signal the PGID.
      proc_snapshot "$business_pid" || return 1
      [[ "$PROC_STATE" != Z* &&
         "$PROC_STARTTIME" == "$business_starttime" &&
         "$PROC_PGID" == "$business_pgid" &&
         "$business_pgid" == "$business_pid" ]] || return 1
      return 0
    }

    flush_pending_signals() {
      local signal signal_rc
      while ((${#pending_signals[@]} > 0)); do
        signal=${pending_signals[0]}
        # Re-read the leader identity immediately before every delivery.  A
        # queued signal must remain queued if the leader or its PGID is gone,
        # reused, unknown, or no longer has a live non-zombie group member.
        validate_business_group_identity || return 1
        if ! kill -"$signal" -- "-$business_pgid" 2>/dev/null; then
          return 1
        fi
        case "$signal" in
          INT) signal_rc=130 ;;
          TERM) signal_rc=143 ;;
          HUP) signal_rc=129 ;;
        esac
        (( successful_signal_rc > 0 )) || successful_signal_rc=$signal_rc
        pending_signals=("${pending_signals[@]:1}")
      done
      return 0
    }

    handle_signal() {
      local signal=$1
      # Bash runs traps synchronously between commands.  Queue first so a
      # transient identity failure cannot lose the request.  Once the stable
      # business identity has been published, attempt delivery in the trap
      # before an interrupted foreground command can be acted on by errexit.
      queue_signal "$signal" || return 0
      if (( business_pid > 0 && business_pgid > 0 && business_starttime > 0 )); then
        if flush_pending_signals; then
          printf 'inner supervisor forwarded queued signal=%s business_pid=%s business_pgid=%s\n' \
            "$signal" "$business_pid" "$business_pgid" >&2 || true
        else
          printf 'inner supervisor retained queued signal=%s after identity-checked delivery failure\n' \
            "$signal" >&2 || true
        fi
      fi
      return 0
    }

    signal_business_group() {
      # Teardown signals use the same immediate leader/PGID identity check as
      # queued signals; never signal a PGID after its leader has disappeared.
      validate_business_group_identity || return 1
      kill -"$1" -- "-$business_pgid" 2>/dev/null
    }

    bounded_teardown() {
      local reason=${1:-teardown} ticks=0 process_rc=0 group_rc=0
      local term_sent=0 kill_sent=0 unknown_observed=0
      while (( ticks < 400 )); do
        process_rc=0
        classify_process "$business_pid" || process_rc=$?
        group_rc=0
        classify_group "$business_pgid" || group_rc=$?
        (( process_rc == 3 || group_rc == 3 )) && unknown_observed=1
        if (( process_rc == 1 || process_rc == 2 )); then
          reap_business_if_finished || true
          if (( group_rc == 1 || group_rc == 2 )); then
            return 0
          fi
        fi
        if (( group_rc == 1 || group_rc == 2 )); then
          if (( process_rc == 0 )); then
            printf 'recovery teardown: child remains without a live group\n' >&2 || true
            signal_business_group KILL || true
          elif (( process_rc == 3 )); then
            :
          else
            return 0
          fi
        elif (( ! term_sent )); then
          if signal_business_group TERM; then
            term_sent=1
          fi
        elif (( ! kill_sent && ticks >= 200 )); then
          if signal_business_group KILL; then
            kill_sent=1
          fi
        fi
        /bin/sleep 0.01 || {
          sleep_rc=$?
          case "$sleep_rc" in
            129|130|143) continue ;;
            *) exit "$RECOVERY_RC_INTERNAL" ;;
          esac
        }
        ticks=$((ticks + 1))
      done
      # Unknown, live, and unreaped states are failures.  The final KILL is
      # identity checked; wait is attempted only after zombie/gone proof.
      signal_business_group KILL || true
      process_rc=0
      classify_process "$business_pid" || process_rc=$?
      if (( process_rc == 1 || process_rc == 2 )); then
        reap_business_if_finished || true
      fi
      if (( unknown_observed )); then
        printf 'recovery supervisor bounded teardown could not prove teardown reason=%s pid=%s pgid=%s\n' \
          "$reason" "$business_pid" "$business_pgid" >&2 || true
      fi
      printf 'recovery teardown timed out or remained unknown; rc=%s\n' "$RECOVERY_RC_INTERNAL" >&2 || true
      return "$RECOVERY_RC_INTERNAL"
    }

    trap 'handle_signal INT' INT
    trap 'handle_signal TERM' TERM
    trap 'handle_signal HUP' HUP

    # Bash ignores SIGINT for asynchronous commands.  Reset dispositions in a
    # short exec wrapper, then close all descriptors naming the lock directory.
    read -r -d '' business_script <<'FRP_XUDP_BUSINESS_CHILD' || :
      trap - INT TERM HUP
      lock_path=$1
      shift
      for fd in /proc/$$/fd/*; do
        target=$(readlink -- "$fd" 2>/dev/null || true)
        if [[ "$target" == "$lock_path" ]]; then
          fd_number=${fd##*/}
          [[ "$fd_number" =~ ^[0-9]+$ ]] || continue
          if ! eval "exec ${fd_number}>&-"; then
            printf 'failed to close inherited lock fd\n' >&2
            exit 74
          fi
        fi
      done
      exec "$@"
FRP_XUDP_BUSINESS_CHILD
    FRP_XUDP_INTERNAL_READY_FILE="$ready_file" \
      /usr/bin/env --default-signal=INT --default-signal=TERM --default-signal=HUP \
      /usr/bin/setsid /bin/bash -c "$business_script" _ "$lock_path" "$@" 9>&- &
    business_pid=$!
    business_job_registered=1
    if proc_snapshot "$business_pid"; then
      business_starttime=$PROC_STARTTIME
    else
      printf 'business startup identity could not be observed before marker publication\n' >&2
      exit "$RECOVERY_RC_INTERNAL"
    fi
    publish_state business-starting || {
      printf 'unable to publish business startup identity\n' >&2
      exit "$RECOVERY_RC_INTERNAL"
    }

    for ((i = 0; i < 100; i++)); do
      if classify_process "$business_pid"; then
        if [[ "$PROC_PGID" == "$business_pid" ]]; then
          business_pgid=$business_pid
          business_starttime=$PROC_STARTTIME
          publish_state business-ready || {
            printf 'unable to publish stable business identity\n' >&2
            exit "$RECOVERY_RC_INTERNAL"
          }
          break
        fi
      else
        process_rc=$?
        [[ $process_rc == 3 ]] && {
          printf 'business child state unknown during startup\n' >&2
          teardown_rc=0
          bounded_teardown child-start-unknown || teardown_rc=$?
          exit_child_with_code "$teardown_rc" "$successful_signal_rc" \
            "$business_reaped" "$business_wait_rc" "$RECOVERY_RC_INTERNAL" \
            "$RECOVERY_RC_INTERNAL"
        }
        [[ $process_rc == 1 || $process_rc == 2 ]] && break
      fi
      /bin/sleep 0.01 || {
        sleep_rc=$?
        case "$sleep_rc" in
          129|130|143) continue ;;
          *) exit "$RECOVERY_RC_INTERNAL" ;;
        esac
      }
    done
    if (( business_pgid == 0 )); then
      printf 'business process group was not established; beginning bounded child reap\n' >&2 || true
      if classify_process "$business_pid"; then
        teardown_rc=0
        bounded_teardown child-group-not-established-live || teardown_rc=$?
        exit_child_with_code "$teardown_rc" "$successful_signal_rc" \
          "$business_reaped" "$business_wait_rc" "$RECOVERY_RC_INTERNAL" \
          "$RECOVERY_RC_INTERNAL"
      else
        process_rc=$?
        if [[ $process_rc == 1 || $process_rc == 2 ]]; then
          reap_business_if_finished || true
          printf 'business process group was not established; releasing lock with rc=%s\n' \
            "$RECOVERY_RC_INTERNAL" >&2 || true
          (( successful_signal_rc > 0 )) && exit "$successful_signal_rc"
          (( business_wait_rc != 0 )) && exit "$business_wait_rc"
          exit "$RECOVERY_RC_INTERNAL"
        fi
        printf 'business process group was not established and state is unknown\n' >&2 || true
        exit "$RECOVERY_RC_INTERNAL"
      fi
    fi

    if ! flush_pending_signals; then
      teardown_rc=0
      bounded_teardown signal-forward-failed || teardown_rc=$?
      exit_child_with_code "$teardown_rc" "$successful_signal_rc" \
        "$business_reaped" "$business_wait_rc" "$RECOVERY_RC_INTERNAL" \
        "$RECOVERY_RC_INTERNAL"
    fi

    while (( SECONDS < business_deadline )); do
      if classify_process "$business_pid"; then
        process_rc=0
      else
        process_rc=$?
      fi
      if (( process_rc == 3 )); then
        teardown_rc=0
        bounded_teardown child-state-unknown || teardown_rc=$?
        exit_child_with_code "$teardown_rc" "$successful_signal_rc" \
          "$business_reaped" "$business_wait_rc" "$RECOVERY_RC_INTERNAL" \
          "$RECOVERY_RC_INTERNAL"
      fi

      if (( business_reaped )); then
        if classify_group "$business_pgid"; then
          group_rc=0
        else
          group_rc=$?
        fi
        if [[ $group_rc == 3 || $group_rc == 0 ]]; then
          teardown_rc=0
          bounded_teardown child-reaped-with-live-group || teardown_rc=$?
          exit_child_with_code "$teardown_rc" "$successful_signal_rc" \
            "$business_reaped" "$business_wait_rc" "$RECOVERY_RC_INTERNAL" \
            "$RECOVERY_RC_INTERNAL"
        fi
        trap - INT TERM HUP
        (( successful_signal_rc > 0 )) && exit "$successful_signal_rc"
        exit "$business_wait_rc"
      fi

      if classify_group "$business_pgid"; then
        group_rc=0
      else
        group_rc=$?
      fi
      if (( group_rc == 3 )); then
        teardown_rc=0
        bounded_teardown group-state-unknown || teardown_rc=$?
        exit_child_with_code "$teardown_rc" "$successful_signal_rc" \
          "$business_reaped" "$business_wait_rc" "$RECOVERY_RC_INTERNAL" \
          "$RECOVERY_RC_INTERNAL"
      fi
      if (( process_rc == 2 )) && (( group_rc == 0 )); then
        teardown_rc=0
        bounded_teardown child-gone-with-live-group || teardown_rc=$?
        exit_child_with_code "$teardown_rc" "$successful_signal_rc" \
          "$business_reaped" "$business_wait_rc" "$RECOVERY_RC_INTERNAL" \
          "$RECOVERY_RC_INTERNAL"
      fi
      if (( process_rc == 2 || process_rc == 1 )); then
        if (( group_rc == 0 )); then
          teardown=1
        fi
        if (( group_rc != 0 )); then
          teardown_rc=0
          bounded_teardown child-exited || teardown_rc=$?
          exit_child_with_code "$teardown_rc" "$successful_signal_rc" \
            "$business_reaped" "$business_wait_rc" "$RECOVERY_RC_INTERNAL" \
            "$RECOVERY_RC_INTERNAL"
        fi
      fi

      if (( teardown )); then
        if ! flush_pending_signals; then
          teardown_rc=0
          bounded_teardown signal-forward-failed || teardown_rc=$?
          exit_child_with_code "$teardown_rc" "$successful_signal_rc" \
            "$business_reaped" "$business_wait_rc" "$RECOVERY_RC_INTERNAL" \
            "$RECOVERY_RC_INTERNAL"
        fi
        teardown_rc=0
        bounded_teardown requested-signal || teardown_rc=$?
        exit_child_with_code "$teardown_rc" "$successful_signal_rc" \
          "$business_reaped" "$business_wait_rc" "$RECOVERY_RC_INTERNAL" \
          "$RECOVERY_RC_INTERNAL"
      fi
      /bin/sleep 0.01 || {
        sleep_rc=$?
        case "$sleep_rc" in
          129|130|143) continue ;;
          *) exit "$RECOVERY_RC_INTERNAL" ;;
        esac
      }
    done
    printf 'recovery supervisor total deadline reached; publishing timeout\n' >&2 || true
    publish_state timeout "$RECOVERY_RC_TIMEOUT" || true
    teardown_rc=0
    bounded_teardown total-runtime-timeout || teardown_rc=$?
    reap_business_if_finished || true
    if (( teardown_rc != 0 )); then
      exit "$RECOVERY_RC_INTERNAL"
    fi
    exit "$RECOVERY_RC_TIMEOUT"
FRP_XUDP_RECOVERY_CHILD
  # The inner supervisor is a new bash process, so outer functions are not
  # inherited.  Inject the one authoritative validator definition instead of
  # maintaining a second copy in the heredoc.  Its only external dependency,
  # RECOVERY_RC_TIMEOUT, is assigned and exported before this function runs.
  local marker_validator_definition
  marker_validator_definition=$(declare -f validate_recovery_marker_phase) || {
    printf 'unable to serialize recovery marker validator\n' >&2
    return "$RECOVERY_RC_INTERNAL"
  }
  [[ "$marker_validator_definition" == validate_recovery_marker_phase* ]] || {
    printf 'serialized recovery marker validator has an unexpected name\n' >&2
    return "$RECOVERY_RC_INTERNAL"
  }
  local inner_recovery_constants
  inner_recovery_constants=$(printf \
    'RECOVERY_RC_INTERNAL=%q\nexport RECOVERY_RC_INTERNAL\nRECOVERY_RC_TIMEOUT=%q\nexport RECOVERY_RC_TIMEOUT\nRECOVERY_SUPERVISOR_MAX_SECONDS=%q\nexport RECOVERY_SUPERVISOR_MAX_SECONDS\nRECOVERY_IDENTITY_MAX_SECONDS=%q\nexport RECOVERY_IDENTITY_MAX_SECONDS\n' \
    "$RECOVERY_RC_INTERNAL" "$RECOVERY_RC_TIMEOUT" \
    "$RECOVERY_SUPERVISOR_MAX_SECONDS" "$RECOVERY_IDENTITY_MAX_SECONDS") || {
    printf 'unable to serialize recovery constants\n' >&2
    return "$RECOVERY_RC_INTERNAL"
  }
  # Keep the validator first: the test-only probe removes exactly this
  # function to reproduce the historical command-not-found failure.  The
  # constants follow it and make the generated inner shell self-contained.
  child_script="${marker_validator_definition}"$'\n'"${inner_recovery_constants}"$'\n'"${child_script}"

  # This test-only export path lets the script test the exact generated inner
  # supervisor without entering the Docker/report body.  It emits only after
  # the marker directory was created and validated, then proves cleanup.
  if [[ ${FRP_XUDP_TEST_DUMP_INNER_SCRIPT:-0} == 1 ]]; then
    finish_with_marker_cleanup || return "$RECOVERY_RC_INTERNAL"
    printf '%s\n' "$child_script"
    return 0
  fi
  /usr/bin/env --default-signal=INT --default-signal=TERM --default-signal=HUP \
    /usr/bin/setsid /bin/bash -c "$child_script" _ "$RECOVERY_LOCK_PATH" "$ready_file" "$SCRIPT_PATH" "$INTERNAL_MARKER" "${ORIGINAL_ARGS[@]}" &
  INNER_PID=$!
  INNER_JOB_REGISTERED=1

  # setsid creates the supervisor process group.  Never use a blocking wait
  # while discovering it; an unknown /proc result is a hard failure.
  for ((i = 0; i < 100; i++)); do
    if classify_process "$INNER_PID"; then
      INNER_STARTTIME=$PROC_STARTTIME
      if [[ "$PROC_PGID" == "$INNER_PID" ]]; then
        INNER_PGID=$INNER_PID
        group_ready=1
        break
      fi
    else
      process_rc=$?
      [[ $process_rc == 3 ]] && {
        printf 'inner supervisor state unknown during startup: pid=%s\n' "$INNER_PID" >&2
        if ! abort_inner_before_cleanup startup-state-unknown; then
          return "$RECOVERY_RC_INTERNAL"
        fi
        return "$RECOVERY_RC_INTERNAL"
      }
      [[ $process_rc == 1 || $process_rc == 2 ]] && break
    fi
    /bin/sleep 0.01
  done
  if (( ! group_ready )); then
    INNER_PGID=0
    if ! abort_inner_before_cleanup startup-pgid-timeout; then
      return "$RECOVERY_RC_INTERNAL"
    fi
    return "$RECOVERY_RC_INTERNAL"
  fi
  if ! outer_flush_pending_signals; then
    if ! abort_inner_before_cleanup startup-signal-forward-failed; then
      return "$RECOVERY_RC_INTERNAL"
    fi
    return "$RECOVERY_RC_INTERNAL"
  fi

  # Poll the supervisor and group.  We wait only after /proc proves zombie or
  # gone; no signal-driven wait timeout is used.
  while (( SECONDS < outer_deadline )); do
    if classify_process "$INNER_PID"; then
      process_rc=0
    else
      process_rc=$?
    fi
    # A supervisor that is being interrupted can briefly expose an incomplete
    # /proc snapshot while transitioning to zombie/gone.  Retry only this
    # observation a bounded number of times; a persistent unknown state must
    # still abort fail-closed and retain the marker.
    if (( process_rc == 3 )); then
      for ((retry = 0; retry < 3 && process_rc == 3; retry++)); do
        /bin/sleep 0.01
        if classify_process "$INNER_PID"; then
          process_rc=0
        else
          process_rc=$?
        fi
      done
    fi
    [[ $process_rc == 3 ]] && {
      printf 'inner supervisor state unknown: pid=%s pgid=%s\n' "$INNER_PID" "$INNER_PGID" >&2
      if ! abort_inner_before_cleanup outer-state-unknown; then
        return "$RECOVERY_RC_INTERNAL"
      fi
      return "$RECOVERY_RC_INTERNAL"
    }
    if (( process_rc == 0 )); then
      if (( INNER_PGID > 0 )); then
        if outer_group_state "$INNER_PGID"; then
          group_rc=0
        else
          group_rc=$?
        fi
        [[ $group_rc == 3 ]] && {
          printf 'inner supervisor group state unknown: pgid=%s\n' "$INNER_PGID" >&2
          if ! abort_inner_before_cleanup outer-group-state-unknown; then
            return "$RECOVERY_RC_INTERNAL"
          fi
          return "$RECOVERY_RC_INTERNAL"
        }
      fi
      if (( ! identity_published )); then
        if [[ -f "$ready_file" ]] && read_recovery_state "$ready_file"; then
          case "$RECOVERY_STATE_PHASE" in
            business-ready|business-exited|body-running|body-success|body-failed|timeout)
              identity_published=1
              ;;
          esac
        fi
        if (( ! identity_published && SECONDS >= identity_deadline )); then
          printf 'inner supervisor identity publication timed out\n' >&2
          if ! abort_inner_before_cleanup identity-publication-timeout; then
            return "$RECOVERY_RC_INTERNAL"
          fi
          return "$RECOVERY_RC_INTERNAL"
        fi
      fi
      if ! outer_flush_pending_signals; then
        if ! abort_inner_before_cleanup signal-forward-failed; then
          return "$RECOVERY_RC_INTERNAL"
        fi
        return "$RECOVERY_RC_INTERNAL"
      fi
      /bin/sleep 0.01
      continue
    fi
    if reap_inner_if_finished; then
      reap_rc=0
    else
      reap_rc=$?
    fi
    case "$reap_rc" in
      0)
        wait_status=$OUTER_CHILD_WAIT_RC
        ;;
      1)
        /bin/sleep 0.01
        continue
        ;;
      3)
        printf 'inner supervisor reap state unknown: pid=%s\n' "$INNER_PID" >&2
        if ! abort_inner_before_cleanup reap-state-unknown; then
          return "$RECOVERY_RC_INTERNAL"
        fi
        return "$RECOVERY_RC_INTERNAL"
        ;;
      *)
        printf 'inner supervisor reap returned unexpected rc=%s: pid=%s\n' \
          "$reap_rc" "$INNER_PID" >&2
        if ! abort_inner_before_cleanup reap-state-unexpected; then
          return "$RECOVERY_RC_INTERNAL"
        fi
        return "$RECOVERY_RC_INTERNAL"
        ;;
    esac
    if (( INNER_PGID > 0 )); then
      if outer_group_state "$INNER_PGID"; then
        group_rc=0
      else
        group_rc=$?
      fi
      if (( group_rc != 2 )); then
        printf 'inner supervisor exited without proving group teardown; retaining marker: pid=%s pgid=%s state=%s\n' \
          "$INNER_PID" "$INNER_PGID" "$group_rc" >&2
        return "$RECOVERY_RC_INTERNAL"
      fi
    fi
    if ! read_recovery_state "$ready_file"; then
      # A directly registered inner child may exit before publishing a marker
      # (for example, the authenticated lock-busy path).  Once wait(2) has
      # returned its non-zero status and the child's original process group is
      # proved empty, preserve that child result.  No signal is sent on this
      # path; a zero result, an unknown/non-empty/reused group, or an
      # unreaped child remains fail-closed.
      if (( INNER_JOB_REGISTERED && INNER_REAPED && wait_status != 0 &&
            INNER_PGID > 0 && group_rc == 2 )); then
        if ! finish_with_marker_cleanup; then
          return "$RECOVERY_RC_INTERNAL"
        fi
        return "$wait_status"
      fi
      printf 'inner supervisor exited with unknown child identity state; no signal sent\n' >&2
      if ! abort_inner_before_cleanup state-publication-failed; then
        return "$RECOVERY_RC_INTERNAL"
      fi
      return "$RECOVERY_RC_INTERNAL"
    fi
    if [[ "$RECOVERY_STATE_SUPERVISOR_PID" != "$INNER_PID" ||
          ( "$INNER_STARTTIME" != 0 && "$RECOVERY_STATE_SUPERVISOR_STARTTIME" != "$INNER_STARTTIME" ) ||
          ( "$INNER_PGID" != 0 && "$RECOVERY_STATE_SUPERVISOR_PGID" != "$INNER_PGID" ) ]]; then
      printf 'inner supervisor identity state does not match observed process\n' >&2
      if ! abort_inner_before_cleanup state-identity-mismatch; then
        return "$RECOVERY_RC_INTERNAL"
      fi
      return "$RECOVERY_RC_INTERNAL"
    fi
    case "$RECOVERY_STATE_PHASE" in
      body-success)
        (( wait_status == 0 )) || {
          if ! finish_with_marker_cleanup; then
            return "$RECOVERY_RC_INTERNAL"
          fi
          return "$wait_status"
        }
        if ! finish_with_marker_cleanup; then
          return "$RECOVERY_RC_INTERNAL"
        fi
        return 0
        ;;
      body-failed)
        if ! finish_with_marker_cleanup; then
          return "$RECOVERY_RC_INTERNAL"
        fi
        if (( RECOVERY_STATE_RESULT_RC > 0 )); then
          return "$RECOVERY_STATE_RESULT_RC"
        fi
        return "$RECOVERY_RC_INTERNAL"
        ;;
      timeout)
        if ! finish_with_marker_cleanup; then
          return "$RECOVERY_RC_INTERNAL"
        fi
        return "$RECOVERY_RC_TIMEOUT"
        ;;
      supervisor-ready|business-starting|business-ready|business-exited|body-running)
        if (( RECOVERY_STATE_BUSINESS_PID > 0 )); then
          recover_unpublished_business "$ready_file" "$RECOVERY_STATE_PHASE" \
            "$RECOVERY_STATE_BUSINESS_PID" "$RECOVERY_STATE_BUSINESS_PGID" \
            "$RECOVERY_STATE_BUSINESS_STARTTIME" || wait_status=$?
          if (( wait_status != 0 )); then
            if ! finish_with_marker_cleanup; then
              return "$RECOVERY_RC_INTERNAL"
            fi
            return "$wait_status"
          fi
        fi
        if (( wait_status == 0 )); then
          printf 'inner supervisor ended before the report body completed\n' >&2
          wait_status=$RECOVERY_RC_INTERNAL
        fi
        ;;
      *)
        printf 'inner supervisor published unsupported phase=%s\n' "$RECOVERY_STATE_PHASE" >&2
        wait_status=$RECOVERY_RC_INTERNAL
        ;;
    esac
    if ! finish_with_marker_cleanup; then
      return "$RECOVERY_RC_INTERNAL"
    fi
    return "$wait_status"
  done
  printf 'outer supervisor total deadline reached; terminating inner supervisor\n' >&2
  if ! abort_inner_before_cleanup outer-runtime-timeout; then
    return "$RECOVERY_RC_INTERNAL"
  fi
  return "$RECOVERY_RC_TIMEOUT"
}

if (( SHOW_HELP )); then
  if (( INTERNAL_MODE )); then
    validate_internal_lock_holder
  fi
  usage
  exit 0
fi

if (( INTERNAL_MODE )); then
  validate_internal_lock_holder
else
  validate_recovery_lock_dir
  trap 'forward_inner_signal INT' INT
  trap 'forward_inner_signal TERM' TERM
  trap 'forward_inner_signal HUP' HUP
  run_locked_child
  trap - INT TERM HUP
  exit $?
fi

INTERNAL_STATE_FILE=${FRP_XUDP_INTERNAL_READY_FILE-}
publish_body_phase() {
  local phase=$1 result_rc=${2:-0} tmp
  local lock_inode tmp_umask tmp_noclobber=0 tmp_create_rc
  (( INTERNAL_MODE )) || return 0
  read_recovery_state "$INTERNAL_STATE_FILE" || return 1
  lock_inode=$(stat -Lc '%d:%i' -- "$RECOVERY_LOCK_PATH" 2>/dev/null) || return 1
  [[ "$lock_inode" == "$RECOVERY_STATE_LOCK_INODE" ]] || return 1
  tmp="${INTERNAL_STATE_FILE}.body.${BASHPID}"
  tmp_umask=$(umask)
  case "$-" in *C*) tmp_noclobber=1 ;; esac
  umask 077
  set -C
  if : >"$tmp" 2>/dev/null; then
    tmp_create_rc=0
  else
    tmp_create_rc=$?
  fi
  (( tmp_noclobber )) || set +C
  umask "$tmp_umask"
  (( tmp_create_rc == 0 )) || return 1
  {
    printf 'phase=%s\n' "$phase"
    printf 'lock_inode=%s\n' "$RECOVERY_STATE_LOCK_INODE"
    printf 'result_rc=%s\n' "$result_rc"
    printf 'supervisor_pid=%s\n' "$RECOVERY_STATE_SUPERVISOR_PID"
    printf 'supervisor_pgid=%s\n' "$RECOVERY_STATE_SUPERVISOR_PGID"
    printf 'supervisor_starttime=%s\n' "$RECOVERY_STATE_SUPERVISOR_STARTTIME"
    printf 'business_pid=%s\n' "$RECOVERY_STATE_BUSINESS_PID"
    printf 'business_pgid=%s\n' "$RECOVERY_STATE_BUSINESS_PGID"
    printf 'business_starttime=%s\n' "$RECOVERY_STATE_BUSINESS_STARTTIME"
  } >"$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$INTERNAL_STATE_FILE"
}

publish_body_phase body-running || {
  printf 'unable to publish body-running state\n' >&2
  exit "$RECOVERY_RC_INTERNAL"
}

xudp_collect_git_provenance "$ROOT"

create_report
exec {CONSOLE_OUT_FD}>&1
exec {CONSOLE_ERR_FD}>&2
exec 1>&${REPORT_FD} 2>&1
REPORT_READY=1

say() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" >&${CONSOLE_OUT_FD}
}

warn() {
  printf 'ERROR: %s\n' "$*"
  printf 'ERROR: %s\n' "$*" >&${CONSOLE_ERR_FD}
}

current_runtime_snapshot_dir() {
  local label=$1 path=$2 key realpath stat_line devino kind uid mode current_uid
  [[ "$label" =~ ^(root|bin|config|log)$ ]] || return 74
  [[ -d "$path" && ! -L "$path" ]] || return 74
  current_uid=$(id -u) || return 74
  realpath=$(realpath -e -- "$path") || return 74
  stat_line=$(LC_ALL=C stat -Lc '%d:%i|%F|%u|%a' -- "$path") || return 74
  IFS='|' read -r devino kind uid mode <<<"$stat_line"
  [[ -n "$realpath" && "$devino" =~ ^[0-9]+:[0-9]+$ &&
    "$kind" == directory && "$uid" == "$current_uid" && "$mode" == 700 ]] || return 74
  key=${label^^}
  printf -v "CURRENT_RUNTIME_${key}_REALPATH" '%s' "$realpath"
  printf -v "CURRENT_RUNTIME_${key}_DEVINO" '%s' "$devino"
  printf -v "CURRENT_RUNTIME_${key}_KIND" '%s' "$kind"
  printf -v "CURRENT_RUNTIME_${key}_UID" '%s' "$uid"
  printf -v "CURRENT_RUNTIME_${key}_MODE" '%s' "$mode"
}

runtime_path_valid() {
  [[ "${1:-}" =~ ^/tmp/frp-xudp-smoke\.[A-Za-z0-9]{6}$ ]]
}

current_runtime_identity_field() {
  local label=$1 key=${1^^} realpath devino kind uid mode
  local var_realpath=CURRENT_RUNTIME_${key}_REALPATH
  local var_devino=CURRENT_RUNTIME_${key}_DEVINO
  local var_kind=CURRENT_RUNTIME_${key}_KIND
  local var_uid=CURRENT_RUNTIME_${key}_UID
  local var_mode=CURRENT_RUNTIME_${key}_MODE
  realpath=${!var_realpath-}
  devino=${!var_devino-}
  kind=${!var_kind-}
  uid=${!var_uid-}
  mode=${!var_mode-}
  [[ "$label" =~ ^(root|bin|config|log)$ && -n "$realpath" &&
    "$realpath" != *[[:space:]]* && "$devino" =~ ^[0-9]+:[0-9]+$ &&
    "$kind" == directory && "$uid" =~ ^[0-9]+$ && "$mode" == 700 ]] || return 74
  printf '%s=%s,%s,%s,%s,%s' "$label" "$realpath" "$devino" "$kind" "$uid" "$mode"
}

current_runtime_identity_load() {
  local identity=$1 version root_field bin_field config_field log_field extra
  local label field payload path devino kind uid mode expected_path key
  [[ -n "$identity" && "$identity" != *[[:space:]]* ]] || return 74
  IFS='|' read -r version root_field bin_field config_field log_field extra <<<"$identity"
  [[ "$version" == v1 && -n "$root_field" && -n "$bin_field" &&
    -n "$config_field" && -n "$log_field" && -z "$extra" ]] || return 74
  for label in root bin config log; do
    case "$label" in
      root) field=$root_field; expected_path=/tmp/frp-xudp-smoke.XXXXXX ;;
      bin) field=$bin_field; expected_path=bin ;;
      config) field=$config_field; expected_path=config ;;
      log) field=$log_field; expected_path=log ;;
    esac
    [[ "$field" == "$label="* ]] || return 74
    payload=${field#*=}
    IFS=',' read -r path devino kind uid mode extra <<<"$payload"
    [[ -n "$path" && -n "$devino" && -n "$kind" && -n "$uid" &&
      -n "$mode" && -z "$extra" && "$devino" =~ ^[0-9]+:[0-9]+$ &&
      "$kind" == directory && "$uid" =~ ^[0-9]+$ && "$mode" == 700 ]] || return 74
    if [[ "$label" == root ]]; then
      runtime_path_valid "$path" || return 74
      CURRENT_RUNTIME_ROOT_REALPATH=$path
    else
      [[ "$path" == "$CURRENT_RUNTIME_ROOT_REALPATH/$expected_path" ]] || return 74
    fi
    key=${label^^}
    printf -v "CURRENT_RUNTIME_${key}_REALPATH" '%s' "$path"
    printf -v "CURRENT_RUNTIME_${key}_DEVINO" '%s' "$devino"
    printf -v "CURRENT_RUNTIME_${key}_KIND" '%s' "$kind"
    printf -v "CURRENT_RUNTIME_${key}_UID" '%s' "$uid"
    printf -v "CURRENT_RUNTIME_${key}_MODE" '%s' "$mode"
  done
  CURRENT_RUNTIME_IDENTITY=$identity
}

current_runtime_identity_build() {
  local root=$1 identity root_field bin_field config_field log_field
  runtime_path_valid "$root" || return 74
  root_field=$(current_runtime_identity_field root) || return 74
  bin_field=$(current_runtime_identity_field bin) || return 74
  config_field=$(current_runtime_identity_field config) || return 74
  log_field=$(current_runtime_identity_field log) || return 74
  identity="v1|$root_field|$bin_field|$config_field|$log_field"
  current_runtime_identity_load "$identity" || return 74
  CURRENT_RUNTIME_IDENTITY=$identity
}

current_runtime_verify_dir_identity() {
  local label=$1 path=$2 key expected_realpath expected_devino expected_kind
  local expected_uid expected_mode realpath stat_line devino kind uid mode current_uid
  local var_realpath var_devino var_kind var_uid var_mode
  [[ "$label" =~ ^(root|bin|config|log)$ ]] || return 74
  key=${label^^}
  var_realpath=CURRENT_RUNTIME_${key}_REALPATH
  var_devino=CURRENT_RUNTIME_${key}_DEVINO
  var_kind=CURRENT_RUNTIME_${key}_KIND
  var_uid=CURRENT_RUNTIME_${key}_UID
  var_mode=CURRENT_RUNTIME_${key}_MODE
  expected_realpath=${!var_realpath-}
  expected_devino=${!var_devino-}
  expected_kind=${!var_kind-}
  expected_uid=${!var_uid-}
  expected_mode=${!var_mode-}
  [[ -n "$expected_realpath" && -n "$expected_devino" &&
    -n "$expected_kind" && -n "$expected_uid" && -n "$expected_mode" ]] || return 74
  [[ -d "$path" && ! -L "$path" ]] || return 74
  current_uid=$(id -u) || return 74
  realpath=$(realpath -e -- "$path") || return 74
  stat_line=$(LC_ALL=C stat -Lc '%d:%i|%F|%u|%a' -- "$path") || return 74
  IFS='|' read -r devino kind uid mode <<<"$stat_line"
  [[ "$realpath" == "$expected_realpath" && "$devino" == "$expected_devino" &&
    "$kind" == "$expected_kind" && "$uid" == "$expected_uid" &&
    "$mode" == "$expected_mode" && "$uid" == "$current_uid" &&
    "$kind" == directory && "$mode" == 700 ]]
}

current_runtime_snapshot() {
  local root=$1 bin_dir=$2 config_dir=$3 log_dir=$4
  runtime_path_valid "$root" || return 74
  [[ "$bin_dir" == "$root/bin" && "$config_dir" == "$root/config" &&
    "$log_dir" == "$root/log" ]] || return 74
  current_runtime_snapshot_dir root "$root" || return 74
  current_runtime_snapshot_dir bin "$bin_dir" || return 74
  current_runtime_snapshot_dir config "$config_dir" || return 74
  current_runtime_snapshot_dir log "$log_dir" || return 74
  current_runtime_identity_build "$root" || return 74
}

current_runtime_static_file_lstat() {
  local path=$1 stat_line realpath kind uid nlink mode current_uid
  [[ "$path" == /* && ! -L "$path" ]] || return 74
  current_uid=$(id -u) || return 74
  stat_line=$(LC_ALL=C stat -c '%d:%i|%F|%u|%h|%a' -- "$path") || return 74
  IFS='|' read -r CURRENT_RUNTIME_STATIC_LSTAT_DEVINO \
    CURRENT_RUNTIME_STATIC_LSTAT_KIND CURRENT_RUNTIME_STATIC_LSTAT_UID \
    CURRENT_RUNTIME_STATIC_LSTAT_NLINK CURRENT_RUNTIME_STATIC_LSTAT_MODE <<<"$stat_line"
  realpath=$(realpath -e -- "$path") || return 74
  CURRENT_RUNTIME_STATIC_LSTAT_REALPATH=$realpath
  kind=$CURRENT_RUNTIME_STATIC_LSTAT_KIND
  uid=$CURRENT_RUNTIME_STATIC_LSTAT_UID
  nlink=$CURRENT_RUNTIME_STATIC_LSTAT_NLINK
  mode=$CURRENT_RUNTIME_STATIC_LSTAT_MODE
  [[ "$realpath" == /* && "$kind" == 'regular file' &&
    "$uid" == "$current_uid" && "$nlink" == 1 && "$mode" =~ ^[0-7]+$ ]]
}

current_runtime_snapshot_static_files() {
  local bin_dir=$1 config_dir=$2 root=$ACTIVE_TMP_DIR index key path before after hash
  local -a paths=(
    "$bin_dir/frps" "$bin_dir/frpc" "$bin_dir/udp_send" "$bin_dir/udp_echo"
    "$config_dir/frps.toml" "$config_dir/frpc.toml"
    "$config_dir/frpc-visitor.toml"
  )
  [[ -n "$root" && "$bin_dir" == "$root/bin" &&
    "$config_dir" == "$root/config" &&
    "$root" == "$CURRENT_RUNTIME_ROOT_REALPATH" ]] || return 74
  current_runtime_verify_dir_identity root "$root" || return 74
  current_runtime_verify_dir_identity bin "$bin_dir" || return 74
  current_runtime_verify_dir_identity config "$config_dir" || return 74
  current_runtime_verify_dir_identity log "$root/log" || return 74
  CURRENT_RUNTIME_STATIC_SNAPSHOT_READY=0
  for ((index = 0; index < ${#CURRENT_RUNTIME_STATIC_KEYS[@]}; index++)); do
    path=${paths[index]}
    current_runtime_static_file_lstat "$path" || return 74
    before="$CURRENT_RUNTIME_STATIC_LSTAT_REALPATH|$CURRENT_RUNTIME_STATIC_LSTAT_DEVINO|$CURRENT_RUNTIME_STATIC_LSTAT_KIND|$CURRENT_RUNTIME_STATIC_LSTAT_UID|$CURRENT_RUNTIME_STATIC_LSTAT_NLINK|$CURRENT_RUNTIME_STATIC_LSTAT_MODE"
    hash=$(xudp_sha256_file "$path" 2>/dev/null) || return 74
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 74
    current_runtime_static_file_lstat "$path" || return 74
    after="$CURRENT_RUNTIME_STATIC_LSTAT_REALPATH|$CURRENT_RUNTIME_STATIC_LSTAT_DEVINO|$CURRENT_RUNTIME_STATIC_LSTAT_KIND|$CURRENT_RUNTIME_STATIC_LSTAT_UID|$CURRENT_RUNTIME_STATIC_LSTAT_NLINK|$CURRENT_RUNTIME_STATIC_LSTAT_MODE"
    [[ "$before" == "$after" ]] || return 74
    key=${CURRENT_RUNTIME_STATIC_KEYS[index]}
    CURRENT_RUNTIME_STATIC_PATH["$key"]=$path
    CURRENT_RUNTIME_STATIC_REALPATH["$key"]=$CURRENT_RUNTIME_STATIC_LSTAT_REALPATH
    CURRENT_RUNTIME_STATIC_DEVINO["$key"]=$CURRENT_RUNTIME_STATIC_LSTAT_DEVINO
    CURRENT_RUNTIME_STATIC_KIND["$key"]=$CURRENT_RUNTIME_STATIC_LSTAT_KIND
    CURRENT_RUNTIME_STATIC_UID["$key"]=$CURRENT_RUNTIME_STATIC_LSTAT_UID
    CURRENT_RUNTIME_STATIC_NLINK["$key"]=$CURRENT_RUNTIME_STATIC_LSTAT_NLINK
    CURRENT_RUNTIME_STATIC_MODE["$key"]=$CURRENT_RUNTIME_STATIC_LSTAT_MODE
    CURRENT_RUNTIME_STATIC_SHA256["$key"]=$hash
  done
  CURRENT_RUNTIME_STATIC_SNAPSHOT_READY=1
}

current_runtime_verify_static_files() {
  local root=$ACTIVE_TMP_DIR index key path expected_path before after hash
  local -a paths=(
    "$root/bin/frps" "$root/bin/frpc" "$root/bin/udp_send" "$root/bin/udp_echo"
    "$root/config/frps.toml" "$root/config/frpc.toml"
    "$root/config/frpc-visitor.toml"
  )
  (( CURRENT_RUNTIME_STATIC_SNAPSHOT_READY == 1 )) || return 74
  for ((index = 0; index < ${#CURRENT_RUNTIME_STATIC_KEYS[@]}; index++)); do
    key=${CURRENT_RUNTIME_STATIC_KEYS[index]}
    path=${paths[index]}
    expected_path=${CURRENT_RUNTIME_STATIC_PATH[$key]-}
    [[ "$path" == "$expected_path" && "$path" == /* ]] || return 74
    current_runtime_static_file_lstat "$path" || return 74
    before="$CURRENT_RUNTIME_STATIC_LSTAT_REALPATH|$CURRENT_RUNTIME_STATIC_LSTAT_DEVINO|$CURRENT_RUNTIME_STATIC_LSTAT_KIND|$CURRENT_RUNTIME_STATIC_LSTAT_UID|$CURRENT_RUNTIME_STATIC_LSTAT_NLINK|$CURRENT_RUNTIME_STATIC_LSTAT_MODE"
    hash=$(xudp_sha256_file "$path" 2>/dev/null) || return 74
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 74
    current_runtime_static_file_lstat "$path" || return 74
    after="$CURRENT_RUNTIME_STATIC_LSTAT_REALPATH|$CURRENT_RUNTIME_STATIC_LSTAT_DEVINO|$CURRENT_RUNTIME_STATIC_LSTAT_KIND|$CURRENT_RUNTIME_STATIC_LSTAT_UID|$CURRENT_RUNTIME_STATIC_LSTAT_NLINK|$CURRENT_RUNTIME_STATIC_LSTAT_MODE"
    [[ "$before" == "$after" &&
      "$after" == "${CURRENT_RUNTIME_STATIC_REALPATH[$key]}|${CURRENT_RUNTIME_STATIC_DEVINO[$key]}|${CURRENT_RUNTIME_STATIC_KIND[$key]}|${CURRENT_RUNTIME_STATIC_UID[$key]}|${CURRENT_RUNTIME_STATIC_NLINK[$key]}|${CURRENT_RUNTIME_STATIC_MODE[$key]}" &&
      "$hash" == "${CURRENT_RUNTIME_STATIC_SHA256[$key]}" ]] || return 74
  done
}

current_runtime_verify_before_run() {
  local root=$ACTIVE_TMP_DIR
  current_runtime_preflight || return 74
  current_runtime_verify_static_files || return 74
  current_runtime_verify_dir_identity root "$root" || return 74
  current_runtime_verify_dir_identity bin "$root/bin" || return 74
  current_runtime_verify_dir_identity config "$root/config" || return 74
  current_runtime_verify_dir_identity log "$root/log" || return 74
}

current_runtime_validate_leaf() {
  local path=$1 allow_missing=${2:-0} stat_line kind uid nlink current_uid
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    (( allow_missing )) && return 0
    return 74
  fi
  [[ ! -L "$path" ]] || return 74
  current_uid=$(id -u) || return 74
  stat_line=$(LC_ALL=C stat -Lc '%F|%u|%h' -- "$path") || return 74
  IFS='|' read -r kind uid nlink <<<"$stat_line"
  [[ "$kind" == 'regular file' && "$uid" == "$current_uid" && "$nlink" == 1 ]]
}

current_runtime_preflight() {
  local allow_partial=${1:-0}
  local root=$ACTIVE_TMP_DIR bin_dir config_dir log_dir tree entry
  local -a entries=() leaves=() leaf_allow_missing=()
  [[ -n "$root" ]] || return 74
  bin_dir=$root/bin
  config_dir=$root/config
  log_dir=$root/log

  current_runtime_verify_dir_identity root "$root" || return 74
  current_runtime_verify_dir_identity bin "$bin_dir" || return 74
  current_runtime_verify_dir_identity config "$config_dir" || return 74
  current_runtime_verify_dir_identity log "$log_dir" || return 74

  if ! tree=$(find -P -- "$root" -mindepth 1 -print); then
    return 74
  fi
  if [[ -n "$tree" ]]; then
    while IFS= read -r entry; do
      entries+=("$entry")
    done <<<"$tree"
  fi
  for entry in "${entries[@]}"; do
    case "$entry" in
      "$bin_dir"|"$config_dir"|"$log_dir"|"$bin_dir/frps"|"$bin_dir/frpc"|"$bin_dir/udp_send"|"$bin_dir/udp_echo"|"$config_dir/frps.toml"|"$config_dir/frpc.toml"|"$config_dir/frpc-visitor.toml"|"$log_dir/frps.log"|"$log_dir/frpc.log"|"$log_dir/frpc-visitor.log"|"$log_dir/frpsA.log"|"$log_dir/frpcB.log"|"$log_dir/frpC.log") ;;
      *) return 74 ;;
    esac
  done

  leaves=(
    "$bin_dir/frps" "$bin_dir/frpc" "$bin_dir/udp_send" "$bin_dir/udp_echo"
    "$config_dir/frps.toml" "$config_dir/frpc.toml" "$config_dir/frpc-visitor.toml"
    "$log_dir/frps.log" "$log_dir/frpc.log" "$log_dir/frpc-visitor.log"
    # Compatibility leaves from runtimes created before log names were made
    # role-based. They remain exact optional allowlist entries.
    "$log_dir/frpsA.log" "$log_dir/frpcB.log" "$log_dir/frpC.log"
  )
  if (( allow_partial )); then
    leaf_allow_missing=(1 1 1 1 1 1 1 1 1 1 1 1 1)
  else
    leaf_allow_missing=(0 0 1 1 0 0 0 1 1 1 1 1 1)
  fi
  for ((entry = 0; entry < ${#leaves[@]}; entry++)); do
    current_runtime_validate_leaf "${leaves[entry]}" "${leaf_allow_missing[entry]}" || return 74
  done

  # Recheck all saved directory identities after enumeration and leaf checks,
  # immediately before any deletion is permitted.
  current_runtime_verify_dir_identity root "$root" || return 74
  current_runtime_verify_dir_identity bin "$bin_dir" || return 74
  current_runtime_verify_dir_identity config "$config_dir" || return 74
  current_runtime_verify_dir_identity log "$log_dir" || return 74
}

staged_runtime_validate_file() {
  local path=$1 role=$2 stat_line realpath kind uid nlink mode mode_value current_uid
  [[ "$path" == /* && ! -L "$path" && -f "$path" ]] || return 74
  realpath=$(realpath -e -- "$path") || return 74
  [[ "$realpath" == "$path" ]] || return 74
  current_uid=$(id -u) || return 74
  stat_line=$(LC_ALL=C stat -Lc '%F|%u|%h|%a' -- "$path") || return 74
  IFS='|' read -r kind uid nlink mode <<<"$stat_line"
  [[ "$kind" == 'regular file' && "$uid" == "$current_uid" &&
    "$nlink" == 1 && "$mode" =~ ^[0-7]+$ ]] || return 74
  mode_value=$((8#$mode))
  (( (mode_value & 022) == 0 )) || return 74
  case "$role" in
    binary)
      [[ -x "$path" && "$mode" == 555 ]] || return 74
      ;;
    frps-config)
      (( (mode_value & 0111) == 0 )) || return 74
      grep -Fqx 'bindAddr = "0.0.0.0"' -- "$path" || return 74
      grep -Fqx 'bindPort = 7000' -- "$path" || return 74
      grep -Fqx 'auth.method = "token"' -- "$path" || return 74
      grep -Fqx 'auth.token = "frp-test-token"' -- "$path" || return 74
      ;;
    frpc-config)
      (( (mode_value & 0111) == 0 )) || return 74
      grep -Fqx 'serverAddr = "frpsA"' -- "$path" || return 74
      grep -Fqx 'serverPort = 7000' -- "$path" || return 74
      grep -Fqx 'auth.method = "token"' -- "$path" || return 74
      grep -Fqx 'auth.token = "frp-test-token"' -- "$path" || return 74
      grep -Fqx '[[proxies]]' -- "$path" || return 74
      grep -Fqx 'type = "xudp"' -- "$path" || return 74
      grep -Fqx 'localIP = "127.0.0.1"' -- "$path" || return 74
      grep -Fqx 'localPort = 2000' -- "$path" || return 74
      ;;
    visitor-config)
      (( (mode_value & 0111) == 0 )) || return 74
      grep -Fqx 'serverAddr = "frpsA"' -- "$path" || return 74
      grep -Fqx 'serverPort = 7000' -- "$path" || return 74
      grep -Fqx 'auth.method = "token"' -- "$path" || return 74
      grep -Fqx 'auth.token = "frp-test-token"' -- "$path" || return 74
      grep -Fqx '[[visitors]]' -- "$path" || return 74
      grep -Fqx 'type = "xudp"' -- "$path" || return 74
      grep -Fqx 'bindAddr = "0.0.0.0"' -- "$path" || return 74
      grep -Fqx 'bindPort = 9000' -- "$path" || return 74
      ;;
    *) return 74 ;;
  esac
}

staged_runtime_preflight() {
  local root=$1 bin_dir=$2 config_dir=$3 log_dir=$4 key path expected_hash actual_hash
  local -a binaries=(frps frpc udp_send udp_echo)
  local -a configs=(frps.toml frpc.toml frpc-visitor.toml)
  local -a config_roles=(frps-config frpc-config visitor-config)
  [[ "$root" == "$ACTIVE_TMP_DIR" && "$bin_dir" == "$root/bin" &&
    "$config_dir" == "$root/config" && "$log_dir" == "$root/log" ]] || return 74

  # This is deliberately Docker-free.  It is the last complete staged-file
  # gate before any old container can be removed.
  current_runtime_preflight || return 74
  current_runtime_verify_static_files || return 74
  current_runtime_verify_dir_identity root "$root" || return 74
  current_runtime_verify_dir_identity bin "$bin_dir" || return 74
  current_runtime_verify_dir_identity config "$config_dir" || return 74
  current_runtime_verify_dir_identity log "$log_dir" || return 74

  for key in "${binaries[@]}"; do
    staged_runtime_validate_file "$bin_dir/$key" binary || return 74
  done
  for ((key = 0; key < ${#configs[@]}; key++)); do
    staged_runtime_validate_file "$config_dir/${configs[key]}" "${config_roles[key]}" || return 74
  done

  for key in "${CURRENT_RUNTIME_STATIC_KEYS[@]}"; do
    expected_hash=${CURRENT_RUNTIME_STATIC_SHA256[$key]-}
    [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || return 74
    case "$key" in
      frps|frpc|udp_send|udp_echo) path="$bin_dir/$key" ;;
      frps_config) path="$config_dir/frps.toml" ;;
      frpc_config) path="$config_dir/frpc.toml" ;;
      visitor_config) path="$config_dir/frpc-visitor.toml" ;;
      *) return 74 ;;
    esac
    actual_hash=$(xudp_sha256_file "$path") || return 74
    [[ "$actual_hash" == "$expected_hash" ]] || return 74
  done

  [[ "$FRPS_SHA256" == "${CURRENT_RUNTIME_STATIC_SHA256[frps]}" &&
    "$FRPC_SHA256" == "${CURRENT_RUNTIME_STATIC_SHA256[frpc]}" &&
    "$UDP_SEND_SHA256" == "${CURRENT_RUNTIME_STATIC_SHA256[udp_send]}" &&
    "$UDP_ECHO_SHA256" == "${CURRENT_RUNTIME_STATIC_SHA256[udp_echo]}" &&
    "$FRPS_CONFIG_SHA256" == "${CURRENT_RUNTIME_STATIC_SHA256[frps_config]}" &&
    "$FRPC_CONFIG_SHA256" == "${CURRENT_RUNTIME_STATIC_SHA256[frpc_config]}" &&
    "$VISITOR_CONFIG_SHA256" == "${CURRENT_RUNTIME_STATIC_SHA256[visitor_config]}" ]] || return 74

  # Close the staged TOCTOU window immediately before the lifecycle change.
  current_runtime_verify_static_files || return 74
  current_runtime_verify_dir_identity root "$root" || return 74
  current_runtime_verify_dir_identity bin "$bin_dir" || return 74
  current_runtime_verify_dir_identity config "$config_dir" || return 74
  current_runtime_verify_dir_identity log "$log_dir" || return 74
}

current_runtime_cleanup() {
  local root=$ACTIVE_TMP_DIR bin_dir config_dir log_dir leaf dir allow_missing
  local entry allow_partial=0
  local -a leaves=(
    "$ACTIVE_TMP_DIR/bin/frps" "$ACTIVE_TMP_DIR/bin/frpc"
    "$ACTIVE_TMP_DIR/bin/udp_send" "$ACTIVE_TMP_DIR/bin/udp_echo"
    "$ACTIVE_TMP_DIR/config/frps.toml" "$ACTIVE_TMP_DIR/config/frpc.toml"
    "$ACTIVE_TMP_DIR/config/frpc-visitor.toml"
    "$ACTIVE_TMP_DIR/log/frps.log" "$ACTIVE_TMP_DIR/log/frpc.log"
    "$ACTIVE_TMP_DIR/log/frpc-visitor.log"
    "$ACTIVE_TMP_DIR/log/frpsA.log" "$ACTIVE_TMP_DIR/log/frpcB.log"
    "$ACTIVE_TMP_DIR/log/frpC.log"
  )
  local -a leaf_dirs=(bin bin bin bin config config config log log log log log log)
  local -a leaf_allow_missing=(0 0 1 1 0 0 0 1 1 1 1 1 1)
  [[ -n "$root" ]] || return 74
  bin_dir=$root/bin
  config_dir=$root/config
  log_dir=$root/log
  if (( ${CONTAINER_START_ATTEMPTED:-0} == 0 && CURRENT_RUNTIME_STATIC_SNAPSHOT_READY == 0 )); then
    allow_partial=1
    leaf_allow_missing=(1 1 1 1 1 1 1 1 1 1 1 1 1)
  fi
  current_runtime_preflight "$allow_partial" || {
    warn "current runtime preflight failed; retaining: $root"
    return 74
  }

  for ((entry = 0; entry < ${#leaves[@]}; entry++)); do
    leaf=${leaves[entry]}
    dir=${leaf_dirs[entry]}
    allow_missing=${leaf_allow_missing[entry]}
    current_runtime_verify_dir_identity "$dir" "$root/$dir" || return 74
    current_runtime_validate_leaf "$leaf" "$allow_missing" || return 74
    if ! rm -f -- "$leaf"; then
      warn "current runtime leaf cleanup failed; retaining: $leaf"
      return 74
    fi
  done

  current_runtime_verify_dir_identity root "$root" || return 74
  current_runtime_verify_dir_identity log "$log_dir" || return 74
  rmdir -- "$log_dir" || return 74
  current_runtime_verify_dir_identity root "$root" || return 74
  current_runtime_verify_dir_identity config "$config_dir" || return 74
  rmdir -- "$config_dir" || return 74
  current_runtime_verify_dir_identity root "$root" || return 74
  current_runtime_verify_dir_identity bin "$bin_dir" || return 74
  rmdir -- "$bin_dir" || return 74
  current_runtime_verify_dir_identity root "$root" || return 74
  rmdir -- "$root" || return 74
}

current_runtime_cleanup_at() {
  local target=$1 saved_active=$ACTIVE_TMP_DIR rc=0
  ACTIVE_TMP_DIR=$target
  if current_runtime_cleanup; then
    rc=0
  else
    rc=$?
  fi
  ACTIVE_TMP_DIR=$saved_active
  return "$rc"
}

old_runtime_cleanup_verified() {
  local old_root=$1 active_root=$ACTIVE_TMP_DIR rc=0
  if ! current_runtime_snapshot "$old_root" "$old_root/bin" \
      "$old_root/config" "$old_root/log"; then
    rc=75
  elif [[ "$CURRENT_RUNTIME_IDENTITY" != "$OLD_RUNTIME_IDENTITY" ]]; then
    rc=75
  elif current_runtime_cleanup_at "$old_root"; then
    rc=0
  else
    rc=$?
  fi
  if ! current_runtime_snapshot "$active_root" "$active_root/bin" \
      "$active_root/config" "$active_root/log"; then
    return 74
  fi
  return "$rc"
}

current_runtime_cleanup_from_identity() {
  local root=$1 identity=$2
  # Run in a subshell so loading an old label snapshot cannot replace the
  # current runtime snapshot used by the EXIT trap.
  (
    current_runtime_identity_load "$identity" || exit 74
    [[ "$CURRENT_RUNTIME_ROOT_REALPATH" == "$root" ]] || exit 74
    ACTIVE_TMP_DIR=$root
    current_runtime_cleanup
  )
}

on_exit() {
  local original_rc=$? final_rc cleanup_status=PASS cleanup_rc=0 cleanup_detail status=FAIL
  local old_cleanup_acceptable=0 current_cleanup_acceptable=0
  trap - EXIT
  final_rc=$original_rc
  if [[ -n "$ACTIVE_TMP_DIR" ]]; then
    if (( ${CONTAINER_START_ATTEMPTED:-0} )); then
      CURRENT_RUNTIME_CLEANUP_STATUS=RETAINED_AFTER_CONTAINER_START_ATTEMPT
      CURRENT_RUNTIME_CLEANUP_RC=0
      CURRENT_RUNTIME_CLEANUP_DETAIL="retained:$ACTIVE_TMP_DIR"
    else
      if current_runtime_cleanup; then
        CURRENT_RUNTIME_CLEANUP_STATUS=PASS
        CURRENT_RUNTIME_CLEANUP_RC=0
        CURRENT_RUNTIME_CLEANUP_DETAIL="removed:$ACTIVE_TMP_DIR"
      else
        CURRENT_RUNTIME_CLEANUP_STATUS=FAIL
        CURRENT_RUNTIME_CLEANUP_RC=74
        CURRENT_RUNTIME_CLEANUP_DETAIL="retained:$ACTIVE_TMP_DIR:cleanup-failed"
        final_rc=74
      fi
    fi
  else
    CURRENT_RUNTIME_CLEANUP_STATUS=NOT_REQUIRED
    CURRENT_RUNTIME_CLEANUP_RC=0
    CURRENT_RUNTIME_CLEANUP_DETAIL=not-required
  fi
  case "$OLD_RUNTIME_CLEANUP_STATUS" in
    PASS|NOT_APPLICABLE|SAFELY_SKIPPED) old_cleanup_acceptable=1 ;;
  esac
  case "$CURRENT_RUNTIME_CLEANUP_STATUS" in
    PASS|NOT_REQUIRED|RETAINED_AFTER_CONTAINER_START_ATTEMPT) current_cleanup_acceptable=1 ;;
  esac
  if (( ! old_cleanup_acceptable || ! current_cleanup_acceptable )); then
    cleanup_status=FAIL
    if (( ! current_cleanup_acceptable )); then
      cleanup_rc=74
      final_rc=74
    elif (( OLD_RUNTIME_CLEANUP_RC != 0 )); then
      cleanup_rc=$OLD_RUNTIME_CLEANUP_RC
    elif (( CURRENT_RUNTIME_CLEANUP_RC != 0 )); then
      cleanup_rc=$CURRENT_RUNTIME_CLEANUP_RC
    else
      cleanup_rc=1
    fi
    (( original_rc != 0 )) || final_rc=1
  fi
  cleanup_detail="old:$OLD_RUNTIME_CLEANUP_STATUS,current:$CURRENT_RUNTIME_CLEANUP_STATUS"
  if (( INTERNAL_MODE )); then
    if (( REPORT_READY && final_rc == 0 )); then
      publish_body_phase body-success 0 || final_rc=$RECOVERY_RC_INTERNAL
    else
      publish_body_phase body-failed "$final_rc" || true
    fi
  fi
  (( final_rc == 0 )) && status=PASS
  if (( REPORT_READY )); then
    printf 'runtime_dir=%q container_start_attempted=%d\n' \
      "$ACTIVE_TMP_DIR" "${CONTAINER_START_ATTEMPTED:-0}"
    printf 'old_runtime_cleanup_status=%s old_runtime_cleanup_exit_code=%d old_runtime_cleanup_detail=%q\n' \
      "$OLD_RUNTIME_CLEANUP_STATUS" "$OLD_RUNTIME_CLEANUP_RC" "$OLD_RUNTIME_CLEANUP_DETAIL"
    printf 'current_runtime_cleanup_status=%s current_runtime_cleanup_exit_code=%d current_runtime_cleanup_detail=%q\n' \
      "$CURRENT_RUNTIME_CLEANUP_STATUS" "$CURRENT_RUNTIME_CLEANUP_RC" "$CURRENT_RUNTIME_CLEANUP_DETAIL"
    printf 'cleanup_status=%s cleanup_exit_code=%d cleanup_detail=%s\n' \
      "$cleanup_status" "$cleanup_rc" "$cleanup_detail"
    printf 'finished_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local release_eligible=false
    if (( final_rc == 0 && PROVENANCE_VALID == 1 )) &&
       [[ "$XUDP_WORKTREE_DIRTY" == false && "$XUDP_GIT_HEAD" != unavailable &&
          "$XUDP_GIT_TREE" != unavailable && "$XUDP_STATUS_DIGEST" != unavailable &&
          "$XUDP_REQUIRED_FILES_VALID" == true ]]; then
      release_eligible=true
    fi
    printf 'provenance_schema=1\n'
    printf 'scenario=%s\n' "$SCENARIO"
    printf 'git_head=%s\n' "$XUDP_GIT_HEAD"
    printf 'git_tree=%s\n' "$XUDP_GIT_TREE"
    printf 'worktree_dirty=%s\n' "$XUDP_WORKTREE_DIRTY"
    printf 'status_digest=%s\n' "$XUDP_STATUS_DIGEST"
    printf 'status_entries=%s\n' "$XUDP_STATUS_ENTRIES"
    printf 'required_files_valid=%s\n' "$XUDP_REQUIRED_FILES_VALID"
    printf 'required_files_missing=%s\n' "$XUDP_REQUIRED_FILES_MISSING"
    if (( PREBUILT_ARTIFACT_MODE )); then
      printf 'build_source=explicit-prebuilt\n'
    else
      printf 'build_source=%s\n' "$([[ "$MODE" == existing ]] && echo external || echo current-worktree)"
    fi
    printf 'prebuilt_artifact_mode=%d\n' "$PREBUILT_ARTIFACT_MODE"
    printf 'frps_source_path=%s\n' "$FRPS_SOURCE_PATH"
    printf 'frps_source_sha256=%s\n' "$FRPS_SOURCE_SHA256"
    printf 'frpc_source_path=%s\n' "$FRPC_SOURCE_PATH"
    printf 'frpc_source_sha256=%s\n' "$FRPC_SOURCE_SHA256"
    printf 'udp_send_source_path=%s\n' "$UDP_SEND_SOURCE_PATH"
    printf 'udp_send_source_sha256=%s\n' "$UDP_SEND_SOURCE_SHA256"
    printf 'udp_echo_source_path=%s\n' "$UDP_ECHO_SOURCE_PATH"
    printf 'udp_echo_source_sha256=%s\n' "$UDP_ECHO_SOURCE_SHA256"
    printf 'build_started_at_utc=%s\n' "$BUILD_STARTED_AT_UTC"
    printf 'frpc_sha256=%s\n' "$FRPC_SHA256"
    printf 'frps_sha256=%s\n' "$FRPS_SHA256"
    printf 'udp_send_sha256=%s\n' "$UDP_SEND_SHA256"
    printf 'udp_echo_sha256=%s\n' "$UDP_ECHO_SHA256"
    printf 'frpc_config_sha256=%s\n' "$FRPC_CONFIG_SHA256"
    printf 'frps_config_sha256=%s\n' "$FRPS_CONFIG_SHA256"
    printf 'visitor_config_sha256=%s\n' "$VISITOR_CONFIG_SHA256"
    printf 'docker_image_server=%s\n' "$DOCKER_IMAGE_SERVER"
    printf 'docker_image_proxy=%s\n' "$DOCKER_IMAGE_PROXY"
    printf 'docker_image_visitor=%s\n' "$DOCKER_IMAGE_VISITOR"
    printf 'release_eligible=%s\n' "$release_eligible"
    printf 'RESULT=%s exit_code=%d main_exit_code=%d detail=%s\n' \
      "$status" "$final_rc" "$original_rc" "$FINAL_DETAIL"
    printf 'RESULT=%s report=%s\n' "$status" "$REPORT" >&${CONSOLE_OUT_FD}
    exec 1>&${CONSOLE_OUT_FD} 2>&${CONSOLE_ERR_FD}
    exec {REPORT_FD}>&-
  fi
  exit "$final_rc"
}
trap on_exit EXIT

fail() {
  local message=$1 rc=${2:-1}
  FINAL_DETAIL=${message// /-}
  warn "$message"
  exit "$rc"
}

validate_docker_name() {
  local kind=$1 value=$2
  [[ -n "$value" ]] || fail "$kind must not be empty" 2
  [[ "$value" != -* ]] || fail "$kind must not start with '-': $value" 2
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || fail "invalid Docker $kind: $value" 2
}

validate_absolute_path() {
  local kind=$1 value=$2
  [[ -n "$value" && "$value" == /* ]] || fail "$kind must be a non-empty absolute path" 2
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || fail "$kind contains a newline" 2
}

validate_recreate_artifact_selection() {
  local count=$PREBUILT_ARTIFACT_COUNT
  if [[ "$MODE" == p2p || "$MODE" == relay ]]; then
    if (( ! RECREATE && count > 0 )); then
      fail "FRP_XUDP_FRPS/FRPC/UDP_SEND/UDP_ECHO require --recreate" 2
    fi
    if (( RECREATE && count != 0 && count != 4 )); then
      fail "recreate prebuilt mode requires all four artifact paths: FRP_XUDP_FRPS, FRP_XUDP_FRPC, FRP_XUDP_UDP_SEND, FRP_XUDP_UDP_ECHO" 2
    fi
    if (( RECREATE && count == 4 )); then
      validate_absolute_path frps_artifact "$PREBUILT_FRPS"
      validate_absolute_path frpc_artifact "$PREBUILT_FRPC"
      validate_absolute_path udp_sender "$UDP_SEND"
      validate_absolute_path udp_echo "$UDP_ECHO"
    fi
  elif (( count > 0 )); then
    fail "prebuilt artifact paths are only supported for --p2p/--relay --recreate" 2
  fi
}

validate_inputs() {
  validate_docker_name container "$DEV_CONTAINER"
  validate_docker_name network "$NETWORK"
  validate_docker_name container "$SERVER"
  validate_docker_name container "$PROXY"
  validate_docker_name container "$VISITOR"
  validate_absolute_path workdir "$DEV_WORKDIR"
  if [[ "$MODE" == existing ]]; then
    validate_absolute_path udp_sender "$UDP_SEND"
    if [[ -n "$UDP_ECHO" ]]; then
      validate_absolute_path udp_echo "$UDP_ECHO"
    fi
  fi
}

validate_recreate_container_names() {
  if [[ "$SERVER" == frpsA && "$PROXY" == frpcB && "$VISITOR" == frpC ]]; then
    return 0
  fi
  fail "refusing --recreate: only fixed containers frpsA/frpcB/frpC are permitted" 2
}

printf 'test=xudp-recovery-docker\n'
printf 'started_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'mode=%s recreate=%s\n' "$MODE" "$RECREATE"
printf 'containers=server:%s proxy:%s visitor:%s dev:%s network:%s\n' \
  "$SERVER" "$PROXY" "$VISITOR" "$DEV_CONTAINER" "$NETWORK"
printf 'binary_source=frps:%s frpc:%s udp_send:%s udp_echo:%s worktree:%s container_workdir:%s\n' \
  "$PREBUILT_FRPS" "$PREBUILT_FRPC" "$UDP_SEND" "$UDP_ECHO" "$ROOT" "$DEV_WORKDIR"
printf 'coverage=Docker-bridge-only\n'
printf 'not_covered=public-NAT,CGNAT,VPN,5G,Wi-Fi,public-Internet,live-P2P-to-Relay-fault\n'
say "report=$REPORT mode=$MODE"

validate_inputs
validate_recreate_artifact_selection
if (( RECREATE )) && [[ "$MODE" != existing ]]; then
  validate_recreate_container_names
fi
[[ ! ( "$MODE" == existing && "$RECREATE" == 1 ) ]] || fail "--recreate is invalid with --existing" 2

command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v timeout >/dev/null 2>&1 || fail "timeout is required"
if [[ "$MODE" == existing ]]; then
  [[ -x "$UDP_SEND" ]] || fail "UDP sender not found or not executable: $UDP_SEND"
fi

inspect_container() {
  local name=$1 status
  docker inspect -- "$name" >/dev/null 2>&1 || { warn "missing container: $name"; return 1; }
  status=$(docker inspect --format '{{.State.Status}}' -- "$name")
  [[ "$status" == running ]] || { warn "container is not running: $name ($status)"; return 1; }
  say "container=$name status=$status"
  docker inspect --format 'image={{.Config.Image}} started={{.State.StartedAt}}' -- "$name"
  docker inspect --format 'mounts={{json .Mounts}}' -- "$name"
}

collect_image_ids() {
  local value
  value=$(docker inspect --format '{{.Image}}' -- "$SERVER" 2>/dev/null || true)
  DOCKER_IMAGE_SERVER=${value:-unavailable}
  value=$(docker inspect --format '{{.Image}}' -- "$PROXY" 2>/dev/null || true)
  DOCKER_IMAGE_PROXY=${value:-unavailable}
  value=$(docker inspect --format '{{.Image}}' -- "$VISITOR" 2>/dev/null || true)
  DOCKER_IMAGE_VISITOR=${value:-unavailable}
}

check_network() {
  docker network inspect -- "$NETWORK" >/dev/null 2>&1 || {
    warn "missing Docker network: $NETWORK"
    return 1
  }
  say "network=$NETWORK status=present"
}

probe_packets() {
  local ip=$1 prefix=$2 i message result rc
  for i in 1 2 3; do
    message="${prefix}-${i}"
    # udp_send has a 12-second application deadline so the first packet can
    # establish P2P or complete the bounded relay fallback. Keep the external
    # watchdog longer so helper diagnostics win over a generic timeout exit.
    if result=$(timeout --foreground 15 "$UDP_SEND" "$ip:9000" "$message" 2>&1); then
      rc=0
    else
      rc=$?
      printf 'packet=%s result=FAIL exit_code=%d output=%q\n' "$message" "$rc" "$result"
      warn "packet failed: $message"
      return "$rc"
    fi
    if [[ "$result" != *"echo: $message"* ]]; then
      printf 'packet=%s result=FAIL reason=unexpected-response output=%q\n' "$message" "$result"
      warn "unexpected UDP response for $message"
      return 1
    fi
    say "packet=$message result=PASS response=$(printf '%q' "$result")"
  done
}

retained_runtime_warning() {
  local reason=${1:-retained-runtime}
  # Keep this warning fixed: callers must not imply that an old runtime was
  # cleaned when a validation or preflight decision retained it.
  printf 'WARNING: retained legacy runtime; runtime directory was not cleaned\n'
  printf 'WARNING: retained legacy runtime; runtime directory was not cleaned\n' >&${CONSOLE_ERR_FD}
  say "old_runtime_retention_reason=$reason"
}

retain_legacy_runtime() {
  local reason=$1
  OLD_RUNTIME_CLEANUP_STATUS=SAFELY_SKIPPED
  OLD_RUNTIME_CLEANUP_RC=0
  OLD_RUNTIME_CLEANUP_DETAIL="retained-legacy-runtime:$reason"
  retained_runtime_warning "$reason"
  say "old_runtime_dir=$OLD_RUNTIME_DIR reason=$OLD_RUNTIME_CLEANUP_DETAIL"
}

docker_inspect_capture() {
  local format=$1 name=$2 inspect_hex payload_hex pair decoded= ch
  DOCKER_INSPECT_OUTPUT=
  # Never place Docker's raw stdout in a Bash variable.  od emits only the
  # byte-safe ASCII representation; pipefail preserves both Docker and
  # encoder failures.  The decoded value is created only after the complete
  # byte stream has passed the strict wire-shape checks below.
  if ! inspect_hex=$(set -o pipefail; docker inspect --format "$format" -- "$name" 2>/dev/null |
    od -An -v -tx1 | tr -d '[:space:]'); then
    return 74
  fi
  [[ -n "$inspect_hex" && "$inspect_hex" =~ ^([0-9a-f]{2})+$ ]] || return 74
  [[ "$inspect_hex" == *0a && "${inspect_hex%0a}" != *0a ]] || return 74
  payload_hex=${inspect_hex%0a}
  # Preserve internal LF bytes for inspect formats that intentionally return
  # multiple records (notably .Mounts).  Higher-level parsers still enforce
  # either exactly one line or a strict non-empty mount record per line.
  [[ -z "$payload_hex" ||
    "$payload_hex" =~ ^((0a)|([2-6][0-9a-f])|(7[0-9a-e]))+$ ]] || return 74

  while [[ -n "$payload_hex" ]]; do
    pair=${payload_hex:0:2}
    payload_hex=${payload_hex:2}
    printf -v ch '%b' "\\x$pair"
    decoded+=$ch
  done
  # The strict wire contract above proves there was exactly one final LF.
  # Keep it in the decoded representation because the single-line and mount
  # parsers deliberately consume and validate that framing byte themselves.
  DOCKER_INSPECT_OUTPUT=$decoded$'\n'
}

docker_inspect_single_line() {
  local format=$1 name=$2 output
  docker_inspect_capture "$format" "$name" || return 74
  output=$DOCKER_INSPECT_OUTPUT
  [[ "$output" == *$'\n' ]] || return 74
  output=${output%$'\n'}
  [[ -n "$output" && "$output" != *$'\n'* && "$output" != *$'\r'* ]] || return 74
  DOCKER_INSPECT_VALUE=$output
}

docker_inspect_mount_lines() {
  local name=$1 output line
  # Docker appends one LF after the rendered template. Prefix every mount with
  # LF instead of using println: println would leave a second trailing LF and
  # make a valid non-empty mount list indistinguishable from malformed framing.
  docker_inspect_capture '{{range .Mounts}}{{printf "\n%s|%s" .Source .Destination}}{{end}}' \
    "$name" || return 74
  output=$DOCKER_INSPECT_OUTPUT
  [[ -n "$output" && "$output" == *$'\n' ]] || return 74
  output=${output%$'\n'}
  [[ "$output" != *$'\r'* ]] || return 74
  if [[ -n "$output" ]]; then
    [[ "$output" == $'\n'* ]] || return 74
    output=${output#$'\n'}
    [[ -n "$output" ]] || return 74
    while IFS= read -r line; do
      line=${line//[[:space:]]/}
      [[ -n "$line" && "$line" != *$'\r'* && "$line" == *'|'* ]] || return 74
      local source=${line%%|*} destination=${line#*|}
      [[ "$destination" != *'|'* && "$source" =~ ^/[^[:space:]|]+$ &&
        "$destination" =~ ^/[^[:space:]|]+$ ]] || return 74
    done < <(printf '%s\n' "$output")
  fi
  DOCKER_INSPECT_VALUE=$output
}

collect_old_runtime_dir() {
  local name source destination candidate container_candidate common_candidate= sources
  local path_label identity_label common_path_label= common_identity=
  local mount_error= label_error= label_valid=1
  local mount_inspect_failed=0 mount_shape_invalid=0 controlled_runtime_seen=0
  OLD_RUNTIME_DIR=
  OLD_RUNTIME_IDENTITY=
  OLD_RUNTIME_CLEANUP_STATUS=NOT_APPLICABLE
  OLD_RUNTIME_CLEANUP_RC=0
  OLD_RUNTIME_CLEANUP_DETAIL=not-evaluated
  for name in "$SERVER" "$PROXY" "$VISITOR"; do
    if ! docker_inspect_mount_lines "$name"; then
      mount_error="container-inspect-failed:$name"
      mount_inspect_failed=1
      continue
    fi
    sources=$DOCKER_INSPECT_VALUE
    container_candidate=
    if [[ -n "$sources" ]]; then
      while IFS= read -r source; do
        [[ -n "$source" ]] || {
          mount_error="malformed-runtime-mount:$name"
          mount_shape_invalid=1
          continue
        }
        destination=${source#*|}
        source=${source%%|*}
        if [[ "$source" =~ ^(/tmp/frp-xudp-smoke\.[A-Za-z0-9]{6})(/.*)?$ ]]; then
          candidate=${BASH_REMATCH[1]}
          if [[ -n "$container_candidate" && "$container_candidate" != "$candidate" ]]; then
            mount_error="multiple-controlled-runtime-dirs:$name"
            mount_shape_invalid=1
            continue
          fi
          container_candidate=$candidate
        fi
      done < <(printf '%s\n' "$sources")
    fi
    if [[ -z "$container_candidate" ]]; then
      mount_error="no-controlled-runtime-dir:$name"
    elif [[ -n "$common_candidate" && "$common_candidate" != "$container_candidate" ]]; then
      mount_error=runtime-dir-not-common
      mount_shape_invalid=1
    else
      controlled_runtime_seen=1
      common_candidate=$container_candidate
    fi

    if ! docker_inspect_single_line '{{index .Config.Labels "frp.xudp.runtime.path"}}' "$name"; then
      label_error="path-label-inspect-failed:$name"
      label_valid=0
      path_label=
    else
      path_label=$DOCKER_INSPECT_VALUE
      runtime_path_valid "$path_label" || {
        label_error="path-label-invalid:$name"
        label_valid=0
      }
    fi
    if ! docker_inspect_single_line '{{index .Config.Labels "frp.xudp.runtime.identity"}}' "$name"; then
      label_error="identity-label-inspect-failed:$name"
      label_valid=0
      identity_label=
    else
      identity_label=$DOCKER_INSPECT_VALUE
      (current_runtime_identity_load "$identity_label") || {
        label_error="identity-label-invalid:$name"
        label_valid=0
      }
    fi
    if [[ -z "$path_label" || -z "$identity_label" ]]; then
      label_error="label-missing:$name"
      label_valid=0
    elif [[ -z "$common_path_label" ]]; then
      common_path_label=$path_label
      common_identity=$identity_label
    elif [[ "$common_path_label" != "$path_label" || "$common_identity" != "$identity_label" ]]; then
      label_error="labels-not-common:$name"
      label_valid=0
    fi
  done

  if (( ! controlled_runtime_seen && ! mount_inspect_failed && ! mount_shape_invalid )); then
    OLD_RUNTIME_CLEANUP_STATUS=NOT_APPLICABLE
    OLD_RUNTIME_CLEANUP_RC=0
    OLD_RUNTIME_CLEANUP_DETAIL=no-controlled-runtime-dir
    say 'old_runtime_dir=NONE reason=no-controlled-runtime-dir'
    return 0
  fi

  if [[ -n "$mount_error" || -z "$common_candidate" ]]; then
    OLD_RUNTIME_DIR=$common_candidate
    OLD_RUNTIME_CLEANUP_DETAIL=${mount_error:-no-controlled-runtime-dir}
    retain_legacy_runtime "${OLD_RUNTIME_CLEANUP_DETAIL}"
    say "old_runtime_dir=NONE reason=$OLD_RUNTIME_CLEANUP_DETAIL"
    return 0
  fi
  OLD_RUNTIME_DIR=$common_candidate
  if (( ! label_valid )); then
    retain_legacy_runtime "${label_error:-labels-not-common}"
    return 0
  fi
  runtime_path_valid "$common_path_label" || {
    retain_legacy_runtime label-path-invalid
    return 0
  }
  [[ "$common_path_label" == "$OLD_RUNTIME_DIR" ]] || {
    retain_legacy_runtime label-path-mismatch
    return 0
  }
  if ! (current_runtime_identity_load "$common_identity" &&
        [[ "$CURRENT_RUNTIME_ROOT_REALPATH" == "$common_path_label" ]]); then
    retain_legacy_runtime identity-label-invalid
    return 0
  fi
  OLD_RUNTIME_IDENTITY=$common_identity
  OLD_RUNTIME_CLEANUP_STATUS=PENDING
  OLD_RUNTIME_CLEANUP_DETAIL="candidate:$OLD_RUNTIME_DIR identity=$OLD_RUNTIME_IDENTITY"
  say "old_runtime_dir=$OLD_RUNTIME_DIR evidence=common-mount-and-label-snapshot"
}

classify_logs() {
  local log_file=$1 expected=$2
  if grep -Eq -- "tunnel established via p2p|recovered P2P path" "$log_file"; then
    say "path=P2P evidence=container-log expected=$expected"
    [[ "$expected" == p2p ]] || return 1
  elif grep -Eq -- "falling back to relay|relay visitor conn established|relay work connection" "$log_file"; then
    say "path=Relay evidence=container-log expected=$expected"
    [[ "$expected" == relay ]] || return 1
  else
    say "path=UNCONFIRMED evidence=no-container-log-marker expected=$expected"
    return 2
  fi
}

readonly_check() {
  check_network
  inspect_container "$SERVER"
  inspect_container "$PROXY"
  inspect_container "$VISITOR"
  collect_image_ids

  local ip
  ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' -- "$VISITOR")
  [[ -n "$ip" ]] || { warn "visitor container has no reported IP address"; return 1; }
  say "visitor_ip=$ip network=$NETWORK"
  say "udp_sender_resolved=$(/bin/readlink -f -- "$UDP_SEND")"
  say "binary_provenance=external-/tmp-binary-not-proven-from-current-worktree"
  probe_packets "$ip" existing
  say "path=UNCONFIRMED evidence=existing-mode-does-not-assert-log-marker"
  say "live_P2P_to_Relay_switch=NOT_COVERED"
}

xudp_host_copy_stat() {
  local path=$1 line extra
  line=$(stat -Lc '%d:%i|%F|%u|%h|%a' -- "$path" 2>/dev/null) || return 1
  [[ -n "$line" && "$line" != *$'\n'* ]] || return 1
  IFS='|' read -r XUDP_HOST_COPY_STAT_DEVINO XUDP_HOST_COPY_STAT_KIND \
    XUDP_HOST_COPY_STAT_UID XUDP_HOST_COPY_STAT_NLINK XUDP_HOST_COPY_STAT_MODE \
    extra <<<"$line"
  [[ -z "$extra" && "$XUDP_HOST_COPY_STAT_DEVINO" =~ ^[0-9]+:[0-9]+$ &&
    -n "$XUDP_HOST_COPY_STAT_KIND" && "$XUDP_HOST_COPY_STAT_UID" =~ ^[0-9]+$ &&
    "$XUDP_HOST_COPY_STAT_NLINK" =~ ^[0-9]+$ &&
    "$XUDP_HOST_COPY_STAT_MODE" =~ ^[0-7]+$ ]]
}

xudp_host_copy_validate_file() {
  local path=$1 current_uid mode_value
  [[ -f "$path" && ! -L "$path" ]] || return 1
  xudp_host_copy_stat "$path" || return 1
  current_uid=$(id -u)
  [[ "$XUDP_HOST_COPY_STAT_KIND" == 'regular file' &&
    "$XUDP_HOST_COPY_STAT_UID" == "$current_uid" &&
    "$XUDP_HOST_COPY_STAT_NLINK" == 1 ]] || return 1
  mode_value=$((8#$XUDP_HOST_COPY_STAT_MODE))
  (( (mode_value & 022) == 0 )) || return 1
}

xudp_host_copy_sha256() {
  local path=$1 expected_identity=${2:-} digest before_identity after_identity
  [[ -x "$XUDP_SHA256_BIN" ]] || return 1
  xudp_host_copy_validate_file "$path" || return 1
  before_identity="$XUDP_HOST_COPY_STAT_DEVINO|$XUDP_HOST_COPY_STAT_KIND|$XUDP_HOST_COPY_STAT_UID|$XUDP_HOST_COPY_STAT_NLINK|$XUDP_HOST_COPY_STAT_MODE"
  [[ -z "$expected_identity" || "$before_identity" == "$expected_identity" ]] || return 1
  digest=$("$XUDP_SHA256_BIN" -- "$path" 2>/dev/null) || return 1
  [[ -n "$digest" && "$digest" != *$'\n'* &&
    "$digest" =~ ^([0-9a-f]{64})[[:space:]]+[^[:space:]].*$ ]] || return 1
  XUDP_HOST_COPY_HASH=${BASH_REMATCH[1]}
  xudp_host_copy_validate_file "$path" || return 1
  after_identity="$XUDP_HOST_COPY_STAT_DEVINO|$XUDP_HOST_COPY_STAT_KIND|$XUDP_HOST_COPY_STAT_UID|$XUDP_HOST_COPY_STAT_NLINK|$XUDP_HOST_COPY_STAT_MODE"
  [[ "$after_identity" == "$before_identity" &&
    ( -z "$expected_identity" || "$after_identity" == "$expected_identity" ) ]] || return 1
}

xudp_host_copy_snapshot_out_dir() {
  local out_dir=$1 line extra current_uid real_dir
  [[ -d "$out_dir" && ! -L "$out_dir" && "$out_dir" != *$'\n'* &&
    "$out_dir" != *$'\r'* ]] || return 1
  real_dir=$(realpath -- "$out_dir" 2>/dev/null) || return 1
  [[ "$real_dir" == "$out_dir" ]] || return 1
  line=$(stat -Lc '%d:%i|%F|%u|%a' -- "$out_dir" 2>/dev/null) || return 1
  [[ -n "$line" && "$line" != *$'\n'* ]] || return 1
  IFS='|' read -r XUDP_HOST_COPY_OUT_DEVINO XUDP_HOST_COPY_OUT_KIND \
    XUDP_HOST_COPY_OUT_UID XUDP_HOST_COPY_OUT_MODE extra <<<"$line"
  current_uid=$(id -u)
  XUDP_HOST_COPY_OUT_REALPATH=$real_dir
  [[ -z "$extra" && "$XUDP_HOST_COPY_OUT_DEVINO" =~ ^[0-9]+:[0-9]+$ &&
    "$XUDP_HOST_COPY_OUT_KIND" == directory &&
    "$XUDP_HOST_COPY_OUT_UID" == "$current_uid" &&
    "$XUDP_HOST_COPY_OUT_MODE" == 700 ]]
}

xudp_host_copy_validate_out_dir() {
  local out_dir=$1 line extra real_dir
  [[ -n "${XUDP_HOST_COPY_OUT_REALPATH:-}" ]] || return 1
  [[ -d "$out_dir" && ! -L "$out_dir" ]] || return 1
  real_dir=$(realpath -- "$out_dir" 2>/dev/null) || return 1
  line=$(stat -Lc '%d:%i|%F|%u|%a' -- "$out_dir" 2>/dev/null) || return 1
  IFS='|' read -r XUDP_HOST_COPY_CHECK_DEVINO XUDP_HOST_COPY_CHECK_KIND \
    XUDP_HOST_COPY_CHECK_UID XUDP_HOST_COPY_CHECK_MODE extra <<<"$line"
  [[ -z "$extra" && "$real_dir" == "$XUDP_HOST_COPY_OUT_REALPATH" &&
    "$XUDP_HOST_COPY_CHECK_DEVINO" == "$XUDP_HOST_COPY_OUT_DEVINO" &&
    "$XUDP_HOST_COPY_CHECK_KIND" == "$XUDP_HOST_COPY_OUT_KIND" &&
    "$XUDP_HOST_COPY_CHECK_UID" == "$XUDP_HOST_COPY_OUT_UID" &&
    "$XUDP_HOST_COPY_CHECK_MODE" == "$XUDP_HOST_COPY_OUT_MODE" ]]
}

xudp_host_copy_require_final_absent() {
  local out_dir=$1 name
  for name in frps frpc; do
    [[ ! -e "$out_dir/$name" && ! -L "$out_dir/$name" ]] || return 1
  done
}

xudp_host_copy_remove_if_ours() {
  local path=$1 expected_devino=${2:-}
  [[ -n "$path" && -n "$expected_devino" ]] || return 0
  case "$path" in
    "$XUDP_HOST_COPY_TMP_FRPS"|"$XUDP_HOST_COPY_TMP_FRPC"|"$XUDP_HOST_COPY_FINAL_FRPS"|"$XUDP_HOST_COPY_FINAL_FRPC") ;;
    *) return 74 ;;
  esac
  [[ -e "$path" || -L "$path" ]] || return 0
  xudp_host_copy_validate_file "$path" || return 0
  [[ "$XUDP_HOST_COPY_STAT_DEVINO" == "$expected_devino" ]] || return 0
  # The identity-check-to-rm-f unlink race is not atomic; names are private to
  # this run's out_dir and this is a non-recursive, single-file removal only.
  rm -f -- "$path" || return 74
  [[ ! -e "$path" && ! -L "$path" ]] || return 74
}

xudp_host_copy_cleanup() {
  local cleanup_rc=0
  xudp_host_copy_validate_out_dir "$XUDP_HOST_COPY_OUT_DIR" || return 74
  xudp_host_copy_remove_if_ours "$XUDP_HOST_COPY_TMP_FRPS" \
    "$XUDP_HOST_COPY_FRPS_DEVINO" || cleanup_rc=74
  xudp_host_copy_validate_out_dir "$XUDP_HOST_COPY_OUT_DIR" || cleanup_rc=74
  xudp_host_copy_remove_if_ours "$XUDP_HOST_COPY_TMP_FRPC" \
    "$XUDP_HOST_COPY_FRPC_DEVINO" || cleanup_rc=74
  xudp_host_copy_validate_out_dir "$XUDP_HOST_COPY_OUT_DIR" || cleanup_rc=74
  xudp_host_copy_remove_if_ours "$XUDP_HOST_COPY_FINAL_FRPS" \
    "$XUDP_HOST_COPY_FRPS_FINAL_DEVINO" || cleanup_rc=74
  xudp_host_copy_validate_out_dir "$XUDP_HOST_COPY_OUT_DIR" || cleanup_rc=74
  xudp_host_copy_remove_if_ours "$XUDP_HOST_COPY_FINAL_FRPC" \
    "$XUDP_HOST_COPY_FRPC_FINAL_DEVINO" || cleanup_rc=74
  xudp_host_copy_validate_out_dir "$XUDP_HOST_COPY_OUT_DIR" || cleanup_rc=74
  return "$cleanup_rc"
}

xudp_host_copy_artifact() {
  local out_dir=$1 name=$2 source=$3 expected_hash=$4
  local tmp final tmp_devino final_devino final_identity
  case "$name" in
    frps)
      tmp=$XUDP_HOST_COPY_TMP_FRPS
      final=$XUDP_HOST_COPY_FINAL_FRPS
      ;;
    frpc)
      tmp=$XUDP_HOST_COPY_TMP_FRPC
      final=$XUDP_HOST_COPY_FINAL_FRPC
      ;;
    *) return 74 ;;
  esac
  xudp_host_copy_validate_out_dir "$out_dir" || return 74
  [[ ! -e "$tmp" && ! -L "$tmp" ]] || return 74
  [[ ! -e "$final" && ! -L "$final" ]] || return 74
  docker cp -- "$source" "$tmp" || return 74
  xudp_host_copy_validate_out_dir "$out_dir" || return 74
  xudp_host_copy_validate_file "$tmp" || return 74
  tmp_devino=$XUDP_HOST_COPY_STAT_DEVINO
  if [[ "$name" == frps ]]; then
    XUDP_HOST_COPY_FRPS_DEVINO=$tmp_devino
  else
    XUDP_HOST_COPY_FRPC_DEVINO=$tmp_devino
  fi
  xudp_host_copy_sha256 "$tmp" || return 74
  [[ "$XUDP_HOST_COPY_HASH" == "$expected_hash" ]] || return 74
  xudp_host_copy_validate_out_dir "$out_dir" || return 74
  [[ ! -e "$final" && ! -L "$final" ]] || return 74
  xudp_host_copy_validate_out_dir "$out_dir" || return 74
  mv -n -- "$tmp" "$final" || return 74
  xudp_host_copy_validate_out_dir "$out_dir" || return 74
  [[ ! -e "$tmp" && ! -L "$tmp" ]] || return 74
  xudp_host_copy_validate_file "$final" || return 74
  final_devino=$XUDP_HOST_COPY_STAT_DEVINO
  final_identity="$final_devino|$XUDP_HOST_COPY_STAT_KIND|$XUDP_HOST_COPY_STAT_UID|$XUDP_HOST_COPY_STAT_NLINK|$XUDP_HOST_COPY_STAT_MODE"
  [[ "$final_devino" == "$tmp_devino" ]] || return 74
  if [[ "$name" == frps ]]; then
    XUDP_HOST_COPY_FRPS_FINAL_DEVINO=$final_devino
  else
    XUDP_HOST_COPY_FRPC_FINAL_DEVINO=$final_devino
  fi
  xudp_host_copy_sha256 "$final" "$final_identity" || return 74
  [[ "$XUDP_HOST_COPY_HASH" == "$expected_hash" ]] || return 74
}

xudp_prebuilt_parent_safe() {
  local path=$1 parent stat_line kind uid mode mode_value real_parent
  parent=$(dirname -- "$path") || return 74
  realpath -e -- "$parent" >/dev/null 2>&1 || return 74
  real_parent=$(realpath -e -- "$parent") || return 74
  [[ "$real_parent" == "$parent" ]] || return 74
  while :; do
    [[ -d "$parent" && ! -L "$parent" ]] || return 74
    stat_line=$(LC_ALL=C stat -Lc '%F|%u|%a' -- "$parent") || return 74
    IFS='|' read -r kind uid mode <<<"$stat_line"
    [[ "$kind" == directory && "$uid" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]+$ ]] || return 74
    mode_value=$((8#$mode))
    if [[ "$parent" == /tmp ]]; then
      # /tmp is the only permitted world-writable ancestor.  Keep the
      # exception exact: canonical directory, non-symlink, sticky, 1777.
      [[ "$real_parent" == /tmp && "$mode" == 1777 &&
        $((mode_value & 01000)) -ne 0 ]] || return 74
    else
      (( (mode_value & 022) == 0 )) || return 74
    fi
    [[ "$parent" == / ]] && break
    parent=${parent%/*}
    [[ -n "$parent" ]] || parent=/
    real_parent=$(realpath -e -- "$parent") || return 74
    [[ "$real_parent" == "$parent" ]] || return 74
  done
}

xudp_prebuilt_source_snapshot() {
  local path=$1 realpath stat_line kind uid nlink mode mode_value before after digest
  [[ -n "$path" && "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 74
  [[ -f "$path" && ! -L "$path" && -x "$path" ]] || return 74
  realpath -e -- "$path" >/dev/null 2>&1 || return 74
  [[ "$(realpath -e -- "$path")" == "$path" ]] || return 74
  xudp_prebuilt_parent_safe "$path" || return 74
  stat_line=$(LC_ALL=C stat -Lc '%d:%i|%F|%u|%h|%a' -- "$path") || return 74
  IFS='|' read -r devino kind uid nlink mode <<<"$stat_line"
  [[ "$devino" =~ ^[0-9]+:[0-9]+$ && "$kind" == 'regular file' &&
    "$uid" =~ ^[0-9]+$ && "$nlink" == 1 && "$mode" =~ ^[0-7]+$ ]] || return 74
  mode_value=$((8#$mode))
  (( (mode_value & 022) == 0 )) || return 74
  before="$path|$devino|$kind|$uid|$nlink|$mode"
  digest=$(xudp_sha256_file "$path") || return 74
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 74
  stat_line=$(LC_ALL=C stat -Lc '%d:%i|%F|%u|%h|%a' -- "$path") || return 74
  IFS='|' read -r devino kind uid nlink mode <<<"$stat_line"
  after="$path|$devino|$kind|$uid|$nlink|$mode"
  [[ "$after" == "$before" ]] || return 74
  PREBUILT_SOURCE_SNAPSHOT=$before
  PREBUILT_SOURCE_HASH=$digest
}

xudp_prebuilt_copy_artifact() {
  local out_dir=$1 name=$2 source=$3 tmp final before after source_hash final_hash
  prebuilt_copy_abort() {
    local rc=$1
    if [[ -e "$tmp" || -L "$tmp" ]]; then
      xudp_host_copy_validate_out_dir "$out_dir" || return 74
      [[ ! -L "$tmp" && -f "$tmp" ]] || return 74
      xudp_host_copy_validate_file "$tmp" || return 74
      rm -f -- "$tmp" || return 74
      [[ ! -e "$tmp" && ! -L "$tmp" ]] || return 74
    fi
    return "$rc"
  }
  case "$name" in
    frps|frpc|udp_send|udp_echo) ;;
    *) return 74 ;;
  esac
  final="$out_dir/$name"
  tmp="$out_dir/.$name.prebuilt-copy.$BASHPID"
  [[ ! -e "$tmp" && ! -L "$tmp" && ! -e "$final" && ! -L "$final" ]] || return 74
  xudp_prebuilt_source_snapshot "$source" || {
    warn "unsafe prebuilt artifact source: $name path=$source"
    prebuilt_copy_abort 2
    return $?
  }
  before=$PREBUILT_SOURCE_SNAPSHOT
  source_hash=$PREBUILT_SOURCE_HASH
  cp -- "$source" "$tmp" || { prebuilt_copy_abort 74; return $?; }
  xudp_host_copy_validate_out_dir "$out_dir" || { prebuilt_copy_abort 74; return $?; }
  xudp_host_copy_validate_file "$tmp" || { prebuilt_copy_abort 74; return $?; }
  chmod 0555 -- "$tmp" || { prebuilt_copy_abort 74; return $?; }
  [[ "$(sha256sum -- "$tmp" | awk '{print $1}')" == "$source_hash" ]] || { prebuilt_copy_abort 74; return $?; }
  xudp_prebuilt_source_snapshot "$source" || { prebuilt_copy_abort 2; return $?; }
  after=$PREBUILT_SOURCE_SNAPSHOT
  [[ "$after" == "$before" && "$PREBUILT_SOURCE_HASH" == "$source_hash" ]] || {
    warn "prebuilt artifact changed during copy: $name path=$source"
    prebuilt_copy_abort 74
    return $?
  }
  mv -n -- "$tmp" "$final" || return 74
  xudp_host_copy_validate_out_dir "$out_dir" || return 74
  xudp_host_copy_validate_file "$final" || return 74
  final_hash=$(sha256sum -- "$final" | awk '{print $1}') || return 74
  [[ "$final_hash" == "$source_hash" ]] || return 74
  case "$name" in
    frps) FRPS_SOURCE_PATH=$source; FRPS_SOURCE_SHA256=$source_hash; FRPS_SHA256=$final_hash ;;
    frpc) FRPC_SOURCE_PATH=$source; FRPC_SOURCE_SHA256=$source_hash; FRPC_SHA256=$final_hash ;;
    udp_send) UDP_SEND_SOURCE_PATH=$source; UDP_SEND_SOURCE_SHA256=$source_hash; UDP_SEND_SHA256=$final_hash ;;
    udp_echo) UDP_ECHO_SOURCE_PATH=$source; UDP_ECHO_SOURCE_SHA256=$source_hash; UDP_ECHO_SHA256=$final_hash ;;
  esac
  say "prebuilt_artifact=$name source=$source sha256=$source_hash"
}

copy_prebuilt_artifacts() {
  local out_dir=$1 name source rc=0
  [[ "$PREBUILT_ARTIFACT_MODE" == 1 ]] || return 74
  [[ "$out_dir" == "$ACTIVE_TMP_DIR/bin" && -d "$out_dir" && ! -L "$out_dir" ]] || return 74
  xudp_host_copy_snapshot_out_dir "$out_dir" || return 74
  for name in frps frpc udp_send udp_echo; do
    [[ ! -e "$out_dir/$name" && ! -L "$out_dir/$name" ]] || return 74
  done
  for name in frps frpc udp_send udp_echo; do
    case "$name" in
      frps) source=$PREBUILT_FRPS ;;
      frpc) source=$PREBUILT_FRPC ;;
      udp_send) source=$UDP_SEND ;;
      udp_echo) source=$UDP_ECHO ;;
    esac
    if xudp_prebuilt_copy_artifact "$out_dir" "$name" "$source"; then
      :
    else
      rc=$?
      [[ "$rc" == 2 ]] && return 2
      return 74
    fi
  done
  [[ "$FRPS_SHA256" =~ ^[0-9a-f]{64}$ && "$FRPC_SHA256" =~ ^[0-9a-f]{64}$ &&
    "$UDP_SEND_SHA256" =~ ^[0-9a-f]{64}$ && "$UDP_ECHO_SHA256" =~ ^[0-9a-f]{64}$ ]]
}

build_binaries() {
  local out_dir=$1
  local build_dir=
  local build_info=
  local build_rc=0
  local cleanup_rc=0
  local verify_rc=0
  local root_realpath= root_devino= root_kind= root_uid= root_mode=
  local frps_devino= frps_kind= frps_uid= frps_nlink= frps_mode= frps_hash=
  local frpc_devino= frpc_kind= frpc_uid= frpc_nlink= frpc_mode= frpc_hash=
  local line record_type artifact_name artifact_lines=()
  local create_payload cleanup_payload build_payload verify_payload
  local create_info_with_end build_info_with_end create_info
  local end_marker='__FRP_XUDP_BUILD_END__'
  local host_copy_rc=0 host_cleanup_rc=0
  local copy_tag=${BASHPID}
  XUDP_HOST_COPY_OUT_DIR=$out_dir
  XUDP_HOST_COPY_TMP_FRPS=$out_dir/.frps.xudp-copy.${copy_tag}
  XUDP_HOST_COPY_TMP_FRPC=$out_dir/.frpc.xudp-copy.${copy_tag}
  XUDP_HOST_COPY_FINAL_FRPS=$out_dir/frps
  XUDP_HOST_COPY_FINAL_FRPC=$out_dir/frpc
  XUDP_HOST_COPY_FRPS_DEVINO=
  XUDP_HOST_COPY_FRPC_DEVINO=
  XUDP_HOST_COPY_FRPS_FINAL_DEVINO=
  XUDP_HOST_COPY_FRPC_FINAL_DEVINO=

  read -r -d '' create_payload <<'FRP_XUDP_BUILD_CREATE' || :
set -eu
umask 077
d=$(mktemp -d /tmp/xudp-build.XXXXXX) || exit 1
case "$d" in
  /tmp/xudp-build.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;;
  *) exit 91 ;;
esac
test -d "$d" && test ! -L "$d"
root_realpath=$(realpath -- "$d") || exit 74
root_stat=$(stat -Lc '%d:%i|%F|%u|%a' -- "$d") || exit 74
IFS='|' read -r root_devino root_kind root_uid root_mode <<EOF_ROOT_STAT
$root_stat
EOF_ROOT_STAT
test "$root_realpath" = "$d"
test "$root_devino" != ""
test "$root_kind" = directory
test "$root_uid" = "$(id -u)"
test "$root_mode" = 700
printf '%s|%s|%s|%s|%s|%s\n' \
  "$d" "$root_realpath" "$root_devino" "$root_kind" "$root_uid" "$root_mode"
FRP_XUDP_BUILD_CREATE

  read -r -d '' cleanup_payload <<'FRP_XUDP_BUILD_CLEANUP' || :
set -eu
fail_closed() { exit 74; }
path=$1
expected_realpath=$2
expected_devino=$3
expected_kind=$4
expected_uid=$5
expected_mode=$6
root_realpath=$(realpath -- "$path") || fail_closed
root_stat=$(stat -Lc '%d:%i|%F|%u|%a' -- "$path") || fail_closed
IFS='|' read -r root_devino root_kind root_uid root_mode <<EOF_ROOT_STAT
$root_stat
EOF_ROOT_STAT
test "$root_realpath" = "$expected_realpath" || fail_closed
test "$root_devino" = "$expected_devino" || fail_closed
test "$root_kind" = "$expected_kind" || fail_closed
test "$root_uid" = "$expected_uid" || fail_closed
test "$root_mode" = "$expected_mode" || fail_closed
unexpected=$(find "$path" -mindepth 1 -maxdepth 1 \
  ! -name frps ! -name frpc ! -name 'cache.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]' -print -quit) || fail_closed
test -z "$unexpected" || fail_closed
for name in frps frpc; do
  file=$path/$name
  test -f "$file" && test ! -L "$file" || fail_closed
  file_stat=$(stat -Lc '%F|%u|%h' -- "$file") || fail_closed
  IFS='|' read -r file_kind file_uid file_nlink <<EOF_FILE_STAT
$file_stat
EOF_FILE_STAT
  test "$file_kind" = 'regular file' || fail_closed
  test "$file_uid" = "$expected_uid" || fail_closed
  test "$file_nlink" = 1 || fail_closed
done
for name in frps frpc; do
  root_realpath=$(realpath -- "$path") || fail_closed
  root_stat=$(stat -Lc '%d:%i|%F|%u|%a' -- "$path") || fail_closed
  IFS='|' read -r root_devino root_kind root_uid root_mode <<EOF_ROOT_STAT
$root_stat
EOF_ROOT_STAT
  test "$root_realpath" = "$expected_realpath" || fail_closed
  test "$root_devino" = "$expected_devino" || fail_closed
  test "$root_kind" = "$expected_kind" || fail_closed
  test "$root_uid" = "$expected_uid" || fail_closed
  test "$root_mode" = "$expected_mode" || fail_closed
  file=$path/$name
  test -f "$file" && test ! -L "$file" || fail_closed
  file_stat=$(stat -Lc '%F|%u|%h' -- "$file") || fail_closed
  IFS='|' read -r file_kind file_uid file_nlink <<EOF_FILE_STAT
$file_stat
EOF_FILE_STAT
  test "$file_kind" = 'regular file' || fail_closed
  test "$file_uid" = "$expected_uid" || fail_closed
  test "$file_nlink" = 1 || fail_closed
  rm -f -- "$file" || fail_closed
  test ! -e "$file" && test ! -L "$file" || fail_closed
done
for cache_root in "$path"/cache.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]; do
  [ -e "$cache_root" ] || [ -L "$cache_root" ] || continue
  test ! -L "$cache_root" && test -d "$cache_root" || fail_closed
  test "$(realpath -- "$cache_root")" = "$cache_root" || fail_closed
  cache_stat=$(stat -Lc '%F|%u' -- "$cache_root") || fail_closed
  IFS='|' read -r cache_kind cache_uid <<EOF_CACHE_STAT
$cache_stat
EOF_CACHE_STAT
  test "$cache_kind" = directory && test "$cache_uid" = "$expected_uid" || fail_closed
  chmod -R u+rwX -- "$cache_root" || fail_closed
  rm -rf -- "$cache_root" || fail_closed
  test ! -e "$cache_root" && test ! -L "$cache_root" || fail_closed
done
rmdir -- "$path" || fail_closed
test ! -e "$path" && test ! -L "$path" || fail_closed
FRP_XUDP_BUILD_CLEANUP

  read -r -d '' build_payload <<'FRP_XUDP_BUILD_RUN' || :
set -eu
fail_closed() { exit 74; }
source_dir=$1
path=$2
expected_realpath=$3
expected_devino=$4
expected_kind=$5
expected_uid=$6
expected_mode=$7
root_realpath=$(realpath -- "$path") || fail_closed
root_stat=$(stat -Lc '%d:%i|%F|%u|%a' -- "$path") || fail_closed
IFS='|' read -r root_devino root_kind root_uid root_mode <<EOF_ROOT_STAT
$root_stat
EOF_ROOT_STAT
test "$root_realpath" = "$expected_realpath" || fail_closed
test "$root_devino" = "$expected_devino" || fail_closed
test "$root_kind" = "$expected_kind" || fail_closed
test "$root_uid" = "$expected_uid" || fail_closed
test "$root_mode" = "$expected_mode" || fail_closed
cache_root=$(mktemp -d "$path/cache.XXXXXX") || fail_closed
case "$cache_root" in
  "$path"/cache.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;;
  *) fail_closed ;;
esac
test ! -L "$cache_root" && test -d "$cache_root" || fail_closed
mkdir -m 700 -- "$cache_root/gocache" "$cache_root/gomodcache" "$cache_root/home" || fail_closed
export GOCACHE="$cache_root/gocache"
export GOMODCACHE="$cache_root/gomodcache"
export HOME="$cache_root/home"
export GOFLAGS=-buildvcs=false
cd "$source_dir"
go build -trimpath -o "$path/frps" ./cmd/frps
go build -trimpath -o "$path/frpc" ./cmd/frpc
unexpected=$(find "$path" -mindepth 1 -maxdepth 1 \
  ! -name frps ! -name frpc \
  ! -name 'cache.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]' \
  -print -quit) || fail_closed
test -z "$unexpected" || fail_closed
for name in frps frpc; do
  file=$path/$name
  test -f "$file" && test ! -L "$file" || fail_closed
  file_stat=$(stat -Lc '%d:%i|%F|%u|%h|%a' -- "$file") || fail_closed
  IFS='|' read -r file_devino file_kind file_uid file_nlink file_mode <<EOF_FILE_STAT
$file_stat
EOF_FILE_STAT
  file_hash=$(sha256sum -- "$file" | awk '{print $1}') || fail_closed
  case "$file_devino" in
    ''|*[!0-9:]*|*:*:*) fail_closed ;;
  esac
  test "$file_kind" = 'regular file' || fail_closed
  test "$file_uid" = "$expected_uid" || fail_closed
  test "$file_nlink" = 1 || fail_closed
  case "$file_mode" in ''|*[!0-7]*) fail_closed ;; esac
  hash_ok=$(printf '%s\n' "$file_hash" | awk \
    'length($0) == 64 && $0 !~ /[^0-9a-f]/ { print 1; exit } { print 0; exit }')
  test "$hash_ok" = 1 || fail_closed
  printf 'artifact|%s|%s|%s|%s|%s|%s|%s\n' "$name" "$file_devino" \
    "$file_kind" "$file_uid" "$file_nlink" "$file_mode" "$file_hash"
done
FRP_XUDP_BUILD_RUN

  read -r -d '' verify_payload <<'FRP_XUDP_BUILD_VERIFY' || :
set -eu
fail_closed() { exit 74; }
source_dir=$1
path=$2
expected_realpath=$3
expected_devino=$4
expected_kind=$5
expected_uid=$6
expected_mode=$7
name=$8
expected_file_devino=$9
expected_file_kind=${10}
expected_file_uid=${11}
expected_file_nlink=${12}
expected_file_mode=${13}
expected_file_hash=${14}
root_realpath=$(realpath -- "$path") || fail_closed
root_stat=$(stat -Lc '%d:%i|%F|%u|%a' -- "$path") || fail_closed
IFS='|' read -r root_devino root_kind root_uid root_mode <<EOF_ROOT_STAT
$root_stat
EOF_ROOT_STAT
test "$root_realpath" = "$expected_realpath" || fail_closed
test "$root_devino" = "$expected_devino" || fail_closed
test "$root_kind" = "$expected_kind" || fail_closed
test "$root_uid" = "$expected_uid" || fail_closed
test "$root_mode" = "$expected_mode" || fail_closed
case "$name" in frps|frpc) ;; *) fail_closed ;; esac
file=$path/$name
test -f "$file" && test ! -L "$file" || fail_closed
file_stat=$(stat -Lc '%d:%i|%F|%u|%h|%a' -- "$file") || fail_closed
IFS='|' read -r file_devino file_kind file_uid file_nlink file_mode <<EOF_FILE_STAT
$file_stat
EOF_FILE_STAT
file_hash=$(sha256sum -- "$file" | awk '{print $1}') || fail_closed
test "$file_devino" = "$expected_file_devino" || fail_closed
test "$file_kind" = "$expected_file_kind" || fail_closed
test "$file_uid" = "$expected_file_uid" || fail_closed
test "$file_nlink" = "$expected_file_nlink" || fail_closed
test "$file_mode" = "$expected_file_mode" || fail_closed
test "$file_hash" = "$expected_file_hash" || fail_closed
FRP_XUDP_BUILD_VERIFY

  docker inspect -- "$DEV_CONTAINER" >/dev/null 2>&1 || { warn "development container not found: $DEV_CONTAINER"; return 1; }
  if create_info_with_end=$(docker exec --user "$HOST_UID:$HOST_GID" -- "$DEV_CONTAINER" /bin/sh -c \
    "$create_payload" _; create_rc=$?; printf '%s' "$end_marker"; exit "$create_rc"); then
    :
  else
    return 1
  fi
  [[ "$create_info_with_end" == *"$end_marker" ]] || return 1
  create_info=${create_info_with_end%"$end_marker"}
  [[ "$create_info" == *$'\n' ]] || return 1
  if ! printf '%s' "$create_info" | awk -F'|' '
    NR == 1 && NF == 6 &&
    $1 ~ /^\/tmp\/xudp-build\.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]$/ &&
    $2 == $1 && $3 ~ /^[0-9]+:[0-9]+$/ && $4 == "directory" &&
    $5 ~ /^[0-9]+$/ && $6 == "700" { ok = 1 }
    NR > 1 { bad = 1 }
    END { exit !(NR == 1 && ok && !bad) }
  '; then
    return 1
  fi
  IFS='|' read -r build_dir root_realpath root_devino root_kind root_uid root_mode <<<"$create_info"
  [[ "$build_dir" =~ ^/tmp/xudp-build\.[A-Za-z0-9]{6}$ &&
    "$root_realpath" == "$build_dir" &&
    "$root_devino" =~ ^[0-9]+:[0-9]+$ && "$root_kind" == directory &&
    "$root_uid" == "$(id -u)" && "$root_mode" == 700 ]] || {
    warn "container returned an unsafe build directory: $build_dir"
    return 1
  }

  cleanup_container_build_dir() {
    local path=${1:-}
    [[ "$path" =~ ^/tmp/xudp-build\.[A-Za-z0-9]{6}$ ]] || return 1
    docker exec --user "$HOST_UID:$HOST_GID" -- "$DEV_CONTAINER" /bin/sh -c "$cleanup_payload" _ \
      "$path" "$root_realpath" "$root_devino" "$root_kind" "$root_uid" "$root_mode" || return 74
  }

  if build_info_with_end=$(docker exec --user "$HOST_UID:$HOST_GID" -- "$DEV_CONTAINER" /bin/sh -c \
    "$build_payload" _ "$DEV_WORKDIR" "$build_dir" "$root_realpath" \
    "$root_devino" "$root_kind" "$root_uid" "$root_mode"; build_rc=$?; \
    printf '%s' "$end_marker"; exit "$build_rc"); then
    :
  else
    build_rc=$?
    cleanup_container_build_dir "$build_dir" || cleanup_rc=$?
    (( cleanup_rc == RECOVERY_RC_INTERNAL )) && return "$RECOVERY_RC_INTERNAL"
    return "$build_rc"
  fi

  [[ "$build_info_with_end" == *"$end_marker" ]] || {
    cleanup_container_build_dir "$build_dir" || return "$RECOVERY_RC_INTERNAL"
    return "$RECOVERY_RC_INTERNAL"
  }
  build_info=${build_info_with_end%"$end_marker"}
  [[ "$build_info" == *$'\n' ]] || {
    cleanup_container_build_dir "$build_dir" || return "$RECOVERY_RC_INTERNAL"
    return "$RECOVERY_RC_INTERNAL"
  }
  if ! printf '%s' "$build_info" | awk -F'|' '
    {
      if (NR > 2 || NF != 8 || $1 != "artifact" ||
          $2 !~ /^(frps|frpc)$/ || $3 !~ /^[0-9]+:[0-9]+$/ ||
          $4 != "regular file" || $5 !~ /^[0-9]+$/ || $6 != 1 ||
          $7 !~ /^[0-7]+$/ || $8 !~ /^[0-9a-f]{64}$/) bad = 1
      if ($2 == "frps") frps++
      if ($2 == "frpc") frpc++
    }
    END { exit !(NR == 2 && !bad && frps == 1 && frpc == 1) }
  '; then
    cleanup_container_build_dir "$build_dir" || return "$RECOVERY_RC_INTERNAL"
    return "$RECOVERY_RC_INTERNAL"
  fi
  mapfile -t artifact_lines < <(printf '%s' "$build_info")
  [[ ${#artifact_lines[@]} == 2 ]] || {
    cleanup_container_build_dir "$build_dir" || return "$RECOVERY_RC_INTERNAL"
    return "$RECOVERY_RC_INTERNAL"
  }
  for line in "${artifact_lines[@]}"; do
    IFS='|' read -r record_type artifact_name artifact_devino artifact_kind artifact_uid \
      artifact_nlink artifact_mode artifact_hash <<<"$line"
    [[ "$record_type" == artifact &&
      ( "$artifact_name" == frps || "$artifact_name" == frpc ) ]] || {
      cleanup_container_build_dir "$build_dir" || return "$RECOVERY_RC_INTERNAL"
      return "$RECOVERY_RC_INTERNAL"
    }
    [[ "$artifact_devino" =~ ^[0-9]+:[0-9]+$ && "$artifact_kind" == 'regular file' &&
      "$artifact_uid" == "$root_uid" && "$artifact_nlink" == 1 &&
      "$artifact_mode" =~ ^[0-7]+$ && "$artifact_hash" =~ ^[0-9a-f]{64}$ ]] || {
      cleanup_container_build_dir "$build_dir" || return "$RECOVERY_RC_INTERNAL"
      return "$RECOVERY_RC_INTERNAL"
    }
    if [[ "$artifact_name" == frps ]]; then
      frps_devino=$artifact_devino; frps_kind=$artifact_kind; frps_uid=$artifact_uid
      frps_nlink=$artifact_nlink; frps_mode=$artifact_mode; frps_hash=$artifact_hash
    else
      frpc_devino=$artifact_devino; frpc_kind=$artifact_kind; frpc_uid=$artifact_uid
      frpc_nlink=$artifact_nlink; frpc_mode=$artifact_mode; frpc_hash=$artifact_hash
    fi
  done
  [[ -n "$frps_hash" && -n "$frpc_hash" ]] || {
    cleanup_container_build_dir "$build_dir" || return "$RECOVERY_RC_INTERNAL"
    return "$RECOVERY_RC_INTERNAL"
  }

  verify_before_copy() {
    local name=$1 expected_devino=$2 expected_kind=$3 expected_uid=$4
    local expected_nlink=$5 expected_mode=$6 expected_hash=$7
    docker exec --user "$HOST_UID:$HOST_GID" -- "$DEV_CONTAINER" /bin/sh -c "$verify_payload" _ \
      "$DEV_WORKDIR" "$build_dir" "$root_realpath" "$root_devino" "$root_kind" \
      "$root_uid" "$root_mode" "$name" "$expected_devino" "$expected_kind" \
      "$expected_uid" "$expected_nlink" "$expected_mode" "$expected_hash"
  }

  if ! xudp_host_copy_snapshot_out_dir "$out_dir" ||
     ! xudp_host_copy_require_final_absent "$out_dir"; then
    host_copy_rc=74
  else
    verify_rc=0
    verify_before_copy frps "$frps_devino" "$frps_kind" "$frps_uid" \
      "$frps_nlink" "$frps_mode" "$frps_hash" || verify_rc=$?
    if (( verify_rc != 0 )); then
      host_copy_rc=74
    elif ! xudp_host_copy_artifact "$out_dir" frps \
        "$DEV_CONTAINER:$build_dir/frps" "$frps_hash"; then
      host_copy_rc=74
    fi
    if (( host_copy_rc == 0 )); then
      verify_rc=0
      verify_before_copy frpc "$frpc_devino" "$frpc_kind" "$frpc_uid" \
        "$frpc_nlink" "$frpc_mode" "$frpc_hash" || verify_rc=$?
      if (( verify_rc != 0 )); then
        host_copy_rc=74
      elif ! xudp_host_copy_artifact "$out_dir" frpc \
          "$DEV_CONTAINER:$build_dir/frpc" "$frpc_hash"; then
        host_copy_rc=74
      fi
    fi
    if (( host_copy_rc == 0 )) &&
       ! chmod 0555 -- "$out_dir/frps" "$out_dir/frpc"; then
      host_copy_rc=74
    fi
  fi
  cleanup_container_build_dir "$build_dir" || cleanup_rc=$?
  if (( host_copy_rc != 0 || cleanup_rc != 0 )); then
    xudp_host_copy_cleanup || host_cleanup_rc=74
    (( host_cleanup_rc == 0 )) || host_copy_rc=74
    return "$RECOVERY_RC_INTERNAL"
  fi
  say "built_binary_source=current-worktree dev_container=$DEV_CONTAINER"
}

build_udp_helpers() {
  local out_dir=$1 build_dir= build_info= build_rc=0 cleanup_rc=0
  local create_payload build_payload cleanup_payload end_marker='__FRP_XUDP_HELPER_BUILD_END__'
  local root_realpath root_devino root_kind root_uid root_mode
  local name hash source tmp final info_line
  local -a helper_names=(udp_send udp_echo)
  [[ "$out_dir" == "$ACTIVE_TMP_DIR/bin" && -d "$out_dir" && ! -L "$out_dir" ]] || return 74
  for name in "${helper_names[@]}"; do
    [[ ! -e "$out_dir/$name" && ! -L "$out_dir/$name" ]] || return 74
  done

  read -r -d '' create_payload <<'FRP_XUDP_HELPER_CREATE' || :
set -eu
umask 077
d=$(mktemp -d /tmp/xudp-helper-build.XXXXXX) || exit 1
case "$d" in
  /tmp/xudp-helper-build.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;;
  *) exit 91 ;;
esac
test -d "$d" && test ! -L "$d"
root_realpath=$(realpath -- "$d") || exit 74
root_stat=$(stat -Lc '%d:%i|%F|%u|%a' -- "$d") || exit 74
IFS='|' read -r root_devino root_kind root_uid root_mode <<EOF_ROOT_STAT
$root_stat
EOF_ROOT_STAT
test "$root_realpath" = "$d"
test "$root_devino" != ""
test "$root_kind" = directory
test "$root_uid" = "$(id -u)"
test "$root_mode" = 700
printf '%s|%s|%s|%s|%s|%s\n' \
  "$d" "$root_realpath" "$root_devino" "$root_kind" "$root_uid" "$root_mode"
FRP_XUDP_HELPER_CREATE

  read -r -d '' build_payload <<'FRP_XUDP_HELPER_BUILD' || :
set -eu
fail_closed() { exit 74; }
source_dir=$1
path=$2
expected_realpath=$3
expected_devino=$4
expected_kind=$5
expected_uid=$6
expected_mode=$7
root_realpath=$(realpath -- "$path") || fail_closed
root_stat=$(stat -Lc '%d:%i|%F|%u|%a' -- "$path") || fail_closed
IFS='|' read -r root_devino root_kind root_uid root_mode <<EOF_ROOT_STAT
$root_stat
EOF_ROOT_STAT
test "$root_realpath" = "$expected_realpath"
test "$root_devino" = "$expected_devino"
test "$root_kind" = "$expected_kind"
test "$root_uid" = "$expected_uid"
test "$root_mode" = "$expected_mode"
cache_root=$(mktemp -d "$path/cache.XXXXXX") || fail_closed
case "$cache_root" in
  "$path"/cache.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;;
  *) fail_closed ;;
esac
test ! -L "$cache_root" && test -d "$cache_root" || fail_closed
mkdir -m 700 -- "$cache_root/gocache" "$cache_root/gomodcache" "$cache_root/home" || fail_closed
export GOCACHE="$cache_root/gocache"
export GOMODCACHE="$cache_root/gomodcache"
export HOME="$cache_root/home"
export GOFLAGS=-buildvcs=false
cd "$source_dir"
go build -trimpath -o "$path/udp_send" ./dev/test/xudp-helper/udp_send
go build -trimpath -o "$path/udp_echo" ./dev/test/xudp-helper/udp_echo
unexpected=$(find "$path" -mindepth 1 -maxdepth 1 ! -name udp_send ! -name udp_echo ! -name 'cache.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]' -print -quit) || fail_closed
test -z "$unexpected" || fail_closed
for name in udp_send udp_echo; do
  file=$path/$name
  test -f "$file" && test ! -L "$file" || fail_closed
  file_stat=$(stat -Lc '%d:%i|%F|%u|%h|%a' -- "$file") || fail_closed
  IFS='|' read -r file_devino file_kind file_uid file_nlink file_mode <<EOF_FILE_STAT
$file_stat
EOF_FILE_STAT
  file_hash=$(sha256sum -- "$file" | awk '{print $1}') || fail_closed
  test "$file_kind" = 'regular file'
  test "$file_uid" = "$expected_uid"
  test "$file_nlink" = 1
  test "$file_mode" != ""
  printf 'artifact|%s|%s|%s|%s|%s|%s|%s\n' "$name" "$file_devino" \
    "$file_kind" "$file_uid" "$file_nlink" "$file_mode" "$file_hash"
done
FRP_XUDP_HELPER_BUILD

  read -r -d '' cleanup_payload <<'FRP_XUDP_HELPER_CLEANUP' || :
set -eu
path=$1
expected_realpath=$2
expected_devino=$3
expected_kind=$4
expected_uid=$5
expected_mode=$6
realpath -- "$path" | grep -Fx -- "$expected_realpath" >/dev/null
test "$(stat -Lc '%d:%i|%F|%u|%a' -- "$path")" = \
  "$expected_devino|$expected_kind|$expected_uid|$expected_mode"
find "$path" -mindepth 1 -maxdepth 1 -type f -name 'udp_send' -delete
find "$path" -mindepth 1 -maxdepth 1 -type f -name 'udp_echo' -delete
for cache_root in "$path"/cache.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]; do
  [ -e "$cache_root" ] || [ -L "$cache_root" ] || continue
  test ! -L "$cache_root" && test -d "$cache_root" || exit 74
  test "$(realpath -- "$cache_root")" = "$cache_root" || exit 74
  cache_stat=$(stat -Lc '%F|%u' -- "$cache_root") || exit 74
  IFS='|' read -r cache_kind cache_uid <<EOF_CACHE_STAT
$cache_stat
EOF_CACHE_STAT
  test "$cache_kind" = directory && test "$cache_uid" = "$expected_uid" || exit 74
  chmod -R u+rwX -- "$cache_root" || exit 74
  rm -rf -- "$cache_root" || exit 74
  test ! -e "$cache_root" && test ! -L "$cache_root" || exit 74
done
rmdir -- "$path"
FRP_XUDP_HELPER_CLEANUP

  docker inspect -- "$DEV_CONTAINER" >/dev/null 2>&1 || return 1
  if ! build_info=$(timeout --foreground 300s docker exec --user "$HOST_UID:$HOST_GID" -- "$DEV_CONTAINER" /bin/sh -c \
    "$create_payload" _; create_rc=$?; printf '%s' "$end_marker"; exit "$create_rc"); then
    return 1
  fi
  [[ "$build_info" == *"$end_marker" ]] || return 74
  build_info=${build_info%"$end_marker"}
  IFS='|' read -r build_dir root_realpath root_devino root_kind root_uid root_mode <<<"$build_info"
  [[ "$build_dir" =~ ^/tmp/xudp-helper-build\.[A-Za-z0-9]{6}$ &&
    "$root_realpath" == "$build_dir" && "$root_devino" =~ ^[0-9]+:[0-9]+$ &&
    "$root_kind" == directory && "$root_uid" == "$(id -u)" && "$root_mode" == 700 ]] || return 74

  cleanup_helper_build_dir() {
    timeout --foreground 60s docker exec --user "$HOST_UID:$HOST_GID" -- "$DEV_CONTAINER" /bin/sh -c \
      "$cleanup_payload" _ "$build_dir" "$root_realpath" "$root_devino" \
      "$root_kind" "$root_uid" "$root_mode"
  }

  if build_info=$(timeout --foreground 300s docker exec --user "$HOST_UID:$HOST_GID" -- "$DEV_CONTAINER" /bin/sh -c \
    "$build_payload" _ "$DEV_WORKDIR" "$build_dir" "$root_realpath" \
    "$root_devino" "$root_kind" "$root_uid" "$root_mode"); then
    :
  else
    build_rc=$?
    cleanup_helper_build_dir || cleanup_rc=$?
    (( cleanup_rc == 0 )) || return 74
    return "$build_rc"
  fi
  if ! awk -F'|' '
    NR == 1 && NF == 8 && $1 == "artifact" && $2 == "udp_send" &&
      $3 ~ /^[0-9]+:[0-9]+$/ && $4 == "regular file" && $5 ~ /^[0-9]+$/ &&
      $6 == 1 && $7 ~ /^[0-7]+$/ && $8 ~ /^[0-9a-f]{64}$/ { send = 1; next }
    NR == 2 && NF == 8 && $1 == "artifact" && $2 == "udp_echo" &&
      $3 ~ /^[0-9]+:[0-9]+$/ && $4 == "regular file" && $5 ~ /^[0-9]+$/ &&
      $6 == 1 && $7 ~ /^[0-7]+$/ && $8 ~ /^[0-9a-f]{64}$/ { echo = 1; next }
    { bad = 1 }
    END { exit !(NR == 2 && send && echo && !bad) }
  ' <<<"$build_info"; then
    cleanup_helper_build_dir || return 74
    return 74
  fi

  for name in "${helper_names[@]}"; do
    info_line=$(awk -F'|' -v wanted="$name" '$1 == "artifact" && $2 == wanted { print; exit }' <<<"$build_info")
    IFS='|' read -r _ _ _ _ _ _ _ hash <<<"$info_line"
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || { cleanup_helper_build_dir || true; return 74; }
    tmp="$out_dir/.$name.xudp-copy.$BASHPID"
    final="$out_dir/$name"
    [[ ! -e "$tmp" && ! -L "$tmp" && ! -e "$final" && ! -L "$final" ]] || {
      cleanup_helper_build_dir || true
      return 74
    }
    timeout --foreground 60s docker cp -- "$DEV_CONTAINER:$build_dir/$name" "$tmp" || {
      rm -f -- "$tmp"
      cleanup_helper_build_dir || true
      return 74
    }
    [[ -f "$tmp" && ! -L "$tmp" && "$(stat -c '%h' -- "$tmp")" == 1 ]] || {
      rm -f -- "$tmp"
      cleanup_helper_build_dir || true
      return 74
    }
    [[ "$(sha256sum -- "$tmp" | awk '{print $1}')" == "$hash" ]] || {
      rm -f -- "$tmp"
      cleanup_helper_build_dir || true
      return 74
    }
    chmod 0555 -- "$tmp" || { rm -f -- "$tmp"; cleanup_helper_build_dir || true; return 74; }
    mv -n -- "$tmp" "$final" || { rm -f -- "$tmp"; cleanup_helper_build_dir || true; return 74; }
    [[ -x "$final" && ! -L "$final" ]] || { cleanup_helper_build_dir || true; return 74; }
    if [[ "$name" == udp_send ]]; then
      UDP_SEND_SHA256=$hash
    else
      UDP_ECHO_SHA256=$hash
    fi
  done
  cleanup_helper_build_dir || return 74
  say "built_udp_helpers_source=current-worktree dev_container=$DEV_CONTAINER"
}

record_recreated_provenance() {
  local bin_dir=$1 cfg_dir=$2
  [[ "$bin_dir" == "$ACTIVE_TMP_DIR/bin" &&
    "$cfg_dir" == "$ACTIVE_TMP_DIR/config" &&
    "$CURRENT_RUNTIME_STATIC_SNAPSHOT_READY" == 1 ]] || return 74
  FRPS_SHA256=${CURRENT_RUNTIME_STATIC_SHA256[frps]-unavailable}
  FRPC_SHA256=${CURRENT_RUNTIME_STATIC_SHA256[frpc]-unavailable}
  UDP_SEND_SHA256=${CURRENT_RUNTIME_STATIC_SHA256[udp_send]-unavailable}
  UDP_ECHO_SHA256=${CURRENT_RUNTIME_STATIC_SHA256[udp_echo]-unavailable}
  FRPS_CONFIG_SHA256=${CURRENT_RUNTIME_STATIC_SHA256[frps_config]-unavailable}
  FRPC_CONFIG_SHA256=${CURRENT_RUNTIME_STATIC_SHA256[frpc_config]-unavailable}
  VISITOR_CONFIG_SHA256=${CURRENT_RUNTIME_STATIC_SHA256[visitor_config]-unavailable}
  for value in "$FRPS_SHA256" "$FRPC_SHA256" "$UDP_SEND_SHA256" \
    "$UDP_ECHO_SHA256" "$FRPS_CONFIG_SHA256" "$FRPC_CONFIG_SHA256" \
    "$VISITOR_CONFIG_SHA256"; do
    [[ "$value" =~ ^[0-9a-f]{64}$ ]] || return 74
  done
}

validate_recreated_provenance() {
  local value
  for value in "$FRPS_SHA256" "$FRPC_SHA256" "$UDP_SEND_SHA256" \
    "$UDP_ECHO_SHA256" "$FRPS_CONFIG_SHA256" "$FRPC_CONFIG_SHA256" \
    "$VISITOR_CONFIG_SHA256"; do
    xudp_valid_sha256_or_unavailable "$value" || return 1
    [[ "$value" != unavailable ]] || return 1
  done
  [[ "$DOCKER_IMAGE_SERVER" != unavailable &&
     "$DOCKER_IMAGE_PROXY" != unavailable &&
     "$DOCKER_IMAGE_VISITOR" != unavailable ]] || return 1
}

run_recreated_scenario() {
  local scenario=$1 bin_dir cfg_dir log_dir ip name rc=0
  [[ "$RECREATE" == 1 ]] || { warn "--$scenario requires explicit --recreate"; return 2; }
  check_network
  ACTIVE_TMP_DIR=$(mktemp -d /tmp/frp-xudp-smoke.XXXXXX)
  bin_dir="$ACTIVE_TMP_DIR/bin"
  cfg_dir="$ACTIVE_TMP_DIR/config"
  log_dir="$ACTIVE_TMP_DIR/log"
  chmod 700 -- "$ACTIVE_TMP_DIR"
  mkdir -m 700 -- "$bin_dir" "$cfg_dir" "$log_dir"
  current_runtime_snapshot "$ACTIVE_TMP_DIR" "$bin_dir" "$cfg_dir" "$log_dir" || {
    warn "unable to snapshot current runtime directory identities"
    return 74
  }

  if (( PREBUILT_ARTIFACT_MODE )); then
    copy_prebuilt_artifacts "$bin_dir" || return $?
  else
    build_binaries "$bin_dir"
    build_udp_helpers "$bin_dir"
  fi
  cp -- "$ROOT/dev/test/frpsB/frps.toml" "$cfg_dir/frps.toml"
  cp -- "$ROOT/dev/test/frpcA/frpc.toml" "$cfg_dir/frpc.toml"
  cp -- "$ROOT/dev/test/frpcC/frpc.toml" "$cfg_dir/frpc-visitor.toml"
  sed -i -- 's/^serverAddr = .*/serverAddr = "frpsA"/' "$cfg_dir/frpc.toml" "$cfg_dir/frpc-visitor.toml"
  if [[ "$scenario" == relay ]]; then
    sed -i -- 's/^natHoleStunServer = .*/natHoleStunServer = "192.0.2.1:3478"/' \
      "$cfg_dir/frpc.toml" "$cfg_dir/frpc-visitor.toml"
  fi
  current_runtime_snapshot_static_files "$bin_dir" "$cfg_dir" || {
    warn "unable to snapshot current runtime static files"
    return 74
  }
  record_recreated_provenance "$bin_dir" "$cfg_dir" || {
    warn "unable to record current runtime static-file provenance"
    return 74
  }
  UDP_SEND="$bin_dir/udp_send"
  UDP_ECHO="$bin_dir/udp_echo"
  [[ -x "$UDP_SEND" && -r "$UDP_ECHO" ]] || {
    warn "prepared UDP helpers are missing or unusable"
    return 74
  }

  # Read old mount sources before changing lifecycle state. Only one common,
  # strictly controlled runtime root may be reclaimed after docker rm succeeds.
  collect_old_runtime_dir
  staged_runtime_preflight "$ACTIVE_TMP_DIR" "$bin_dir" "$cfg_dir" "$log_dir" || {
    warn "staged runtime preflight failed; refusing to remove old containers"
    return 74
  }
  say "staged_runtime_preflight=PASS"
  if docker rm -f -- "$SERVER" "$PROXY" "$VISITOR" >/dev/null 2>&1; then
    if [[ -n "$OLD_RUNTIME_DIR" && "$OLD_RUNTIME_DIR" != "$ACTIVE_TMP_DIR" ]]; then
      if [[ "$OLD_RUNTIME_CLEANUP_STATUS" == PENDING ]]; then
        if current_runtime_cleanup_from_identity "$OLD_RUNTIME_DIR" "$OLD_RUNTIME_IDENTITY"; then
          OLD_RUNTIME_CLEANUP_STATUS=PASS
          OLD_RUNTIME_CLEANUP_RC=0
          OLD_RUNTIME_CLEANUP_DETAIL="removed:$OLD_RUNTIME_DIR"
          say "old_runtime_cleanup=REMOVED runtime_dir=$OLD_RUNTIME_DIR"
        else
          OLD_RUNTIME_CLEANUP_STATUS=FAIL
          OLD_RUNTIME_CLEANUP_RC=74
          OLD_RUNTIME_CLEANUP_DETAIL="retained:$OLD_RUNTIME_DIR:identity-or-allowlist-drift-or-cleanup-failed"
          retained_runtime_warning identity-or-allowlist-drift-or-cleanup-failed
          return "$OLD_RUNTIME_CLEANUP_RC"
        fi
      else
        say "old_runtime_cleanup=SKIPPED reason=legacy-runtime-retained"
      fi
    else
      [[ "$OLD_RUNTIME_CLEANUP_STATUS" != PENDING ]] || {
        OLD_RUNTIME_CLEANUP_STATUS=NOT_APPLICABLE
        OLD_RUNTIME_CLEANUP_DETAIL=active-and-old-runtime-collision
      }
      say "old_runtime_cleanup=NOT_APPLICABLE"
    fi
  else
    if [[ -n "$OLD_RUNTIME_DIR" && "$OLD_RUNTIME_CLEANUP_STATUS" == PENDING ]]; then
      OLD_RUNTIME_CLEANUP_STATUS=SAFELY_SKIPPED
      OLD_RUNTIME_CLEANUP_DETAIL=docker-rm-failed
      retained_runtime_warning docker-rm-failed
    fi
    say "old_runtime_cleanup=SKIPPED reason=docker-rm-failed"
  fi

  # From the first docker run onward, bind mounts may depend on this directory.
  # Retain it on both success and failure until a later recreate safely removes
  # the old containers and their one common controlled runtime directory.
  current_runtime_verify_before_run || {
    warn "current runtime verification failed before $SERVER docker run"
    return 74
  }
  say "live_runtime_preflight=PASS container=$SERVER"
  CONTAINER_START_ATTEMPTED=$(( ${CONTAINER_START_ATTEMPTED:-0} + 1 ))
  docker run -d --name "$SERVER" --network "$NETWORK" \
    --label "$RUNTIME_IDENTITY_LABEL_KEY=$CURRENT_RUNTIME_IDENTITY" \
    --label "$RUNTIME_PATH_LABEL_KEY=$ACTIVE_TMP_DIR" \
    -v "$bin_dir/frps:/usr/local/bin/frps:ro" \
    -v "$cfg_dir/frps.toml:/etc/frp/frps.toml:ro" \
    -- ubuntu:26.04 sh -c '/usr/local/bin/frps -c /etc/frp/frps.toml' >/dev/null
  current_runtime_verify_before_run || {
    warn "current runtime verification failed before $PROXY docker run"
    return 74
  }
  say "live_runtime_preflight=PASS container=$PROXY"
  CONTAINER_START_ATTEMPTED=$(( CONTAINER_START_ATTEMPTED + 1 ))
  docker run -d --name "$PROXY" --network "$NETWORK" \
    --label "$RUNTIME_IDENTITY_LABEL_KEY=$CURRENT_RUNTIME_IDENTITY" \
    --label "$RUNTIME_PATH_LABEL_KEY=$ACTIVE_TMP_DIR" \
    -v "$bin_dir/frpc:/usr/local/bin/frpc:ro" \
    -v "$bin_dir/udp_echo:/usr/local/bin/udp_echo:ro" \
    -v "$cfg_dir/frpc.toml:/etc/frp/frpc.toml:ro" \
    -- ubuntu:26.04 sh -c '/usr/local/bin/udp_echo 127.0.0.1:2000 & exec /usr/local/bin/frpc -c /etc/frp/frpc.toml' >/dev/null
  current_runtime_verify_before_run || {
    warn "current runtime verification failed before $VISITOR docker run"
    return 74
  }
  say "live_runtime_preflight=PASS container=$VISITOR"
  CONTAINER_START_ATTEMPTED=$(( CONTAINER_START_ATTEMPTED + 1 ))
  docker run -d --name "$VISITOR" --network "$NETWORK" \
    --label "$RUNTIME_IDENTITY_LABEL_KEY=$CURRENT_RUNTIME_IDENTITY" \
    --label "$RUNTIME_PATH_LABEL_KEY=$ACTIVE_TMP_DIR" \
    -v "$bin_dir/frpc:/usr/local/bin/frpc:ro" \
    -v "$cfg_dir/frpc-visitor.toml:/etc/frp/frpc.toml:ro" \
    -- ubuntu:26.04 sh -c '/usr/local/bin/frpc -c /etc/frp/frpc.toml' >/dev/null
  sleep 3

  collect_image_ids
  if validate_recreated_provenance; then
    PROVENANCE_VALID=1
  else
    say "provenance_validation=FAIL reason=artifact-or-image-unavailable"
  fi

  ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' -- "$VISITOR")
  [[ -n "$ip" ]] || { warn "visitor container has no reported IP address"; return 1; }
  probe_packets "$ip" "$scenario"
  # Persist by stable role, not by configurable container name. Cleanup still
  # accepts the three exact legacy fixed-name leaves created by older runs.
  docker logs -- "$SERVER" >"$log_dir/frps.log" 2>&1 || true
  docker logs -- "$PROXY" >"$log_dir/frpc.log" 2>&1 || true
  docker logs -- "$VISITOR" >"$log_dir/frpc-visitor.log" 2>&1 || true
  classify_logs "$log_dir/frpc-visitor.log" "$scenario" || rc=$?
  if (( rc == 2 )); then
    say "scenario=$scenario reachability=PASS path=UNCONFIRMED"
    return 2
  elif (( rc != 0 )); then
    warn "scenario=$scenario path classification did not match"
    return "$rc"
  fi
  say "scenario=$scenario reachability=PASS path=CONFIRMED"
  [[ "$scenario" != relay ]] || say "relay_multi_packet=PASS"
  say "live_P2P_to_Relay_switch=NOT_COVERED"
}

case "$MODE" in
  existing) readonly_check ;;
  p2p|relay) run_recreated_scenario "$MODE" ;;
esac
FINAL_DETAIL=completed
