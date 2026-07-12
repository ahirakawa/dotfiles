#!/usr/bin/env bash
# SessionStart baseline + progress restore
# Generalized: state dir derived from payload .cwd
set -uo pipefail

input="$(cat 2>/dev/null || printf '{}')"
if ! printf '%s' "$input" | jq empty >/dev/null 2>&1; then
  input='{}'
fi

session_id="$(printf '%s' "$input" | jq -r '.session_id // "unknown-session"')"
source="$(printf '%s' "$input" | jq -r '.source // "startup"')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
if [ -z "$cwd" ]; then
  cwd="$(pwd 2>/dev/null || printf '%s' "$HOME")"
fi

project_name="$(basename "$cwd")"
STATE_DIR="${HOME}/.claude/state/${project_name}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
state_file="${STATE_DIR}/${session_id}.json"
started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")"

if [ ! -f "$state_file" ]; then
  jq -n \
    --arg session_id "$session_id" \
    --arg started_at "$started_at" \
    --arg source "$source" \
    --arg cwd "$cwd" \
    '{
      session_id: $session_id,
      started_at: $started_at,
      source: $source,
      cwd: $cwd,
      calls: 0,
      history: [],
      by_tool: {},
      file_edits: {},
      blocked_count: 0,
      warnings: [],
      baseline_status: "unknown"
    }' > "$state_file" 2>/dev/null || true
fi

branch="unknown"
status_porcelain=""
uncommitted_count="0"
changed_first5=""
last_commits=""

if [ -d "$cwd/.git" ] || [ -d "$cwd" ]; then
  branch="$(cd "$cwd" 2>/dev/null && git branch --show-current 2>/dev/null)"
  if [ -z "$branch" ]; then
    branch="$(cd "$cwd" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null)"
  fi
  if [ -z "$branch" ]; then
    branch="unknown"
  fi

  status_porcelain="$(cd "$cwd" 2>/dev/null && git status --porcelain 2>/dev/null || true)"
  if [ -n "$status_porcelain" ]; then
    uncommitted_count="$(printf '%s\n' "$status_porcelain" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
    changed_first5="$(printf '%s\n' "$status_porcelain" | sed -n '1,5p')"
  fi

  last_commits="$(cd "$cwd" 2>/dev/null && git log -3 --oneline 2>/dev/null || true)"
fi

if [ -z "$last_commits" ]; then
  last_commits="none"
fi

progress="none"
if [ -f "$cwd/claude-progress.txt" ]; then
  progress="$(head -c 2000 "$cwd/claude-progress.txt" 2>/dev/null || true)"
  if [ -z "$progress" ]; then
    progress="none"
  fi
fi

baseline_status="skipped"
baseline_kind="none"

timeout_bin=""
if command -v timeout >/dev/null 2>&1; then
  timeout_bin="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  timeout_bin="gtimeout"
fi

# Baseline is project-type aware: only run the check that belongs to this
# project (a dbt parse in a Rust repo is 30s of noise and a false "red").
if [ -f "$cwd/dbt_project.yml" ] || [ -f "$cwd/dbt/dbt_project.yml" ]; then
  baseline_kind="dbt parse"
  if command -v dbt >/dev/null 2>&1 && [ -n "$timeout_bin" ]; then
    dbt_output="$(cd "$cwd" 2>/dev/null && "$timeout_bin" 30 dbt parse --no-version-check 2>&1 | tail -20)"
    dbt_exit=$?
    if [ "$dbt_exit" -eq 0 ]; then
      baseline_status="ok"
    elif [ "$dbt_exit" -eq 124 ]; then
      baseline_status="skipped (timeout)"
    else
      baseline_status="red"
    fi
  fi
elif [ -f "$cwd/Cargo.toml" ]; then
  baseline_kind="cargo check"
  if command -v cargo >/dev/null 2>&1 && [ -n "$timeout_bin" ]; then
    cargo_output="$(cd "$cwd" 2>/dev/null && "$timeout_bin" 30 cargo check --quiet 2>&1 | tail -5)"
    cargo_exit=$?
    if [ "$cargo_exit" -eq 0 ]; then
      baseline_status="ok"
    elif [ "$cargo_exit" -eq 124 ]; then
      baseline_status="skipped (timeout)"
    else
      baseline_status="red"
    fi
  fi
fi

if [ -f "$state_file" ]; then
  tmp_state="${state_file}.tmp.$$"
  jq --arg baseline_status "$baseline_status" '.baseline_status = $baseline_status' "$state_file" > "$tmp_state" 2>/dev/null && mv "$tmp_state" "$state_file" 2>/dev/null || rm -f "$tmp_state" 2>/dev/null || true
fi

commits_block="$(printf '%s\n' "$last_commits" | sed 's/^/- /')"

working_tree_block=""
if [ -n "$changed_first5" ]; then
  working_tree_block="$(printf '\n### Working tree\n%s\n' "$(printf '%s\n' "$changed_first5" | sed 's/^/- /')")"
fi

context="$(cat <<EOF
## Session boot (auto-mode safety harness)
- project: $project_name
- cwd: $cwd
- branch: $branch (uncommitted: $uncommitted_count files)
- baseline (${baseline_kind}): $baseline_status

### Last commits
$commits_block
$working_tree_block
### Resumed progress
$progress

### Auto-mode safety reminders
- Edits to CLAUDE.md/.claude/* and skill files are blocked. Ask user before suggesting them.
- Budget: 300 tool calls per session; loop detection at 8 consecutive identical calls (same tool+args).
- Secrets matching common patterns (AWS, Anthropic, GitHub, etc.) are blocked on write.
EOF
)"

jq -n --arg context "$context" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $context
  }
}'

exit 0
