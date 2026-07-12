#!/usr/bin/env bash
# PreToolUse guard for Bash commands.
# Blocks: exit 2 + stderr (fed back to Claude).
# Warns: collected and delivered via hookSpecificOutput.additionalContext at
# exit 0 (stderr at exit 0 never reaches Claude).
# The destructive-command rules (sudo, rm -rf, mkfs, raw disks, fork bombs,
# curl|sh) intentionally do NOT honor CLAUDE_HOOK_BYPASS — they are the hard
# safety floor. Only the protected-config-path rule is bypassable, so that
# maintenance sessions can manage ~/.claude deliberately.
set -euo pipefail

input="$(cat)"

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
if [[ "$tool_name" != "Bash" ]]; then
  exit 0
fi

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
if [[ -z "$cmd" ]]; then
  exit 0
fi

session_id="$(printf '%s' "$input" | jq -r '.session_id // "unknown"')"
AUDIT_LOG="${HOME}/.claude/harness_audit.jsonl"

audit() {
  local decision="$1" reason="$2"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +%s)"
  jq -nc \
    --arg ts "$ts" \
    --arg detector "bash_guard" \
    --arg session_id "$session_id" \
    --arg decision "$decision" \
    --arg reason "$reason" \
    --arg command_summary "${cmd:0:120}" \
    '{ts:$ts, detector:$detector, session_id:$session_id, decision:$decision, reason:$reason, command_summary:$command_summary}' \
    >> "$AUDIT_LOG" 2>/dev/null || true
}

block() {
  audit "blocked" "$1"
  printf '[block] %s\nCommand: %s\n' "$1" "$cmd" >&2
  exit 2
}

WARN_BUF=""
warn() {
  audit "warned" "$1"
  local line="[bash-guard warning] $1"
  if [[ -z "$WARN_BUF" ]]; then
    WARN_BUF="$line"
  else
    WARN_BUF="${WARN_BUF}
${line}"
  fi
}

lc="$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')"

