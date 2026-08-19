#!/usr/bin/env bash
set -Eeuo pipefail

# Create a small, jq-free release manifest for the Docker-only XUDP evidence.
# The command is intentionally conservative: it writes an ineligible summary
# for a well-formed but failing/dirty set, and refuses malformed inputs.

usage() {
  cat >&2 <<'EOF'
Usage: xudp-release-summary.sh --output PATH --p2p REPORT --relay REPORT --pmtud REPORT
EOF
}

OUTPUT=
P2P=
RELAY=
PMTUD=
while (($# > 0)); do
  case "$1" in
    --output) (($# >= 2)) || { usage; exit 2; }; OUTPUT=$2; shift ;;
    --p2p) (($# >= 2)) || { usage; exit 2; }; P2P=$2; shift ;;
    --relay) (($# >= 2)) || { usage; exit 2; }; RELAY=$2; shift ;;
    --pmtud) (($# >= 2)) || { usage; exit 2; }; PMTUD=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

strict_path() {
  local kind=$1 path=$2
  [[ -n "$path" && "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || {
    printf '%s must be an absolute path without newlines\n' "$kind" >&2
    exit 2
  }
}

strict_path output "$OUTPUT"
strict_path p2p "$P2P"
strict_path relay "$RELAY"
strict_path pmtud "$PMTUD"
[[ -f "$P2P" && ! -L "$P2P" ]] || { echo "invalid p2p report" >&2; exit 2; }
[[ -f "$RELAY" && ! -L "$RELAY" ]] || { echo "invalid relay report" >&2; exit 2; }
[[ -f "$PMTUD" && ! -L "$PMTUD" ]] || { echo "invalid pmtud report" >&2; exit 2; }
out_parent=$(dirname -- "$OUTPUT")
[[ -d "$out_parent" ]] || { echo "summary parent is not a directory" >&2; exit 2; }
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || { echo "refusing to overwrite summary" >&2; exit 1; }

field() {
  local file=$1 key=$2
  awk -v key="$key" 'index($0, key "=") == 1 {print substr($0, length(key)+2); exit}' "$file"
}

require_field() {
  local file=$1 key=$2 value
  value=$(field "$file" "$key")
  [[ -n "$value" ]] || { printf 'missing field %s in %s\n' "$key" "$file" >&2; exit 2; }
  printf '%s' "$value"
}

report_result() {
  awk '/^RESULT=(PASS|FAIL) exit_code=[0-9]+([[:space:]]|$)/ {sub(/^RESULT=/, ""); split($0, a, " "); print a[1]; exit}' "$1"
}

validate_hex() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
validate_hex_or_unavailable() { [[ "$1" == unavailable ]] || validate_hex "$1"; }
validate_oid() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
validate_oid_or_unavailable() { [[ "$1" == unavailable ]] || validate_oid "$1"; }
validate_bool_or_unknown() { [[ "$1" == true || "$1" == false || "$1" == unknown ]]; }
validate_uint_or_unavailable() { [[ "$1" == unavailable || "$1" =~ ^[0-9]+$ ]]; }

json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  value=${value//$'\b'/\\b}
  value=${value//$'\f'/\\f}
  printf '%s' "$value"
}

report_sha() {
	sha256sum --zero -- "$1" | awk -v RS='\0' '{sub(/ .*/, ""); print}'
}

compat_key() {
  local file=$1
  printf '%s|%s|%s|%s|%s|%s' \
    "$(require_field "$file" git_head)" \
    "$(require_field "$file" git_tree)" \
    "$(require_field "$file" worktree_dirty)" \
    "$(require_field "$file" status_digest)" \
    "$(require_field "$file" status_entries)" \
    "$(require_field "$file" build_source)"
}

artifact_compat_key() {
  local file=$1 key
  for key in frpc_sha256 frps_sha256 frpc_config_sha256 \
    frps_config_sha256 visitor_config_sha256 \
    docker_image_server docker_image_proxy docker_image_visitor; do
    printf '%s|' "$(require_field "$file" "$key")"
  done
}

validate_common() {
  local file=$1 expected=$2 value
  [[ $(require_field "$file" provenance_schema) == 1 ]] || { echo "unsupported provenance schema" >&2; exit 2; }
  [[ $(require_field "$file" scenario) == "$expected" ]] || { echo "scenario mismatch" >&2; exit 2; }
  value=$(require_field "$file" git_head); validate_oid_or_unavailable "$value" || { echo "invalid git_head" >&2; exit 2; }
  value=$(require_field "$file" git_tree); validate_oid_or_unavailable "$value" || { echo "invalid git_tree" >&2; exit 2; }
  value=$(require_field "$file" worktree_dirty); validate_bool_or_unknown "$value" || { echo "invalid worktree_dirty" >&2; exit 2; }
  value=$(require_field "$file" status_digest); validate_hex_or_unavailable "$value" || { echo "invalid status_digest" >&2; exit 2; }
  value=$(require_field "$file" status_entries); validate_uint_or_unavailable "$value" || { echo "invalid status_entries" >&2; exit 2; }
  [[ $(require_field "$file" required_files_valid) == true ||
     $(require_field "$file" required_files_valid) == false ]] || {
    echo "invalid required_files_valid" >&2
    exit 2
  }
  value=$(require_field "$file" build_source); [[ "$value" == current-worktree || "$value" == external ]] || { echo "unsupported build_source" >&2; exit 2; }
  [[ $(require_field "$file" release_eligible) == true || $(require_field "$file" release_eligible) == false ]] || {
    echo "invalid release_eligible" >&2
    exit 2
  }
  [[ $(report_result "$file") == PASS || $(report_result "$file") == FAIL ]] || {
    echo "missing or invalid RESULT" >&2
    exit 2
  }
}

validate_artifact_fields() {
  local file=$1 key value
  for key in frpc_sha256 frps_sha256; do
    value=$(require_field "$file" "$key")
    validate_hex_or_unavailable "$value" || { echo "invalid $key" >&2; exit 2; }
  done
  for key in frpc_config_sha256 frps_config_sha256 visitor_config_sha256; do
    value=$(require_field "$file" "$key")
    validate_hex_or_unavailable "$value" || { echo "invalid $key" >&2; exit 2; }
  done
  for key in docker_image_server docker_image_proxy docker_image_visitor; do
    value=$(require_field "$file" "$key")
    [[ "$value" == unavailable || "$value" != *[[:space:]]* ]] || { echo "invalid $key" >&2; exit 2; }
  done
}

validate_pmtud_fields() {
  local file=$1 key value
  for key in default_frpc_sha256 default_frps_sha256 experiment_frpc_sha256 experiment_frps_sha256; do
    value=$(require_field "$file" "$key")
    validate_hex_or_unavailable "$value" || { echo "invalid $key" >&2; exit 2; }
  done
  value=$(require_field "$file" docker_image_id)
  [[ "$value" == unavailable || "$value" != *[[:space:]]* ]] || { echo "invalid docker_image_id" >&2; exit 2; }
  [[ $(require_field "$file" pmtud_inputs_present) == true || $(require_field "$file" pmtud_inputs_present) == false ]] || { echo "invalid PMTUD input state" >&2; exit 2; }
  [[ $(require_field "$file" pmtud_default_result) == PASS || $(require_field "$file" pmtud_default_result) == FAIL ]] || { echo "invalid PMTUD default result" >&2; exit 2; }
  [[ $(require_field "$file" pmtud_experiment_result) == PASS || $(require_field "$file" pmtud_experiment_result) == FAIL ]] || { echo "invalid PMTUD experiment result" >&2; exit 2; }
  [[ $(require_field "$file" pmtud_default_disabled) == true || $(require_field "$file" pmtud_default_disabled) == false ]] || { echo "invalid PMTUD default state" >&2; exit 2; }
  [[ $(require_field "$file" pmtud_experiment_enabled) == true || $(require_field "$file" pmtud_experiment_enabled) == false ]] || { echo "invalid PMTUD experiment state" >&2; exit 2; }
}

validate_common "$P2P" p2p
validate_common "$RELAY" relay
validate_common "$PMTUD" pmtud
validate_artifact_fields "$P2P"
validate_artifact_fields "$RELAY"
validate_pmtud_fields "$PMTUD"

P2P_KEY=$(compat_key "$P2P")
RELAY_KEY=$(compat_key "$RELAY")
PMTUD_KEY=$(compat_key "$PMTUD")
P2P_ARTIFACT_KEY=$(artifact_compat_key "$P2P")
RELAY_ARTIFACT_KEY=$(artifact_compat_key "$RELAY")
REASONS=()
reason() { REASONS+=("$1"); }
[[ "$P2P_KEY" == "$RELAY_KEY" && "$P2P_KEY" == "$PMTUD_KEY" ]] || reason provenance-mismatch
[[ "$P2P_ARTIFACT_KEY" == "$RELAY_ARTIFACT_KEY" ]] || reason artifact-provenance-mismatch
for file in "$P2P" "$RELAY" "$PMTUD"; do
  [[ $(report_result "$file") == PASS ]] || reason report-result-not-pass
  [[ $(require_field "$file" release_eligible) == true ]] || reason report-not-release-eligible
  [[ $(require_field "$file" worktree_dirty) == false ]] || reason dirty-worktree
  [[ $(require_field "$file" git_head) != unavailable &&
     $(require_field "$file" git_tree) != unavailable &&
     $(require_field "$file" status_digest) != unavailable &&
     $(require_field "$file" status_entries) != unavailable ]] || reason incomplete-provenance
  [[ $(require_field "$file" required_files_valid) == true ]] || reason required-files-not-tracked
  [[ $(require_field "$file" build_source) == current-worktree ]] || reason build-source-not-current-worktree
  if [[ $(require_field "$file" scenario) == pmtud ]]; then
    for key in default_frpc_sha256 default_frps_sha256 \
      experiment_frpc_sha256 experiment_frps_sha256 docker_image_id; do
      [[ $(require_field "$file" "$key") != unavailable ]] || reason incomplete-artifacts
    done
    [[ $(require_field "$file" pmtud_inputs_present) == true ]] || reason pmtud-inputs-not-proven
    [[ $(require_field "$file" pmtud_default_result) == PASS &&
       $(require_field "$file" pmtud_experiment_result) == PASS &&
       $(require_field "$file" pmtud_default_disabled) == true &&
       $(require_field "$file" pmtud_experiment_enabled) == true ]] || reason pmtud-variants-not-pass
  else
    for key in frpc_sha256 frps_sha256 frpc_config_sha256 \
      frps_config_sha256 visitor_config_sha256 \
      docker_image_server docker_image_proxy docker_image_visitor; do
      [[ $(require_field "$file" "$key") != unavailable ]] || reason incomplete-artifacts
    done
  fi
done

P2P_SHA=$(report_sha "$P2P")
RELAY_SHA=$(report_sha "$RELAY")
PMTUD_SHA=$(report_sha "$PMTUD")
P2P_PATH=$(json_escape "$P2P")
RELAY_PATH=$(json_escape "$RELAY")
PMTUD_PATH=$(json_escape "$PMTUD")
REASONS_JSON=
if ((${#REASONS[@]} == 0)); then
  REASONS_JSON='[]'
else
  REASONS_JSON='['
  for reason_text in "${REASONS[@]}"; do
    [[ "$REASONS_JSON" == '[' ]] || REASONS_JSON+=,
    REASONS_JSON+="\"$(json_escape "$reason_text")\""
  done
  REASONS_JSON+=']'
fi
ELIGIBLE=false
((${#REASONS[@]} == 0)) && ELIGIBLE=true

tmp=$(mktemp "$out_parent/.xudp-release-summary.XXXXXX")
cleanup_tmp() { rm -f -- "$tmp"; }
trap cleanup_tmp EXIT
umask 077
{
  printf '{\n'
  printf '  "schema": 1,\n'
  printf '  "release_eligible": %s,\n' "$ELIGIBLE"
  printf '  "required_scenarios": ["p2p", "relay", "pmtud"],\n'
  printf '  "provenance_key": "%s",\n' "$(json_escape "$P2P_KEY")"
  printf '  "rejection_reasons": %s,\n' "$REASONS_JSON"
  printf '  "reports": {\n'
  printf '    "p2p": {"path": "%s", "sha256": "%s", "result": "%s", "supersedes": []},\n' "$P2P_PATH" "$P2P_SHA" "$(report_result "$P2P")"
  printf '    "relay": {"path": "%s", "sha256": "%s", "result": "%s", "supersedes": []},\n' "$RELAY_PATH" "$RELAY_SHA" "$(report_result "$RELAY")"
  printf '    "pmtud": {"path": "%s", "sha256": "%s", "result": "%s", "supersedes": []}\n' "$PMTUD_PATH" "$PMTUD_SHA" "$(report_result "$PMTUD")"
  printf '  }\n}\n'
} >"$tmp"
mv -- "$tmp" "$OUTPUT"
trap - EXIT

if [[ "$ELIGIBLE" == true ]]; then
  exit 0
fi
exit 1
