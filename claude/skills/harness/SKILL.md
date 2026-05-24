---
name: harness
description: Claude Code セッションの観測ハーネス。run の開始/終了、tool 呼び出し、loop 検出、token/cost 予算、quality gate 結果を DuckDB に記録する。Plan-Execute-Verify (PEV) のテンプレも提供する。実装中のセッションでは start で run_id を発行し、要所で record-tool / update-usage / record-gate を呼ぶ。
---

# Harness — Claude Code 観測スキル

セッションの暴走パターンと品質ゲートを DuckDB（既定 `harness.duckdb`）に記録する stub。`session-memory` 派生だが保存先は別ファイル。

## いつ呼ぶか

- **session 開始**: `harness start` で run_id を発行する
- **長い実装ループの中**: 数 step ごとに `harness record-tool` を呼ぶ（loop 検出のため。毎 step 呼ぶ必要はない、明らかに繰り返している箇所だけで十分）
- **LLM API 呼び出し直後**: `harness update-usage` で token / cost を更新（exit code 3 が返ったら abort）
- **品質ゲート（cargo test, clippy, scala-cli test, bun test, pytest など）の直後**: `harness record-gate`
- **session 終了**: `harness end --status completed|aborted|manual_intervention`

## 前提

- `duckdb` CLI が `$PATH` にある（macOS なら `brew install duckdb` 済みの想定）
- `python3` が `$PATH` にある
- 環境変数 `HARNESS_DUCKDB_PATH` で保存先を指定（未設定なら CWD の `./harness.duckdb`）。
  プロジェクト単位で固定したい場合は、そのプロジェクトの `.claude/settings.json` の `env` で設定する。

## 初回セットアップ

```bash
python3 ~/.claude/skills/harness/cli.py init
```

## 使い方

### run の開始

```bash
RUN_ID=$(python3 ~/.claude/skills/harness/cli.py start \
  --agent-type claude-code \
  --task "<実装するタスクの一行サマリ>" \
  --language rust)
```

### tool 呼び出しを記録（loop 検出付き）

```bash
python3 ~/.claude/skills/harness/cli.py record-tool \
  --run-id "$RUN_ID" \
  --tool "Edit" \
  --args-json '{"file":"src/main.rs","old":"...","new":"..."}' \
  --result "ok"
# exit code 3 → 直近 6 step で同じ args_hash が 3 回以上 → abort 推奨
```

### token / cost を更新（予算超過判定）

```bash
python3 ~/.claude/skills/harness/cli.py update-usage \
  --run-id "$RUN_ID" \
  --tokens 12345 \
  --cost 0.34
# exit code 3 → token 200k or cost $5 を超えた → abort 推奨
```

### quality gate を記録

```bash
python3 ~/.claude/skills/harness/cli.py record-gate \
  --run-id "$RUN_ID" \
  --gate "cargo_test" \
  --passed true \
  --output "12 passed, 0 failed"
```

### run の終了

```bash
python3 ~/.claude/skills/harness/cli.py end \
  --run-id "$RUN_ID" \
  --status completed
```

## Abort 条件まとめ

| 条件 | 検出 | exit code |
|---|---|---|
| 直近 6 step で同 args_hash が 3 回以上 | `record-tool` | 3 |
| total_tokens > 200,000 | `update-usage` / `check-budget` | 3 |
| total_cost_usd > $5.00 | `update-usage` / `check-budget` | 3 |

予算しきい値（200k tokens / $5）と loop 検出窓（直近 6 step / 同一 3 回）は `cli.py` 冒頭の定数で調整する。
exit code 3 が返った時点で **そのまま実装を続けず、ユーザーに通知して停止**する。

## PEV プロンプト雛形

### Plan（上位モデル想定）

```
あなたは本タスクの Plan フェーズを担当する。

## 現在の状況
- 言語/スタック: <language>
- 残タスク: <task>
- 残時間: <hours>
- 累計黄信号: <N>

## やること
1. このタスクを 30 分以内に分解できる単位の小タスクに分ける（最大 5 件）
2. 各小タスクで使う API / ライブラリ / 設計判断を決める
3. **撤退条件**を再確認: このタスクで踏みそうな撤退条件はどれか
4. Verify 時にチェックすべき品質ゲート（test, lint など）を列挙する

## 出力
JSON で {"subtasks": [...], "decisions": [...], "risks": [...], "gates": [...]}
```

### Verify（上位モデル想定）

```
あなたは本タスクの Verify フェーズを担当する。

## やること
直前の Execute フェーズの成果物を、Plan で定めた品質ゲートに沿って検証する。

1. Plan で列挙した gates を順に実行（または該当コマンドを提示）
2. 各 gate の結果を `harness record-gate` で記録するコマンドを生成
3. 失敗 gate がある場合: 失敗理由 / 修正提案 / 撤退判断（黄信号該当か）を出力
4. **コードを直接修正しない**。修正は Execute に戻す

## 出力
- gates: [{name, passed, evidence}]
- next_action: "proceed" | "fix_in_execute" | "retreat_to_next_stage"
- retreat_yellow_flag: true | false
```
