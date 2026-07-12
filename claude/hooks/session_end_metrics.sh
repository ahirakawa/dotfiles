#!/usr/bin/env bash
# SessionEnd metrics persistence to DuckDB / JSONL
# Generalized: state dir derived from payload .cwd
set -uo pipefail

trap 'exit 0' EXIT

DB_PATH="${HOME}/.claude/harness_safety.duckdb"
JSONL_PATH="${HOME}/.claude/harness_safety.jsonl"

mkdir -p "${HOME}/.claude" 2>/dev/null || true

input="$(cat 2>/dev/null || true)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
cwd_from_input="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
reason="$(printf '%s' "$input" | jq -r '.reason // "unknown"' 2>/dev/null || true)"

cwd="${cwd_from_input:-$PWD}"
project_name="$(basename "$cwd")"
STATE_DIR="${HOME}/.claude/state/${project_name}"
ARCHIVE_DIR="${STATE_DIR}/archive"
mkdir -p "$ARCHIVE_DIR" 2>/dev/null || true

if [[ -z "${session_id}" ]]; then
  echo "SessionEnd metrics: missing session_id (reason=${reason:-unknown}, cwd=${cwd_from_input:-unknown})" >&2
  exit 0
fi

state_file="${STATE_DIR}/${session_id}.json"

if [[ ! -f "$state_file" ]]; then
  echo "SessionEnd metrics: no state file at ${state_file} (project=${project_name}, reason=${reason})" >&2
  exit 0
fi

ended_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || printf '')"

# blocked/warned counts come from the audit log (single source of truth for
# all guards); the state file's counters only cover the circuit breaker.
AUDIT_LOG_PATH="${HOME}/.claude/harness_audit.jsonl"
blocked_from_audit=0
warned_from_audit=0
if [[ -f "$AUDIT_LOG_PATH" ]]; then
  blocked_from_audit="$(jq -rR --arg sid "$session_id" 'fromjson? | select((.session_id // "") == $sid) | (.decision // "")' "$AUDIT_LOG_PATH" 2>/dev/null | grep -cE '^(block|blocked)$' || true)"
  warned_from_audit="$(jq -rR --arg sid "$session_id" 'fromjson? | select((.session_id // "") == $sid) | (.decision // "")' "$AUDIT_LOG_PATH" 2>/dev/null | grep -cE '^(warn|warned)$' || true)"
fi
blocked_from_audit="${blocked_from_audit:-0}"
warned_from_audit="${warned_from_audit:-0}"

metrics_json="$(
  jq -c --arg ended_at "$ended_at" --arg project "$project_name" \
     --argjson blocked "$blocked_from_audit" --argjson warned "$warned_from_audit" '
    def object_or_empty: if type == "object" then . else {} end;
    def array_len: if type == "array" then length else 0 end;
    def calls_count:
      if (.calls | type) == "number" then .calls
      elif (.calls | type) == "array" then (.calls | length)
      elif (.history | type) == "array" then (.history | length)
      else 0 end;

    (.by_tool | object_or_empty) as $by_tool |
    (.file_edits | object_or_empty) as $file_edits |
    {
      session_id: (.session_id // ""),
      project: $project,
      started_at: (.started_at // null),
      ended_at: $ended_at,
      cwd: (.cwd // ""),
      source: (.source // ""),
      total_calls: calls_count,
      unique_tools: ($by_tool | keys | length),
      top_tool: (($by_tool | to_entries | max_by(.value) | .key) // "none"),
      blocked_count: $blocked,
      warning_count: $warned,
      files_changed: ($file_edits | keys | length),
      by_tool: $by_tool,
      baseline_status: (.baseline_status // "unknown")
    }
  ' "$state_file" 2>/dev/null || true
)"

if [[ -z "$metrics_json" ]]; then
  echo "SessionEnd metrics: failed to parse state file at ${state_file}" >&2
  exit 0
fi

summary="$(
  printf '%s' "$metrics_json" | jq -r '
    "Session \(.session_id) (\(.project)) — \(.total_calls) calls, \(.unique_tools) tools (top: \(.top_tool)), \(.files_changed) files changed, \(.blocked_count) blocked, baseline=\(.baseline_status)"
  ' 2>/dev/null || true
)"

if command -v duckdb >/dev/null 2>&1; then
  sql="$(
    printf '%s' "$metrics_json" | jq -r '
      def sql_string:
        if . == null then "NULL"
        else ([39] | implode) as $q | $q + (tostring | gsub($q; $q + $q)) + $q
        end;
      def sql_int: ((. // 0) | tonumber | tostring);
      [
        "CREATE TABLE IF NOT EXISTS session_safety (",
        "session_id TEXT PRIMARY KEY,",
        "project TEXT,",
        "started_at TIMESTAMP,",
        "ended_at TIMESTAMP,",
        "cwd TEXT,",
        "source TEXT,",
        "total_calls INTEGER,",
        "unique_tools INTEGER,",
        "top_tool TEXT,",
        "blocked_count INTEGER,",
        "warning_count INTEGER,",
        "files_changed INTEGER,",
        "by_tool JSON,",
        "baseline_status TEXT",
        ");",
        "INSERT OR REPLACE INTO session_safety VALUES (",
        (.session_id | sql_string) + ",",
        (.project | sql_string) + ",",
        (.started_at | sql_string) + ",",
        (.ended_at | sql_string) + ",",
        (.cwd | sql_string) + ",",
        (.source | sql_string) + ",",
        (.total_calls | sql_int) + ",",
        (.unique_tools | sql_int) + ",",
        (.top_tool | sql_string) + ",",
        (.blocked_count | sql_int) + ",",
        (.warning_count | sql_int) + ",",
        (.files_changed | sql_int) + ",",
        ((.by_tool | tostring) | sql_string) + "::JSON,",
        (.baseline_status | sql_string),
        ");"
      ] | join(" ")
    ' 2>/dev/null || true
  )"
  if [[ -n "$sql" ]]; then
    duckdb "$DB_PATH" -c "$sql" >/dev/null 2>&1 || printf '%s\n' "$metrics_json" >> "$JSONL_PATH" 2>/dev/null || true
  else
    printf '%s\n' "$metrics_json" >> "$JSONL_PATH" 2>/dev/null || true
  fi
else
  printf '%s\n' "$metrics_json" >> "$JSONL_PATH" 2>/dev/null || true
fi

if [[ -n "$summary" ]]; then
  printf '%s\n' "$summary"
else
  echo "Session ${session_id} (${project_name}) — metrics recorded"
fi

archive_file="${ARCHIVE_DIR}/${session_id}.json"
if [[ -e "$archive_file" ]]; then
  archive_file="${ARCHIVE_DIR}/${session_id}.$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s).json"
fi
mv "$state_file" "$archive_file" 2>/dev/null || true

exit 0
