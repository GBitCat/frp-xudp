#!/usr/bin/env bash

# Shared, dependency-light provenance helpers for the Docker-only XUDP tests.
# The callers deliberately keep the report format line-oriented so the reports
# remain readable without jq or another JSON parser.

# Every file needed to reproduce the evidence chain must be present in the
# current worktree, tracked, and present in HEAD.  An untracked build input is
# deliberately ineligible even when the local Docker build can see it.
XUDP_SAFE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
XUDP_GIT_BIN=/usr/bin/git
XUDP_ENV_BIN=/usr/bin/env
XUDP_GREP_BIN=/usr/bin/grep
XUDP_AWK_BIN=/usr/bin/awk
XUDP_SHA256_BIN=/usr/bin/sha256sum
XUDP_REQUIRED_FILES=(
  dev/test/run-xudp-recovery-docker.sh
  dev/test/run-xudp-pmtud-docker.sh
  dev/test/test-xudp-docker-scripts.sh
  dev/test/xudp-provenance.sh
  dev/test/xudp-release-summary.sh
  dev/test/xudp-json-validate.go
  dev/test/reports/.gitignore
  pkg/xudp/transport/pmtud_default.go
  pkg/xudp/transport/pmtud_experiment.go
)

xudp_collect_git_provenance() {
  XUDP_GIT_HEAD=unavailable
  XUDP_GIT_TREE=unavailable
  XUDP_WORKTREE_DIRTY=unknown
  XUDP_STATUS_DIGEST=unavailable
  XUDP_STATUS_ENTRIES=unavailable
  XUDP_REQUIRED_FILES_VALID=false
  XUDP_REQUIRED_FILES_MISSING=unavailable

  local status_text entries head tree
  local git_root=$1
  # Git provenance is a security boundary.  Do not inherit PATH, HOME, XDG,
  # aliases, global/system config, locale, repository selectors, or helper
  # configuration.  The absolute command paths below are intentionally fixed
  # to the system image; callers cannot substitute a fake git through PATH.
  local -a git_env=(
    -i
    "PATH=$XUDP_SAFE_PATH"
    HOME=/nonexistent
    XDG_CONFIG_HOME=/nonexistent
    XDG_CONFIG_DIRS=/nonexistent
    GIT_CONFIG_NOSYSTEM=1
    GIT_CONFIG_GLOBAL=/dev/null
    GIT_CONFIG_SYSTEM=/dev/null
    GIT_TERMINAL_PROMPT=0
    LC_ALL=C
    LANG=C
  )
  [[ -x "$XUDP_GIT_BIN" && -x "$XUDP_ENV_BIN" && -x "$XUDP_GREP_BIN" &&
     -x "$XUDP_AWK_BIN" && -x "$XUDP_SHA256_BIN" ]] || return 0
  if ! head=$("$XUDP_ENV_BIN" "${git_env[@]}" \
      "$XUDP_GIT_BIN" -c "safe.directory=$git_root" --no-replace-objects \
      --no-optional-locks -C "$git_root" rev-parse --verify HEAD 2>/dev/null) ||
     ! head=$(printf '%s' "$head" | "$XUDP_GREP_BIN" -Eix '[0-9a-f]{40}'); then
    return 0
  fi
  if ! tree=$("$XUDP_ENV_BIN" "${git_env[@]}" \
      "$XUDP_GIT_BIN" -c "safe.directory=$git_root" --no-replace-objects \
      --no-optional-locks -C "$git_root" rev-parse --verify 'HEAD^{tree}' 2>/dev/null) ||
     ! tree=$(printf '%s' "$tree" | "$XUDP_GREP_BIN" -Eix '[0-9a-f]{40}'); then
    return 0
  fi
  XUDP_GIT_HEAD=$head
  XUDP_GIT_TREE=$tree
  if ! status_text=$("$XUDP_ENV_BIN" "${git_env[@]}" \
      "$XUDP_GIT_BIN" -c "safe.directory=$git_root" --no-replace-objects \
      --no-optional-locks -C "$git_root" status --porcelain=v1 --untracked-files=all 2>/dev/null); then
    XUDP_GIT_HEAD=unavailable
    XUDP_GIT_TREE=unavailable
    return 0
  fi
  XUDP_STATUS_DIGEST=$(printf '%s\n' "$status_text" | "$XUDP_SHA256_BIN" | "$XUDP_AWK_BIN" '{print $1}')
  entries=$(printf '%s\n' "$status_text" | "$XUDP_AWK_BIN" 'NF {count++} END {print count+0}')
  XUDP_STATUS_ENTRIES=$entries
  if (( entries == 0 )); then
    XUDP_WORKTREE_DIRTY=false
  else
    XUDP_WORKTREE_DIRTY=true
  fi

  local missing= file
  for file in "${XUDP_REQUIRED_FILES[@]}"; do
    if [[ ! -f "$git_root/$file" || -L "$git_root/$file" ]] ||
       ! "$XUDP_ENV_BIN" "${git_env[@]}" \
         "$XUDP_GIT_BIN" -c "safe.directory=$git_root" --no-replace-objects \
         --no-optional-locks -C "$git_root" \
         ls-files --error-unmatch -- "$file" >/dev/null 2>&1 ||
       ! "$XUDP_ENV_BIN" "${git_env[@]}" \
         "$XUDP_GIT_BIN" -c "safe.directory=$git_root" --no-replace-objects \
         --no-optional-locks -C "$git_root" \
         cat-file -e "HEAD:$file" 2>/dev/null; then
      [[ -z "$missing" ]] || missing+=,
      missing+=$file
    fi
  done
  if [[ -z "$missing" ]]; then
    XUDP_REQUIRED_FILES_VALID=true
    XUDP_REQUIRED_FILES_MISSING=none
  else
    XUDP_REQUIRED_FILES_VALID=false
    XUDP_REQUIRED_FILES_MISSING=$missing
  fi
}

xudp_sha256_file() {
  local path=$1 digest
  if [[ -f "$path" && ! -L "$path" && -x "$XUDP_SHA256_BIN" ]] &&
      digest=$("$XUDP_SHA256_BIN" -- "$path" 2>/dev/null); then
    "$XUDP_AWK_BIN" '{print $1}' <<<"$digest"
    return 0
  fi
  printf 'unavailable\n'
  return 1
}

xudp_valid_sha256_or_unavailable() {
  [[ "$1" == unavailable || "$1" =~ ^[0-9a-f]{64}$ ]]
}

xudp_json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  printf '%s' "$value"
}
