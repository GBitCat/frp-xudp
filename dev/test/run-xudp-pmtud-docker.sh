#!/usr/bin/env bash
set -Eeuo pipefail

# Docker-only XUDP PMTUD/MTU control experiment. It uses loopback inside the
# existing development container and never recreates or restarts containers.

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
. "$ROOT/dev/test/xudp-provenance.sh"
CONTAINER=${FRP_DEV_CONTAINER-frp-dev}
WORKDIR=${FRP_DEV_WORKDIR-/workspace/src}
if [[ ${XUDP_PMTUD_REPORT+x} ]]; then
  REPORT=$XUDP_PMTUD_REPORT
else
  REPORT="$ROOT/dev/test/reports/xudp-pmtud-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
fi
REPORT_FD=
CONSOLE_OUT_FD=
CONSOLE_ERR_FD=
REPORT_READY=0
FINAL_DETAIL=unexpected-exit
SCENARIO=pmtud
BUILD_STARTED_AT_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
XUDP_GIT_HEAD=unavailable
XUDP_GIT_TREE=unavailable
XUDP_WORKTREE_DIRTY=unknown
XUDP_STATUS_DIGEST=unavailable
XUDP_STATUS_ENTRIES=unavailable
DEFAULT_FRPC_SHA256=unavailable
DEFAULT_FRPS_SHA256=unavailable
EXPERIMENT_FRPC_SHA256=unavailable
EXPERIMENT_FRPS_SHA256=unavailable
DOCKER_IMAGE_ID=unavailable
XUDP_REQUIRED_FILES_VALID=false
XUDP_REQUIRED_FILES_MISSING=unavailable
PMTUD_INPUTS_VALID=false
PMTUD_DEFAULT_RESULT=FAIL
PMTUD_EXPERIMENT_RESULT=FAIL
PMTUD_DEFAULT_DISABLED=false
PMTUD_EXPERIMENT_ENABLED=false
xudp_collect_git_provenance "$ROOT"

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

create_report
exec {CONSOLE_OUT_FD}>&1
exec {CONSOLE_ERR_FD}>&2
# Keep stdout/stderr attached to the exclusively opened inode. No later write
# reopens REPORT by path, so replacing the directory entry cannot redirect it.
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

on_exit() {
  local rc=$? status=FAIL
  trap - EXIT
  (( rc == 0 )) && status=PASS
  if (( REPORT_READY )); then
    printf 'finished_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local release_eligible=false
    if (( rc == 0 )) && [[ "$XUDP_WORKTREE_DIRTY" == false &&
      "$XUDP_GIT_HEAD" != unavailable && "$XUDP_GIT_TREE" != unavailable &&
      "$XUDP_STATUS_DIGEST" != unavailable && "$PMTUD_INPUTS_VALID" == true &&
      "$XUDP_REQUIRED_FILES_VALID" == true &&
      "$PMTUD_DEFAULT_RESULT" == PASS && "$PMTUD_EXPERIMENT_RESULT" == PASS &&
      "$PMTUD_DEFAULT_DISABLED" == true && "$PMTUD_EXPERIMENT_ENABLED" == true &&
      "$DEFAULT_FRPC_SHA256" =~ ^[0-9a-f]{64}$ &&
      "$DEFAULT_FRPS_SHA256" =~ ^[0-9a-f]{64}$ &&
      "$EXPERIMENT_FRPC_SHA256" =~ ^[0-9a-f]{64}$ &&
      "$EXPERIMENT_FRPS_SHA256" =~ ^[0-9a-f]{64}$ &&
      "$DOCKER_IMAGE_ID" != unavailable ]]; then
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
    printf 'build_source=current-worktree\n'
    printf 'build_started_at_utc=%s\n' "$BUILD_STARTED_AT_UTC"
    printf 'default_frpc_sha256=%s\n' "$DEFAULT_FRPC_SHA256"
    printf 'default_frps_sha256=%s\n' "$DEFAULT_FRPS_SHA256"
    printf 'experiment_frpc_sha256=%s\n' "$EXPERIMENT_FRPC_SHA256"
    printf 'experiment_frps_sha256=%s\n' "$EXPERIMENT_FRPS_SHA256"
    printf 'frpc_sha256=%s\n' "$EXPERIMENT_FRPC_SHA256"
    printf 'frps_sha256=%s\n' "$EXPERIMENT_FRPS_SHA256"
    printf 'frpc_config_sha256=unavailable\n'
    printf 'frps_config_sha256=unavailable\n'
    printf 'visitor_config_sha256=unavailable\n'
    printf 'docker_image_id=%s\n' "$DOCKER_IMAGE_ID"
    printf 'pmtud_inputs_present=%s\n' "$PMTUD_INPUTS_VALID"
    printf 'pmtud_default_result=%s\n' "$PMTUD_DEFAULT_RESULT"
    printf 'pmtud_experiment_result=%s\n' "$PMTUD_EXPERIMENT_RESULT"
    printf 'pmtud_default_disabled=%s\n' "$PMTUD_DEFAULT_DISABLED"
    printf 'pmtud_experiment_enabled=%s\n' "$PMTUD_EXPERIMENT_ENABLED"
    printf 'release_eligible=%s\n' "$release_eligible"
    printf 'RESULT=%s exit_code=%d detail=%s\n' "$status" "$rc" "$FINAL_DETAIL"
    printf 'RESULT=%s report=%s\n' "$status" "$REPORT" >&${CONSOLE_OUT_FD}
    exec 1>&${CONSOLE_OUT_FD} 2>&${CONSOLE_ERR_FD}
    exec {REPORT_FD}>&-
  fi
  exit "$rc"
}
trap on_exit EXIT

