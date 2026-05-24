#!/usr/bin/env bash
set -euo pipefail

STATE_ROOT="${HOME}/.claude/state"
AUDIT_LOG="${HOME}/.claude/harness_audit.jsonl"

INPUT_JSON="$(cat || true)"
if ! printf '%s' "$INPUT_JSON" | jq -e . >/dev/null 2>&1; then
  INPUT_JSON='{}'
fi

SESSION_ID="$(printf '%s' "$INPUT_JSON" | jq -r '.session_id // "unknown"')"
TOOL_NAME="$(printf '%s' "$INPUT_JSON" | jq -r '.tool_name // empty')"
COMMAND="$(printf '%s' "$INPUT_JSON" | jq -r '.tool_input.command // .tool_input.cmd // empty')"
CWD="$(printf '%s' "$INPUT_JSON" | jq -r --arg pwd "$PWD" '.cwd // $pwd')"

if [[ "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

if [[ ! "$COMMAND" =~ dbt[[:space:]]+(compile|parse|build|run|test)\b ]]; then
  exit 0
fi

CWD="${CWD%/}"
PROJECT_NAME="${CWD##*/}"
if [[ -z "$PROJECT_NAME" ]]; then
  PROJECT_NAME="unknown"
fi

CURRENT_MANIFEST="${CWD}/target/manifest.json"
if [[ ! -f "$CURRENT_MANIFEST" ]]; then
  CURRENT_MANIFEST="${CWD}/dbt/target/manifest.json"
fi

if [[ ! -f "$CURRENT_MANIFEST" ]]; then
  exit 0
fi

PROJECT_STATE_DIR="${STATE_ROOT}/${PROJECT_NAME}"
SNAPSHOT="${PROJECT_STATE_DIR}/last_manifest.json"

manifest_valid() {
  local manifest="$1"
  jq -e '
    type == "object"
    and has("nodes")
    and has("parent_map")
    and (.nodes | type == "object")
    and (.parent_map | type == "object")
  ' "$manifest" >/dev/null 2>&1
}

audit_log() {
  local removed_count="$1"
  local broken_count="$2"

  mkdir -p "${HOME}/.claude"
  jq -nc \
    --arg detector "lineage_check" \
    --arg session_id "$SESSION_ID" \
    --arg project "$PROJECT_NAME" \
    --argjson removed_count "$removed_count" \
    --argjson broken_downstream_count "$broken_count" \
    '{
      detector: $detector,
      session_id: $session_id,
      removed_count: $removed_count,
      broken_downstream_count: $broken_downstream_count,
      project: $project
    }' >> "$AUDIT_LOG"
}

write_snapshot() {
  local source_manifest="$1"
  local tmp_file

  mkdir -p "$PROJECT_STATE_DIR"
  tmp_file="$(mktemp "${PROJECT_STATE_DIR}/last_manifest.XXXXXX")"
  jq '.' "$source_manifest" > "$tmp_file"
  mv "$tmp_file" "$SNAPSHOT"
}

if ! manifest_valid "$CURRENT_MANIFEST"; then
  printf '[lineage_check] malformed manifest or missing nodes/parent_map: %s\n' "$CURRENT_MANIFEST" >&2
  exit 0
fi

if [[ ! -f "$SNAPSHOT" ]]; then
  write_snapshot "$CURRENT_MANIFEST"
  audit_log 0 0
  exit 0
fi

if ! manifest_valid "$SNAPSHOT"; then
  printf '[lineage_check] malformed snapshot or missing nodes/parent_map: %s\n' "$SNAPSHOT" >&2
  write_snapshot "$CURRENT_MANIFEST"
  audit_log 0 0
  exit 0
fi

REMOVED_JSON="$(
  jq -n \
    --slurpfile old "$SNAPSHOT" \
    --slurpfile new "$CURRENT_MANIFEST" '
    def models($m):
      $m.nodes
      | to_entries
      | map(select(.value.resource_type == "model") | .key);

    (models($old[0])) as $old_models
    | (models($new[0])) as $new_models
    | ($old_models - $new_models)
  '
)"

BREAKS_JSON="$(
  jq -n \
    --slurpfile old "$SNAPSHOT" \
    --slurpfile new "$CURRENT_MANIFEST" \
    --argjson removed "$REMOVED_JSON" '
    def downstream_for($manifest; $removed_model):
      $manifest.parent_map
      | to_entries
      | map(select((.value // []) | index($removed_model)) | .key);

    [
      $removed[] as $removed_model
      | downstream_for($old[0]; $removed_model)[]
      | select($new[0].nodes[.]? != null)
      | select((($new[0].parent_map[.] // []) | index($removed_model)) == null)
      | {
          removed_model: $removed_model,
          downstream: .,
          removed_short: ($removed_model | split(".") | last)
        }
    ]
  '
)"

REMOVED_COUNT="$(printf '%s' "$REMOVED_JSON" | jq 'length')"
BROKEN_COUNT="$(printf '%s' "$BREAKS_JSON" | jq 'length')"

write_snapshot "$CURRENT_MANIFEST"
audit_log "$REMOVED_COUNT" "$BROKEN_COUNT"

if [[ "$BROKEN_COUNT" -eq 0 ]]; then
  exit 0
fi

ADDITIONAL_CONTEXT="$(
  jq -nr \
    --argjson removed "$REMOVED_JSON" \
    --argjson breaks "$BREAKS_JSON" '
    def bullet_removed:
      $removed
      | unique
      | map("- " + .)
      | join("\n");

    def bullet_downstream:
      $breaks
      | unique_by(.removed_model + "\u0000" + .downstream)
      | map("- " + .downstream + " (was referencing " + .removed_short + ")")
      | join("\n");

    "## ⚠️ dbt lineage break detected\n\n"
    + "Removed/renamed models:\n"
    + bullet_removed
    + "\n\nAffected downstream (may be broken):\n"
    + bullet_downstream
  '
)"

jq -nc --arg additionalContext "$ADDITIONAL_CONTEXT" '{
  hookSpecificOutput: {
    additionalContext: $additionalContext
  }
}'

exit 0
