#!/bin/bash
# Claude Code statusline: プラン利用率(5h/週) + Fableトークン集計 + キャリブレーションログ
#
# settings.json 設定例:
#   "statusLine": { "type": "command", "command": "bash /path/to/statusline-fable.sh" }
#
# 表示例:
#   Fable 5 | ctx 12% | 5h 42% ↺14:30 | wk 67% ↺07/23 09:00 | F今日 1.2M / 累計 8.6M tok
#
# 副作用: 表示のついでに ~/.claude/fable-usage-log.tsv へ観測ログを1行追記する
# (60秒スロットル)。後で「1%あたり何トークンか」の傾き推定に使う。

set -u

STATS="${FABLE_STATUSLINE_STATS:-$HOME/.claude/stats-cache.json}"
LOG="${FABLE_STATUSLINE_LOG:-$HOME/.claude/fable-usage-log.tsv}"
LOG_INTERVAL=60           # 秒。これより短い間隔ではログを追記しない
FABLE_ID="claude-fable-5"

input=$(cat)

model=$(jq -r '.model.display_name // .model.id // "?"' <<<"$input")
model_id=$(jq -r '.model.id // "?"' <<<"$input")
ctx=$(jq -r '.context_window.used_percentage // empty' <<<"$input")
h5=$(jq -r '.rate_limits.five_hour.used_percentage // empty' <<<"$input")
h5r=$(jq -r '.rate_limits.five_hour.resets_at // empty' <<<"$input")
d7=$(jq -r '.rate_limits.seven_day.used_percentage // empty' <<<"$input")
d7r=$(jq -r '.rate_limits.seven_day.resets_at // empty' <<<"$input")

# 使用率に応じた色 (緑<50 / 黄50-79 / 赤>=80)
paint() {
  local p=${1%%.*}
  if [ "$p" -ge 80 ]; then printf '\033[31m'
  elif [ "$p" -ge 50 ]; then printf '\033[33m'
  else printf '\033[32m'; fi
}

# トークン数を 850k / 1.2M 表記にする
fmt_tok() {
  awk -v n="$1" 'BEGIN {
    if (n >= 1000000) printf "%.1fM", n / 1000000
    else if (n >= 1000) printf "%.0fk", n / 1000
    else printf "%d", n
  }'
}

# 使用率+リセット時刻の1セグメントを組み立てる ($1=ラベル $2=% $3=epoch $4=日付表示するか)
seg() {
  local label=$1 pct=$2 reset=$3 with_date=$4 out reset_s=""
  if [ -z "$pct" ]; then
    printf '%s --' "$label"
    return
  fi
  if [ -n "$reset" ]; then
    if [ "$with_date" = "y" ]; then
      reset_s=" ↺$(date -r "$reset" +%m/%d\ %H:%M 2>/dev/null)"
    else
      reset_s=" ↺$(date -r "$reset" +%H:%M 2>/dev/null)"
    fi
  fi
  printf '%s %s%d%%\033[0m%s' "$label" "$(paint "$pct")" "${pct%%.*}" "$reset_s"
}

# --- Fableトークン集計 (stats-cache.json) ---
# 累計 = modelUsage の入出力トークン (キャッシュ読み書きは含めない)
# 今日 = dailyModelTokens の当日エントリ (反映が1-2日遅れることがある)
fable_part=""
if [ -f "$STATS" ]; then
  today=$(date +%F)
  IFS=$'\t' read -r cum today_tok <<<"$(jq -r --arg m "$FABLE_ID" --arg d "$today" '
    [ ((.modelUsage[$m].inputTokens // 0) + (.modelUsage[$m].outputTokens // 0)),
      ((.dailyModelTokens // [] | map(select(.date == $d)) | .[0].tokensByModel[$m]) // 0)
    ] | @tsv' "$STATS" 2>/dev/null)"
  if [ -n "${cum:-}" ] && [ "$cum" != "0" ]; then
    fable_part=" | F今日 $(fmt_tok "${today_tok:-0}") / 累計 $(fmt_tok "$cum") tok"
  fi
fi

# --- 表示 ---
line="$model"
[ -n "$ctx" ] && line="$line | ctx $(paint "$ctx")${ctx%%.*}%\033[0m"
line="$line | $(seg "5h" "$h5" "$h5r" n) | $(seg "wk" "$d7" "$d7r" y)$fable_part"
printf '%b\n' "$line"

# --- キャリブレーションログ ---
# ts, model_id, 5h%, 5h reset, wk%, wk reset, modelUsage全体(JSON)
# modelUsage を丸ごと持つのは、後からモデル別のΔトークンとΔ%を突き合わせるため
if [ -n "$h5" ] || [ -n "$d7" ]; then
  now=$(date +%s)
  last=0
  [ -f "$LOG" ] && last=$(stat -f %m "$LOG" 2>/dev/null || echo 0)
  if [ $((now - last)) -ge "$LOG_INTERVAL" ]; then
    mu='{}'
    [ -f "$STATS" ] && mu=$(jq -c '.modelUsage // {}' "$STATS" 2>/dev/null || echo '{}')
    [ -f "$LOG" ] || printf 'ts\tmodel_id\tfive_hour_pct\tfive_hour_resets_at\tseven_day_pct\tseven_day_resets_at\tmodel_usage_json\n' >"$LOG"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$now" "$model_id" "${h5:--}" "${h5r:--}" "${d7:--}" "${d7r:--}" "$mu" >>"$LOG"
  fi
fi