fail() {
  local message=$1 rc=${2:-1}
  FINAL_DETAIL=${message// /-}
  warn "$message"
  exit "$rc"
}

validate_docker_name() {
  local value=$1
  [[ -n "$value" ]] || fail "container name must not be empty" 2
  [[ "$value" != -* ]] || fail "container name must not start with '-': $value" 2
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || fail "invalid Docker container name: $value" 2
}

validate_docker_name "$CONTAINER"
[[ -n "$WORKDIR" && "$WORKDIR" == /* ]] || fail "workdir must be a non-empty absolute path" 2
[[ "$WORKDIR" != *$'\n'* && "$WORKDIR" != *$'\r'* ]] || fail "workdir contains a newline" 2

printf 'test=xudp-pmtud-docker\n'
printf 'started_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'mode=existing-container-loopback\n'
printf 'container=%s workdir=%s source=current-worktree\n' "$CONTAINER" "$WORKDIR"
printf 'coverage=Docker-container-loopback-only\n'
printf 'not_covered=public-NAT,CGNAT,VPN,5G,Wi-Fi,public-Internet,path-MTU\n'
say "report=$REPORT container=$CONTAINER"

command -v docker >/dev/null 2>&1 || fail "docker command is required"
docker inspect -- "$CONTAINER" >/dev/null 2>&1 || fail "Docker container not found: $CONTAINER"
docker inspect --format 'container_image={{.Config.Image}} started={{.State.StartedAt}}' -- "$CONTAINER"
DOCKER_IMAGE_ID=$(docker inspect --format '{{.Image}}' -- "$CONTAINER" 2>/dev/null || true)
DOCKER_IMAGE_ID=${DOCKER_IMAGE_ID:-unavailable}
docker exec -- "$CONTAINER" sh -lc 'test -d "$1"' sh "$WORKDIR" || \
  fail "Docker workdir not found in $CONTAINER: $WORKDIR"

if docker exec -- "$CONTAINER" sh -lc '
  cd -- "$1" &&
  test -f pkg/xudp/transport/pmtud_default.go &&
  test -f pkg/xudp/transport/pmtud_experiment.go &&
  grep -Fq "experimentalPathMTUDiscoveryDefault = false" pkg/xudp/transport/pmtud_default.go &&
  grep -Fq "experimentalPathMTUDiscoveryDefault = true" pkg/xudp/transport/pmtud_experiment.go
' sh "$WORKDIR"; then
  PMTUD_INPUTS_VALID=true
  say "pmtud_build_inputs=present default-disabled-source=verified experiment-enabled-source=verified"
else
  say "pmtud_build_inputs=FAIL reason=required-build-tag-files-or-default-source-check-failed"
fi

run_variant() {
  local name=$1 tags=$2 output frpc_hash frps_hash build_dir=
  say "variant=$name tags=${tags:-none} phase=build"
  build_dir=$(docker exec -- "$CONTAINER" sh -lc '
    set -eu
    umask 077
    d=$(mktemp -d /tmp/xudp-build.XXXXXX)
    case "$d" in
      /tmp/xudp-build.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;;
      *) exit 91 ;;
    esac
    test -d "$d" && test ! -L "$d"
    test "$(stat -c %u -- "$d")" = "$(id -u)"
    test "$(stat -c %a -- "$d")" = 700
    printf '%s\\n' "$d"
  ' sh) || return 1
  [[ "$build_dir" =~ ^/tmp/xudp-build\.[A-Za-z0-9]{6}$ ]] || {
    say "variant=$name build_dir=FAIL unsafe-path"
    return 1
  }
  cleanup_container_build_dir() {
    local path=${1:-}
    [[ "$path" =~ ^/tmp/xudp-build\.[A-Za-z0-9]{6}$ ]] || return 1
    docker exec -- "$CONTAINER" sh -lc '
      set -eu
      test -d "$1" && test ! -L "$1"
      test "$(stat -c %u -- "$1")" = "$(id -u)"
      rm -rf -- "$1"
      test ! -e "$1" && test ! -L "$1"
    ' sh "$path"
  }
  if ! docker exec -- "$CONTAINER" sh -lc '
    set -eu
    cd -- "$1"
    GOFLAGS=-buildvcs=false go build -tags "$2" -o "$3/frps" ./cmd/frps
    GOFLAGS=-buildvcs=false go build -tags "$2" -o "$3/frpc" ./cmd/frpc
    test -f "$3/frps" && test -f "$3/frpc"
    test ! -L "$3/frps" && test ! -L "$3/frpc"
  ' sh "$WORKDIR" "$tags" "$build_dir"; then
    cleanup_container_build_dir "$build_dir" || true
    return 1
  fi
  say "variant=$name phase=test"
  if ! docker exec -- "$CONTAINER" sh -lc '
    cd -- "$1" &&
    GOFLAGS=-buildvcs=false go test -tags "$2" -count=1 -v ./pkg/xudp/transport \
      -run "TestPMTUDBuildDefaultRemainsExplicit|TestExperimentalPMTUD|TestQUICOversizedDatagramKeepsConnection"
  ' sh "$WORKDIR" "$tags"; then
    cleanup_container_build_dir "$build_dir" || true
    return 1
  fi
  if output=$(docker exec -- "$CONTAINER" sh -lc \
      'sha256sum -- "$1/frps" "$1/frpc"' sh "$build_dir" 2>/dev/null); then
    frps_hash=$(awk '$2 ~ /\/frps$/ {print $1; exit}' <<<"$output")
    frpc_hash=$(awk '$2 ~ /\/frpc$/ {print $1; exit}' <<<"$output")
    [[ "$frps_hash" =~ ^[0-9a-f]{64}$ ]] && [[ "$frpc_hash" =~ ^[0-9a-f]{64}$ ]] || {
      frps_hash=unavailable
      frpc_hash=unavailable
    }
  else
    frps_hash=unavailable
    frpc_hash=unavailable
  fi
  cleanup_container_build_dir "$build_dir" || return 1
  if [[ "$name" == default ]]; then
    DEFAULT_FRPS_SHA256=$frps_hash
    DEFAULT_FRPC_SHA256=$frpc_hash
  else
    EXPERIMENT_FRPS_SHA256=$frps_hash
    EXPERIMENT_FRPC_SHA256=$frpc_hash
  fi
  say "variant=$name result=PASS"
  if [[ "$name" == default ]]; then
    PMTUD_DEFAULT_RESULT=PASS
    PMTUD_DEFAULT_DISABLED=true
  else
    PMTUD_EXPERIMENT_RESULT=PASS
    PMTUD_EXPERIMENT_ENABLED=true
  fi
}

run_variant default ""
run_variant xudp_pmtud_experiment xudp_pmtud_experiment
FINAL_DETAIL=completed
