#!/usr/bin/env bash
set -euo pipefail

INPUT=$(cat)

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')

case "$TOOL_NAME" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // "unknown"')

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"')
AUDIT_LOG="${HOME}/.claude/harness_audit.jsonl"

audit() {
  local decision="$1" reason="$2"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +%s)"
  jq -nc \
    --arg ts "$ts" \
    --arg detector "secret_scan" \
    --arg session_id "$SESSION_ID" \
    --arg file_path "$FILE_PATH" \
    --arg decision "$decision" \
    --arg reason "$reason" \
    '{ts:$ts, detector:$detector, session_id:$session_id, file_path:$file_path, decision:$decision, reason:$reason}' \
    >> "$AUDIT_LOG" 2>/dev/null || true
}

# Escape hatch for maintenance sessions.
if [ "${CLAUDE_HOOK_BYPASS:-0}" = "1" ]; then
  audit "bypass" "CLAUDE_HOOK_BYPASS=1"
  exit 0
fi

case "$TOOL_NAME" in
  Write)
    CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // ""')
    ;;
  Edit)
    CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // ""')
    ;;
  MultiEdit)
    CONTENT=$(printf '%s' "$INPUT" | jq -r '[.tool_input.edits[]?.new_string] | join("\n")')
    ;;
esac

if [ -z "$CONTENT" ]; then
  exit 0
fi

check_pattern() {
  local name="$1"
  local pattern="$2"
  if printf '%s' "$CONTENT" | grep -E -q "$pattern"; then
    audit "blocked" "$name"
    printf '[blocked] Potential secret detected in %s (pattern: %s). Use env vars / secret manager / 1Password.\n' "$FILE_PATH" "$name" >&2
    exit 2
  fi
}

check_pattern "Anthropic API key"                 'sk-ant-(api|admin)[0-9]{2}-[A-Za-z0-9_-]{40,}'
check_pattern "OpenAI API key"                    'sk-(proj-)?[A-Za-z0-9_-]{40,}'
check_pattern "GitHub PAT"                        'ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}'
check_pattern "AWS Access Key ID"                 'AKIA[0-9A-Z]{16}'
check_pattern "AWS Secret Access Key"             'aws_secret_access_key[[:space:]]*=[[:space:]]*[A-Za-z0-9/+=]{40}'
check_pattern "Google API key"                    'AIza[0-9A-Za-z_-]{35}'
check_pattern "Slack token"                       'xox[bpars]-[0-9]+-[0-9]+-[A-Za-z0-9]+'
check_pattern "Private key (PEM)"                 '-----BEGIN (RSA |OPENSSH |EC |DSA |)PRIVATE KEY-----'
check_pattern "JDBC URL with inline password"     'jdbc:[a-z]+://[^[:space:]]*:[^@[:space:]]+@'
check_pattern "Databricks personal access token"  'dapi[a-f0-9]{32}'
check_pattern "Snowflake password literal"        "password[[:space:]]*=[[:space:]]*['\"][^'\"]{8,}['\"]"

while IFS= read -r token; do
  if [[ "$token" =~ [A-Z] ]] && [[ "$token" =~ [a-z] ]] && [[ "$token" =~ [0-9] ]]; then
    audit "warned" "high-entropy string (>=32 chars, mixed case+digits)"
    jq -n --arg ctx "[secret-scan warning] High-entropy string (>=32 chars, mixed case+digits) detected in ${FILE_PATH}. Verify it is not a secret." '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        additionalContext: $ctx
      }
    }'
    break
  fi
done < <(printf '%s' "$CONTENT" | grep -oE '[A-Za-z0-9_/+=-]{32,}' || true)

exit 0
