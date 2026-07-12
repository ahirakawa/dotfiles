#!/usr/bin/env bash
set -euo pipefail

INPUT="$(cat)"

SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")"
AUDIT_LOG="${HOME}/.claude/harness_audit.jsonl"

audit() {
  local decision="$1" reason="$2"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +%s)"
  jq -nc \
    --arg ts "$ts" \
    --arg detector "edit_config_guard" \
    --arg session_id "$SESSION_ID" \
    --arg file_path "${FILE_PATH:-}" \
    --arg decision "$decision" \
    --arg reason "$reason" \
    '{ts:$ts, detector:$detector, session_id:$session_id, file_path:$file_path, decision:$decision, reason:$reason}' \
    >> "$AUDIT_LOG" 2>/dev/null || true
}

# Escape hatch for maintenance: set CLAUDE_HOOK_BYPASS=1 to skip this guard.
# Use sparingly — every bypass is audited.
if [ "${CLAUDE_HOOK_BYPASS:-0}" = "1" ]; then
  echo "[pre_edit_config_guard] BYPASSED via CLAUDE_HOOK_BYPASS=1" >&2
  audit "bypass" "CLAUDE_HOOK_BYPASS=1"
  exit 0
fi

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"

case "$TOOL_NAME" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')"

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Resolve ~ to $HOME
case "$FILE_PATH" in
  "~"|"~/"*) FILE_PATH="${HOME}${FILE_PATH#\~}" ;;
esac

block() {
  local reason="$1"
  audit "blocked" "$reason"
  printf '[blocked] %s Ask user explicitly before editing: %s\n' "$reason" "$FILE_PATH" >&2
  exit 2
}

# Non-blocking warning via additionalContext (stderr at exit 0 never reaches Claude).
warn() {
  local reason="$1"
  audit "warned" "$reason"
  jq -n --arg ctx "[config-guard warning] ${reason} File: ${FILE_PATH}" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: $ctx
    }
  }'
  exit 0
}

# Case-sensitive substring / glob matching using bash [[ ]] with patterns.
# We match anywhere in the tree by checking for the segment surrounded by separators or at edges.

# Helper: returns 0 if $1 (haystack) contains pattern segment $2 at any depth
contains_path() {
  local hay="$1" needle="$2"
  case "$hay" in
    *"/$needle"|*"/$needle/"*|"$needle"|"$needle/"*) return 0 ;;
  esac
  return 1
}

# .vscode/settings.json — CVE-2025-53773 persistent backdoor risk
if contains_path "$FILE_PATH" ".vscode/settings.json"; then
  block "CVE-2025-53773: .vscode/settings.json can persist malicious tasks/commands across sessions (persistent backdoor risk)."
fi

# .vscode/tasks.json, .vscode/launch.json
if contains_path "$FILE_PATH" ".vscode/tasks.json"; then
  block ".vscode/tasks.json can auto-run commands on workspace open (persistent execution risk)."
fi
if contains_path "$FILE_PATH" ".vscode/launch.json"; then
  block ".vscode/launch.json controls debug launch configs; can be abused to execute arbitrary commands."
fi

# .cursorrules
case "$FILE_PATH" in
  *"/.cursorrules"|".cursorrules")
    block ".cursorrules persists AI instructions across all Cursor sessions (instruction persistence risk)."
    ;;
esac

# .cursor/rules/*
case "$FILE_PATH" in
  *"/.cursor/rules/"*|".cursor/rules/"*)
    block ".cursor/rules/* persists AI instructions across all sessions (instruction persistence risk)."
    ;;
esac

# CLAUDE.md (any location)
case "$FILE_PATH" in
  *"/CLAUDE.md"|"CLAUDE.md")
    block "CLAUDE.md edits persist instructions across all future Claude sessions (instruction persistence risk)."
    ;;
esac

# .claude/settings.json, .claude/settings.local.json
if contains_path "$FILE_PATH" ".claude/settings.json"; then
  block ".claude/settings.json controls Claude Code permissions/hooks (privilege escalation risk)."
fi
if contains_path "$FILE_PATH" ".claude/settings.local.json"; then
  block ".claude/settings.local.json controls Claude Code permissions/hooks (privilege escalation risk)."
fi

# .claude/hooks/*
case "$FILE_PATH" in
  *"/.claude/hooks/"*|".claude/hooks/"*)
    block ".claude/hooks/* tampering can disable safety guards or inject malicious behavior (hook tampering risk)."
    ;;
esac

# .claude/agents/*
case "$FILE_PATH" in
  *"/.claude/agents/"*|".claude/agents/"*)
    block ".claude/agents/* defines subagent prompts; persists instructions across sessions (instruction persistence risk)."
    ;;
esac

# .claude/commands/*
case "$FILE_PATH" in
  *"/.claude/commands/"*|".claude/commands/"*)
    block ".claude/commands/* defines slash commands; can be abused to run arbitrary actions (command persistence risk)."
    ;;
esac

# .git/hooks/*
case "$FILE_PATH" in
  *"/.git/hooks/"*|".git/hooks/"*)
    block ".git/hooks/* runs on git operations; classic backdoor for code execution (git hook backdoor risk)."
    ;;
esac

# .gitconfig (any), ~/.gitconfig already resolved
case "$FILE_PATH" in
  *"/.gitconfig"|".gitconfig")
    block ".gitconfig can define malicious aliases or core.hooksPath (git config persistence risk)."
    ;;
esac

# .env, .env.*, *.env  (any env file)
BASENAME="${FILE_PATH##*/}"
case "$BASENAME" in
  ".env"|".env."*|*.env)
    block "env files contain secrets; edits can leak or inject credentials (secret exposure risk)."
    ;;
esac

# ~/.ssh/* (HOME already substituted)
case "$FILE_PATH" in
  "$HOME/.ssh/"*)
    block "~/.ssh/* controls SSH keys and authorized_keys (credential/persistence risk)."
    ;;
esac

# ~/.aws/credentials, ~/.aws/config
case "$FILE_PATH" in
  "$HOME/.aws/credentials"|"$HOME/.aws/config")
    block "~/.aws/{credentials,config} holds AWS credentials/profiles (cloud credential risk)."
    ;;
esac

# /etc/* (any system file)
case "$FILE_PATH" in
  "/etc/"*)
    block "/etc/* is system configuration; edits affect all users (system-wide persistence risk)."
    ;;
esac

# Shell init persistence
case "$FILE_PATH" in
  "$HOME/.zshrc"|"$HOME/.bashrc"|"$HOME/.profile"|"$HOME/.zprofile")
    block "shell init files run on every new shell; classic persistence vector (shell persistence risk)."
    ;;
esac

# pyproject.toml, package.json, requirements.txt — warn (dependency/build injection risk)
case "$BASENAME" in
  "pyproject.toml")
    warn "pyproject.toml edits to [project.scripts]/[build-system] can inject build-time/script execution (dependency injection risk)."
    ;;
  "package.json")
    warn "package.json scripts/dependencies can execute on install (dependency injection risk)."
    ;;
  "requirements.txt")
    warn "requirements.txt changes can pull in malicious packages (dependency injection risk)."
    ;;
esac

exit 0
