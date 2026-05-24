#!/usr/bin/env bash
# =============================================================================
# pre_config_change_guard.sh
# Claude Code ConfigChange hook (added in v2.1.141+, 2026)
#
# matcher 5 種 (user_settings / project_settings / local_settings /
# policy_settings / skills) ごとに block / warn を分ける。
#
# 監査ログ: ~/.claude/harness_audit.jsonl に1行ずつ append
# エスケープハッチ: CLAUDE_HOOK_BYPASS=1 で全 skip
#
# 参考:
# - https://code.claude.com/docs/en/hooks
# - Apollo Watcher MDM for Coding Agents (2025)
# - Comment and Control attack class (CVSS 9.4, 2026-04)
# =============================================================================

set -uo pipefail

AUDIT_LOG="${HOME}/.claude/harness_audit.jsonl"
mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || true

emit_audit() {
  local decision="$1" reason="$2"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +%s)"
  jq -nc \
    --arg ts "$ts" \
    --arg event "ConfigChange" \
    --arg session_id "$SESSION_ID" \
    --arg change_source "$CHANGE_SOURCE" \
    --arg file_path "$FILE_PATH" \
    --arg decision "$decision" \
    --arg reason "$reason" \
    '{ts:$ts, event:$event, session_id:$session_id, change_source:$change_source, file_path:$file_path, decision:$decision, reason:$reason}' \
    >> "$AUDIT_LOG" 2>/dev/null || true
}

# Escape hatch
if [ "${CLAUDE_HOOK_BYPASS:-0}" = "1" ]; then
  echo "[pre_config_change_guard] BYPASSED via CLAUDE_HOOK_BYPASS=1" >&2
  SESSION_ID="bypass" CHANGE_SOURCE="bypass" FILE_PATH="bypass" emit_audit "bypass" "env CLAUDE_HOOK_BYPASS=1"
  exit 0
fi

INPUT="$(cat 2>/dev/null || true)"
if [ -z "$INPUT" ]; then exit 0; fi

CHANGE_SOURCE="$(printf '%s' "$INPUT" | jq -r '.change_source // empty' 2>/dev/null || echo "")"
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.file_path // empty' 2>/dev/null || echo "")"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")"

if [ -z "$CHANGE_SOURCE" ]; then
  exit 0
fi

block() {
  local reason="$1"
  echo "[blocked] ConfigChange:${CHANGE_SOURCE} at ${FILE_PATH}" >&2
  echo "  Reason: $reason" >&2
  echo "  To allow this change, start Claude Code with: CLAUDE_HOOK_BYPASS=1 claude" >&2
  echo "  Or edit the file directly outside auto-mode and restart the session." >&2
  emit_audit "blocked" "$reason"
  exit 2
}

warn() {
  local reason="$1"
  echo "[warn] ConfigChange:${CHANGE_SOURCE} at ${FILE_PATH}" >&2
  echo "  $reason" >&2
  emit_audit "warned" "$reason"
}

allow() {
  local reason="$1"
  emit_audit "allowed" "$reason"
}

case "$CHANGE_SOURCE" in
  policy_settings)
    # exit 2 は無視される仕様だが、監査ログには残す
    allow "policy_settings change cannot be blocked by hook (Anthropic design)"
    exit 0
    ;;

  user_settings)
    # ~/.claude/settings.json — 全プロジェクトのセッションに影響
    # hook 配線・permissions・envVars 拡大は致命的
    block "~/.claude/settings.json affects every project session; hook tampering or permission widening here disables safety guards globally."
    ;;

  project_settings)
    # <repo>/.claude/settings.json — このプロジェクトの hook 配線
    # hook の有効化/無効化、command 上書きを伴う可能性
    block "Project settings define hook wiring and tool permissions; silent change can disable safety guards in this repo."
    ;;

  local_settings)
    # <repo>/.claude/settings.local.json — gitignore 対象、通常 allowlist
    # 影響範囲が小さく回復容易、warn のみ
    warn "local settings (gitignored) typically hold allowlists; review changes but not blocking."
    exit 0
    ;;

  skills)
    # skill / agent component — Claude が実行する instruction を含む
    # Comment-and-Control (CVSS 9.4) の主要な persistence path
    block "Skill / agent component files contain instructions Claude will execute. Comment-and-Control attacks (CVSS 9.4, 2026-04) inject persistence here."
    ;;

  *)
    # 未知の matcher — forward compatibility のため warn のみ
    warn "Unknown change_source '${CHANGE_SOURCE}' — passed through. Consider updating this hook to handle it explicitly."
    exit 0
    ;;
esac
