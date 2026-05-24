#!/usr/bin/env bash
# PostToolUse circuit breaker: loop / budget / file-thrash detection
# Generalized: state dir derived from payload .cwd, per-project under ~/.claude/state/
set -euo pipefail

INPUT_JSON="$(cat || true)"
if ! printf '%s' "$INPUT_JSON" | jq -e . >/dev/null 2>&1; then
  INPUT_JSON='{}'
fi

CWD="$(printf '%s' "$INPUT_JSON" | jq -r '.cwd // empty')"
PROJECT_NAME="$(basename "${CWD:-$PWD}")"
STATE_DIR="${HOME}/.claude/state/${PROJECT_NAME}"
mkdir -p "$STATE_DIR"

SESSION_ID="$(printf '%s' "$INPUT_JSON" | jq -r '.session_id // "unknown"')"
TOOL_NAME="$(printf '%s' "$INPUT_JSON" | jq -r '.tool_name // "unknown"')"
FILE_PATH="$(printf '%s' "$INPUT_JSON" | jq -r '
  if (.tool_name // "") | test("^(Edit|Write|MultiEdit)$") then
    .tool_input.file_path // .tool_input.path // empty
  else
    empty
  end
')"

STATE_FILE="${STATE_DIR}/${SESSION_ID}.json"
LOCK_FILE="${STATE_DIR}/${SESSION_ID}.lock"

update_state() {
  local tmp_file
  tmp_file="$(mktemp "${STATE_DIR}/.${SESSION_ID}.XXXXXX")"

  if [[ ! -s "$STATE_FILE" ]] || ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    jq -n --arg session_id "$SESSION_ID" --arg cwd "$CWD" '{
      session_id: $session_id,
      started_at: now | todate,
      cwd: $cwd,
      calls: 0,
      history: [],
      by_tool: {},
      file_edits: {},
      blocked_count: 0,
      warnings: []
    }' > "$STATE_FILE"
  fi

  jq \
    --arg session_id "$SESSION_ID" \
    --arg tool_name "$TOOL_NAME" \
    --arg file_path "$FILE_PATH" '
    .session_id = (.session_id // $session_id)
    | .started_at = (.started_at // (now | todate))
    | .calls = ((.calls // 0) + 1)
    | .history = (((.history // []) + [$tool_name]) | if length > 30 then .[-30:] else . end)
    | .by_tool = (.by_tool // {})
    | .by_tool[$tool_name] = ((.by_tool[$tool_name] // 0) + 1)
    | .file_edits = (.file_edits // {})
    | if ($file_path | length) > 0 then
        .file_edits[$file_path] = ((.file_edits[$file_path] // 0) + 1)
      else
        .
      end
    | .blocked_count = (.blocked_count // 0)
    | .warnings = (.warnings // [])
  ' "$STATE_FILE" > "$tmp_file"

  mv "$tmp_file" "$STATE_FILE"
}

if command -v flock >/dev/null 2>&1; then
  if flock -w 2 "$LOCK_FILE" -c "$(declare -f update_state); SESSION_ID=$(printf '%q' "$SESSION_ID"); TOOL_NAME=$(printf '%q' "$TOOL_NAME"); FILE_PATH=$(printf '%q' "$FILE_PATH"); CWD=$(printf '%q' "$CWD"); STATE_FILE=$(printf '%q' "$STATE_FILE"); STATE_DIR=$(printf '%q' "$STATE_DIR"); update_state"; then
    :
  else
    update_state
  fi
else
  update_state
fi

CALLS="$(jq -r '.calls // 0' "$STATE_FILE")"
TOP_TOOL="$(jq -r '
  (.by_tool // {}) | to_entries | sort_by(.value) | reverse | first // {key:"none", value:0}
  | "\(.key)(\(.value))"
' "$STATE_FILE")"

block() {
  local reason="$1"
  printf '[circuit-breaker] reason: %s; calls=%s, top_tool=%s\n' "$reason" "$CALLS" "$TOP_TOOL" >&2
  exit 2
}

if jq -e '.calls > 300' "$STATE_FILE" >/dev/null; then
  block "total budget exceeded"
fi

if jq -e '(.history // []) as $h | ($h | length) >= 8 and (($h[-8:] | unique | length) == 1)' "$STATE_FILE" >/dev/null; then
  spam_tool="$(jq -r '.history[-1]' "$STATE_FILE")"
  block "tool spam loop: ${spam_tool} repeated 8 times"
fi

overused_tool="$(jq -r '(.by_tool // {}) | to_entries | map(select(.value > 80)) | first // empty | "\(.key)(\(.value))"' "$STATE_FILE")"
if [[ -n "$overused_tool" ]]; then
  block "single tool overuse: ${overused_tool}"
fi

overedited_file="$(jq -r '(.file_edits // {}) | to_entries | map(select(.value > 6)) | first // empty | "\(.key)(\(.value))"' "$STATE_FILE")"
if [[ -n "$overedited_file" ]]; then
  block "repeated edits to same file: ${overedited_file}"
fi

if [[ "$CALLS" == "100" || "$CALLS" == "200" ]]; then
  printf '[circuit-breaker] warning: budget milestone reached; calls=%s, top_tool=%s\n' "$CALLS" "$TOP_TOOL" >&2
fi

if jq -e '(.history // []) as $h | ($h | length) >= 5 and (($h[-5:] | unique | length) == 1)' "$STATE_FILE" >/dev/null; then
  loop_tool="$(jq -r '.history[-1]' "$STATE_FILE")"
  printf '[circuit-breaker] warning: possible loop forming: %s repeated 5 times; calls=%s, top_tool=%s\n' "$loop_tool" "$CALLS" "$TOP_TOOL" >&2
fi

thrash_file="$(jq -r '(.file_edits // {}) | to_entries | map(select(.value > 3)) | first // empty | "\(.key)(\(.value))"' "$STATE_FILE")"
if [[ -n "$thrash_file" ]]; then
  printf '[circuit-breaker] warning: file thrash starting: %s; calls=%s, top_tool=%s\n' "$thrash_file" "$CALLS" "$TOP_TOOL" >&2
fi

exit 0
