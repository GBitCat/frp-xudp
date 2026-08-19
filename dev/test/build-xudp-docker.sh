#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

# Build the exact current worktree in Docker. The source is mounted read-only
# and the four artifacts are published with one host-side rename.

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
IMAGE=${FRP_XUDP_BUILD_IMAGE-golang:1.25-bookworm}
OUTPUT=${FRP_XUDP_BIN_DIR-/tmp/frp-bin}
LOG=${FRP_XUDP_BUILD_LOG-/tmp/frp-xudp-build-$(date -u +%Y%m%dT%H%M%SZ)-$$.log}
BUILD_NETWORK=${FRP_XUDP_BUILD_NETWORK-}
docker_network_args=()
case "$BUILD_NETWORK" in
  ''|bridge|default)
    docker_network_mode=default
    ;;
  host)
    docker_network_mode=host
    docker_network_args=(--network host)
    ;;
  *)
    printf 'usage: FRP_XUDP_BUILD_NETWORK must be empty, bridge, default, or host (got %q)\n' "$BUILD_NETWORK" >&2
    exit 2
    ;;
esac
TMP_DIR=

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

[[ "$OUTPUT" == /tmp/frp-bin || "$OUTPUT" =~ ^/tmp/frp-bin\.[A-Za-z0-9._-]+$ ]] || {
  echo "refusing unsafe output path: $OUTPUT" >&2
  exit 2
}
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || {
  echo "output already exists; remove it explicitly before rebuilding: $OUTPUT" >&2
  exit 2
}
mkdir -p -- "$(dirname -- "$LOG")"

git_head=$(git -C "$ROOT" rev-parse HEAD)
git_tree=$(git -C "$ROOT" write-tree)
status_text=$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)
if [[ -n "$status_text" ]]; then
  git_dirty=true
else
  git_dirty=false
fi
status_entries=$(printf '%s\n' "$status_text" | awk 'NF {n++} END {print n+0}')
status_digest=$(printf '%s\n' "$status_text" | sha256sum | awk '{print $1}')
build_started=$(date -u +%Y-%m-%dT%H:%M:%SZ)

TMP_DIR=$(mktemp -d /tmp/frp-bin-build.XXXXXX)
chmod 700 -- "$TMP_DIR"

{
  printf 'build_source=current-worktree\n'
  printf 'build_started_at_utc=%s\n' "$build_started"
  printf 'git_head=%s\n' "$git_head"
  printf 'git_tree=%s\n' "$git_tree"
  printf 'worktree_dirty=%s\n' "$git_dirty"
  printf 'status_entries=%s\n' "$status_entries"
  printf 'status_digest=%s\n' "$status_digest"
  printf 'docker_image=%s\n' "$IMAGE"
  printf 'docker_network_mode=%s\n' "$docker_network_mode"
  printf 'container_cache_lifecycle=docker-rm-private-tmp\n'
  printf 'output=%s\n' "$OUTPUT"
  printf 'temp_output=%s\n' "$TMP_DIR"
} >"$LOG"

build_rc=0
docker run --rm \
  "${docker_network_args[@]}" \
  --user "$(id -u):$(id -g)" \
  -v "$ROOT:/src:ro" \
  -v "$TMP_DIR:/out" \
  -w /src \
  "$IMAGE" sh -ceu "$(cat <<'CONTAINER_SCRIPT'
export CGO_ENABLED=0
export GOFLAGS=-buildvcs=false
cache_root=$(mktemp -d /tmp/frp-go-cache.XXXXXX)
# The cache is private to this --rm container and is reclaimed with its removal.
export GOCACHE="$cache_root/build"
export GOMODCACHE="$cache_root/mod"
mkdir -p -- "$GOCACHE" "$GOMODCACHE"
go version
printf "goos=%s\n" "$(go env GOOS)"
printf "goarch=%s\n" "$(go env GOARCH)"
gofmt_files=$(gofmt -l ./dev/test/xudp-helper/udp_send/main.go ./dev/test/xudp-helper/udp_echo/main.go)
test -z "$gofmt_files"
printf "gofmt_check=PASS\n"
go build -trimpath -ldflags "-s -w" -tags "frps,noweb" -o /out/frps ./cmd/frps
go build -trimpath -ldflags "-s -w" -tags "frpc,noweb" -o /out/frpc ./cmd/frpc
go build -trimpath -o /out/udp_send ./dev/test/xudp-helper/udp_send
go build -trimpath -o /out/udp_echo ./dev/test/xudp-helper/udp_echo
for name in frps frpc udp_send udp_echo; do
  test -f "/out/$name" && test ! -L "/out/$name" && test -x "/out/$name"
  sha256sum "/out/$name"
done
CONTAINER_SCRIPT
)" >>"$LOG" 2>&1 || build_rc=$?
if (( build_rc != 0 )); then
  echo "Docker build failed; log: $LOG" >&2
  cat "$LOG" >&2
  exit "$build_rc"
fi

for name in frps frpc udp_send udp_echo; do
  path=$TMP_DIR/$name
  [[ -f "$path" && ! -L "$path" && -x "$path" ]] || {
    echo "missing or non-executable artifact: $path" >&2
    exit 1
  }
  digest=$(sha256sum -- "$path" | awk '{print $1}')
  file_info=$(file --brief -- "$path")
  printf 'artifact=%s\tsha256=%s\tfile=%s\n' "$name" "$digest" "$file_info" | tee -a "$LOG"
done

mv -- "$TMP_DIR" "$OUTPUT"
TMP_DIR=
printf 'published_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$LOG"
printf 'BUILD_RESULT=PASS\nBUILD_LOG=%s\nOUTPUT=%s\n' "$LOG" "$OUTPUT"
