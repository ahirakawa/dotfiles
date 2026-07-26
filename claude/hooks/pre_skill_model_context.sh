#!/usr/bin/env bash
# PreToolUse (Skill): 実行モデルに応じた補正を skill の発火時だけ注入する
#
# 背景:
#   fable-protocol は Opus 5 向けにチューンしてある (自己検証の明示指示を置かない、
#   サブエージェント委譲に上限を切る)。Fable 5 はこの2点が逆で、検証ハーネスは
#   明示的に立てさせ、委譲はむしろ推奨する必要がある。
#
#   モデル判定を prompt 内の分岐で書くとモデルの自己申告に依存して当たらない。
#   hook のペイロードでモデルを取れるのは SessionStart だけ (任意) で /model 切替にも
#   追随しないため、statusline が毎レンダ書く ~/.claude/state/current-model を唯一の
#   判定経路にしている。
#
# 出力しないケースでは静かに exit 0 する。判定材料が無いときも何もしない
# (誤った補正を入れるより、skill の既定 = Opus 5 向けのまま走らせるほうが安全)。

set -uo pipefail

MODEL_STATE="${CLAUDE_MODEL_STATE:-$HOME/.claude/state/current-model}"
STALE_SEC="${CLAUDE_MODEL_STATE_STALE_SEC:-600}"

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || printf '{}')"
printf '%s' "$input" | jq empty >/dev/null 2>&1 || exit 0

# matcher を ".*" に変えても安全なように、ツール名はスクリプト側でも見る
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
[ "$tool_name" = "Skill" ] || exit 0

skill="$(printf '%s' "$input" | jq -r '.tool_input.skill // empty')"
[ "$skill" = "fable-protocol" ] || exit 0

[ -f "$MODEL_STATE" ] || exit 0

# 鮮度チェック: statusline が止まっていれば内容は信用しない
mtime="$(stat -f %m "$MODEL_STATE" 2>/dev/null || stat -c %Y "$MODEL_STATE" 2>/dev/null || echo 0)"
now="$(date +%s)"
[ "$mtime" -gt 0 ] || exit 0
[ $((now - mtime)) -le "$STALE_SEC" ] || exit 0

model_id="$(head -n1 "$MODEL_STATE" 2>/dev/null | tr -d '[:space:]')"

# model.id には "claude-opus-5[1m]" のようにコンテキスト長サフィックスが付くため前方一致で見る
case "$model_id" in
  claude-fable-5*|claude-mythos-5*) ;;
  *) exit 0 ;;
esac

read -r -d '' CONTEXT <<'EOF'
fable-protocol は Opus 5 向けにチューンされている。いま Fable 系モデルで実行しているため、以下の2点を上書きすること。

1. 検証ハーネスを実装より先に立てる。実行コマンド・テスト・lint・画面確認の手順を決めてから書き始め、周期的に自分で回す。長時間のビルドでは別コンテキストの検証用サブエージェントを使うほうが自己批評より当たる。
   (skill 本体が検証指示を置いていないのは Opus 5 が過剰検証しないための措置であり、Fable では逆に明示が必要)

2. サブエージェントへの委譲は抑制しない。独立したサブタスクは積極的に委譲し、完了を待ち合わせずに非同期で進める。サブエージェントが脱線した場合や文脈が足りていない場合にだけ介入する。
   (skill 本体の「上限を切る」は Opus 5 の使いすぎを抑えるための措置)

3. 進捗を報告する前に、各主張をこのセッションのツール結果と突き合わせる。証拠を指せないものは未検証と明示する。
EOF

jq -n --arg ctx "$CONTEXT" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: $ctx
  }
}'
