#!/usr/bin/env bash
# PostToolUse circuit breaker: loop / budget / file-thrash detection.
#
# Loop detection compares (tool, tool_input hash) so repeated calls to the same
# tool with DIFFERENT arguments (e.g. reading many files in a row) are not
# mistaken for a loop. File-thrash uses a sliding window of the last 40 edit
# calls instead of lifetime counters, so a long session cannot get permanently
# stuck once a threshold is crossed.
#
# Enforcement (block/warn) honors CLAUDE_HOOK_BYPASS=1; state recording does not,
# so metrics stay complete even during maintenance sessions.
# Non-blocking warnings are delivered via hookSpecificOutput.additionalContext
# (stderr at exit 0 never reaches Claude).
set -uo pipefail

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
INPUT_HASH="$(printf '%s' "$INPUT_JSON" | jq -c '.tool_input // {}' 2>/dev/null | cksum | awk '{print $1}')"
CALL_SIG="${TOOL_NAME}#${INPUT_HASH}"
FILE_PATH="$(printf '%s' "$INPUT_JSON" | jq -r '
  if (.tool_name // "") | test("^(Edit|Write|MultiEdit|NotebookEdit)$") then
    .tool_input.file_path // .tool_input.notebook_path // .tool_input.path // empty
  else
    empty
  end
')"

STATE_FILE="${STATE_DIR}/${SESSION_ID}.json"
LOCK_FILE="${STATE_DIR}/${SESSION_ID}.lock"
AUDIT_LOG="${HOME}/.claude/harness_audit.jsonl"

audit() {
  local decision="$1" reason="$2"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +%s)"
  jq -nc \
    --arg ts "$ts" \
    --arg detector "circuit_breaker" \
    --arg session_id "$SESSION_ID" \
    --arg tool_name "$TOOL_NAME" \
    --arg decision "$decision" \
    --arg reason "$reason" \
    '{ts:$ts, detector:$detector, session_id:$session_id, tool_name:$tool_name, decision:$decision, reason:$reason}' \
    >> "$AUDIT_LOG" 2>/dev/null || true
}

