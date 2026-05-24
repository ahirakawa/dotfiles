#!/usr/bin/env bash
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

block() {
  printf '[block] %s\nCommand: %s\n' "$1" "$cmd" >&2
  exit 2
}

warn() {
  printf '[warn] %s\nCommand: %s\n' "$1" "$cmd" >&2
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

# Warnings (non-blocking)
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

exit 0