# Fork bomb patterns
if [[ "$cmd" =~ :\(\)[[:space:]]*\{ ]] || [[ "$cmd" =~ :\|:\& ]]; then
  block "Fork bomb pattern detected."
fi

# sudo — any usage forbidden in auto mode
if [[ "$lc" =~ (^|[[:space:];&|\`\(])sudo([[:space:]]|$) ]]; then
  block "sudo is not allowed in auto mode."
fi

# rm -rf against protected roots
if [[ "$lc" =~ (^|[[:space:];&|\`\(])rm[[:space:]]+(-[a-z]*r[a-z]*f[a-z]*|-[a-z]*f[a-z]*r[a-z]*|-r[[:space:]]+-f|-f[[:space:]]+-r)([[:space:]]|$) ]]; then
  if [[ "$cmd" =~ (^|[[:space:]\"\'])(/|/\*|/etc(/|[[:space:]]|$)|/var(/|[[:space:]]|$)|/usr(/|[[:space:]]|$)|/System(/|[[:space:]]|$)|/Library(/|[[:space:]]|$)|\$HOME(/|[[:space:]]|$)?|~(/|[[:space:]]|$)?) ]]; then
    block "rm -rf against a protected path (/, \$HOME, ~, /etc, /var, /usr, /System, /Library)."
  fi
  if [[ "$cmd" =~ [[:space:]](/|\$HOME|~)[[:space:]]*$ ]]; then
    block "rm -rf against a protected path."
  fi
fi

# chmod -R 777
if [[ "$lc" =~ chmod[[:space:]]+(-[a-z]*r[a-z]*[[:space:]]+777|777[[:space:]]+-[a-z]*r[a-z]*|-r[[:space:]]+777) ]]; then
  block "chmod -R 777 is not allowed."
fi

# dd writing to raw disks
if [[ "$lc" =~ dd[[:space:]].*of=/dev/(disk|sd) ]]; then
  block "dd writing to a raw disk device is not allowed."
fi

# Redirecting / writing to raw disks
if [[ "$lc" =~ \>[[:space:]]*/dev/(sd|disk) ]] || [[ "$lc" =~ of=/dev/(sd|disk) ]]; then
  block "Writing directly to /dev/sd* or /dev/disk* is not allowed."
fi

# mkfs.*
if [[ "$lc" =~ (^|[[:space:];&|\`\(])mkfs(\.[a-z0-9]+)?([[:space:]]|$) ]]; then
  block "mkfs.* (filesystem creation) is not allowed."
fi

# curl|bash, wget|sh — piping remote to shell
if [[ "$lc" =~ (curl|wget)[[:space:]].*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh)([[:space:]]|$) ]]; then
  block "Piping remote downloads into a shell is not allowed."
fi

# Bash-mediated writes to protected agent-config paths. The Edit/Write tools
# are guarded by pre_edit_config_guard.sh; without this rule a shell
# redirection or cp/mv/tee would silently bypass that guard.
# Bypassable via CLAUDE_HOOK_BYPASS=1 (maintenance tier).
if [[ "${CLAUDE_HOOK_BYPASS:-0}" != "1" ]]; then
  redir_cfg_pat='>>?[[:space:]]*[^[:space:]]*(\.claude/(hooks|agents|commands|skills)/|\.claude/settings[^[:space:]]*\.json|\.git/hooks/)|>>?[[:space:]]*([^[:space:]]*/)?claude\.md([[:space:]]|$)'
  cpmv_cfg_pat='(^|[;&|`(][[:space:]]*|[[:space:]])(cp|mv|install|ln|tee)[[:space:]][^;&|]*(\.claude/(hooks|agents|commands|skills)(/|[[:space:]]|$)|\.claude/settings[^[:space:]]*\.json|(^|[/[:space:]])claude\.md([[:space:]]|$)|\.git/hooks/)'
  if printf '%s' "$lc" | grep -Eq "$redir_cfg_pat"; then
    block "Shell redirection into a protected config path (.claude/*, CLAUDE.md, .git/hooks). Use the Edit/Write tools so config guards apply, or CLAUDE_HOOK_BYPASS=1 for maintenance."
  fi
  if printf '%s' "$lc" | grep -Eq "$cpmv_cfg_pat"; then
    block "cp/mv/ln/tee/install touching a protected config path (.claude/*, CLAUDE.md, .git/hooks). Use the Edit/Write tools so config guards apply, or CLAUDE_HOOK_BYPASS=1 for maintenance."
  fi
fi

# git push --force / -f to protected branches
if [[ "$lc" =~ git[[:space:]]+push ]]; then
  has_force=0
  has_force_with_lease=0
  if [[ "$lc" =~ --force-with-lease ]]; then
    has_force_with_lease=1
  fi
  if [[ "$lc" =~ (^|[[:space:]])--force([[:space:]]|$) ]] || [[ "$lc" =~ (^|[[:space:]])-f([[:space:]]|$) ]]; then
    has_force=1
  fi

  protected_branch=0
  if [[ "$lc" =~ (^|[[:space:]:])(main|master|production|prod|release)([[:space:]]|$|:) ]]; then
    protected_branch=1
  fi

  if [[ "$has_force" -eq 1 && "$protected_branch" -eq 1 ]]; then
    block "git push --force to a protected branch (main/master/production/prod/release)."
  fi

  if [[ "$has_force_with_lease" -eq 1 && "$protected_branch" -eq 1 ]]; then
    block "git push --force-with-lease to a protected branch is not allowed."
  fi

  if [[ "$has_force" -eq 1 ]]; then
    warn "git push --force detected (target is not a protected branch)."
  fi
fi

# Destructive SQL piped to psql/databricks/dbt
if [[ "$lc" =~ (drop[[:space:]]+database|drop[[:space:]]+schema|truncate[[:space:]]+table) ]]; then
  if [[ "$lc" =~ \|[[:space:]]*(psql|databricks|dbt)([[:space:]]|$) ]] \
     || [[ "$lc" =~ (psql|databricks|dbt)[[:space:]].*(-c|--command|-f|--file|-q|--sql|run-sql) ]]; then
    block "Destructive SQL (DROP DATABASE / DROP SCHEMA / TRUNCATE TABLE) piped to psql/databricks/dbt."
  fi
fi

# Warnings (non-blocking, delivered as additionalContext below)
if [[ "$lc" =~ git[[:space:]]+reset[[:space:]]+(--hard|.*[[:space:]]--hard) ]]; then
  warn "git reset --hard will discard local changes."
fi

if [[ "$lc" =~ npm[[:space:]]+publish ]]; then
  warn "npm publish will release a package to the registry."
fi

if [[ "$lc" =~ (pip|twine)[[:space:]]+upload ]] || [[ "$lc" =~ python[[:space:]]+-m[[:space:]]+twine[[:space:]]+upload ]]; then
  warn "pip/twine upload will publish to PyPI."
fi

if [[ "$lc" =~ terraform[[:space:]]+(apply|destroy) ]]; then
  warn "terraform apply/destroy mutates real infrastructure."
fi

if [[ "$lc" =~ kubectl[[:space:]]+delete ]]; then
  warn "kubectl delete removes cluster resources."
fi

if [[ -n "$WARN_BUF" ]]; then
  jq -n --arg ctx "$WARN_BUF" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: $ctx
    }
  }'
fi

exit 0