update_state() {
  local tmp_file
  tmp_file="$(mktemp "${STATE_DIR}/.${SESSION_ID}.XXXXXX")" || return 0

  if [[ ! -s "$STATE_FILE" ]] || ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    jq -n --arg session_id "$SESSION_ID" --arg cwd "$CWD" '{
      session_id: $session_id,
      started_at: now | todate,
      cwd: $cwd,
      calls: 0,
      history: [],
      by_tool: {},
      file_edits: {},
      recent_edits: [],
      blocked_count: 0,
      warnings: []
    }' > "$STATE_FILE"
  fi

  if jq \
    --arg session_id "$SESSION_ID" \
    --arg sig "$CALL_SIG" \
    --arg tool_name "$TOOL_NAME" \
    --arg file_path "$FILE_PATH" '
    .session_id = (.session_id // $session_id)
    | .started_at = (.started_at // (now | todate))
    | .calls = ((.calls // 0) + 1)
    | .history = (((.history // []) + [$sig]) | if length > 30 then .[-30:] else . end)
    | .by_tool = (.by_tool // {})
    | .by_tool[$tool_name] = ((.by_tool[$tool_name] // 0) + 1)
    | .file_edits = (.file_edits // {})
    | if ($file_path | length) > 0 then
        .file_edits[$file_path] = ((.file_edits[$file_path] // 0) + 1)
      else
        .
      end
    | .recent_edits = (((.recent_edits // [])
        + (if ($file_path | length) > 0 then [$file_path] else [] end))
        | if length > 40 then .[-40:] else . end)
    | .blocked_count = (.blocked_count // 0)
    | .warnings = (.warnings // [])
  ' "$STATE_FILE" > "$tmp_file" 2>/dev/null; then
    mv "$tmp_file" "$STATE_FILE"
  else
    rm -f "$tmp_file" 2>/dev/null || true
  fi
}

# Serialize concurrent updates when flock is available (parallel tool calls can
# finish near-simultaneously). FD-based lock keeps update_state in this shell.
exec 9>"$LOCK_FILE" 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then
  flock -w 2 9 2>/dev/null || true
fi
update_state
exec 9>&- 2>/dev/null || true

CALLS="$(jq -r '.calls // 0' "$STATE_FILE" 2>/dev/null || echo 0)"
TOP_TOOL="$(jq -r '
  (.by_tool // {}) | to_entries | sort_by(.value) | reverse | first // {key:"none", value:0}
  | "\(.key)(\(.value))"
' "$STATE_FILE" 2>/dev/null || echo "none(0)")"

# Maintenance escape hatch: record state above, but skip all enforcement.
if [[ "${CLAUDE_HOOK_BYPASS:-0}" == "1" ]]; then
  exit 0
fi

block() {
  local reason="$1"
  local tmp_file
  tmp_file="$(mktemp "${STATE_DIR}/.${SESSION_ID}.XXXXXX")" 2>/dev/null || tmp_file=""
  if [[ -n "$tmp_file" ]] && jq '.blocked_count = ((.blocked_count // 0) + 1)' "$STATE_FILE" > "$tmp_file" 2>/dev/null; then
    mv "$tmp_file" "$STATE_FILE"
  else
    rm -f "$tmp_file" 2>/dev/null || true
  fi
  audit "blocked" "$reason"
  printf '[circuit-breaker] reason: %s; calls=%s, top_tool=%s\n' "$reason" "$CALLS" "$TOP_TOOL" >&2
  exit 2
}

# Hard budget backstop — intentionally permanent; bypass is the escape hatch.
if [[ "$CALLS" =~ ^[0-9]+$ ]] && (( CALLS > 300 )); then
  block "total budget exceeded (300 calls)"
fi

# True loop: identical (tool + args) call repeated 8 times consecutively.
if jq -e '(.history // []) as $h | ($h | length) >= 8 and (($h[-8:] | unique | length) == 1)' "$STATE_FILE" >/dev/null 2>&1; then
  block "identical tool call repeated 8 times: ${TOOL_NAME}"
fi

# File thrash: the file THIS call edited has >6 edits within the last 40 edit calls.
RECENT_EDIT_COUNT=0
if [[ -n "$FILE_PATH" ]]; then
  RECENT_EDIT_COUNT="$(jq -r --arg f "$FILE_PATH" '[(.recent_edits // [])[] | select(. == $f)] | length' "$STATE_FILE" 2>/dev/null || echo 0)"
  if [[ "$RECENT_EDIT_COUNT" =~ ^[0-9]+$ ]] && (( RECENT_EDIT_COUNT > 6 )); then
    block "repeated edits to same file: ${FILE_PATH} (${RECENT_EDIT_COUNT} of last 40 edit calls)"
  fi
fi

WARN_BUF=""
addwarn() {
  audit "warned" "$1"
  local line="[circuit-breaker warning] $1 (calls=${CALLS}, top_tool=${TOP_TOOL})"
  if [[ -z "$WARN_BUF" ]]; then
    WARN_BUF="$line"
  else
    WARN_BUF="${WARN_BUF}
${line}"
  fi
}

if [[ "$CALLS" == "100" || "$CALLS" == "200" ]]; then
  addwarn "budget milestone reached (300 is the hard limit)"
fi

if jq -e '(.history // []) as $h | ($h | length) >= 5 and (($h[-5:] | unique | length) == 1)' "$STATE_FILE" >/dev/null 2>&1; then
  addwarn "possible loop forming: identical ${TOOL_NAME} call repeated 5 times"
fi

if [[ -n "$FILE_PATH" && "$RECENT_EDIT_COUNT" =~ ^[0-9]+$ ]] && (( RECENT_EDIT_COUNT > 3 )); then
  addwarn "file thrash forming: ${FILE_PATH} (${RECENT_EDIT_COUNT} of last 40 edit calls; blocks at 7)"
fi

if [[ -n "$WARN_BUF" ]]; then
  jq -n --arg ctx "$WARN_BUF" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $ctx
    }
  }'
fi

exit 0
