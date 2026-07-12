---
name: distill
description: Claude Codeセッションのトランスクリプトから「学びの濃いセッション」を抽出し、判断の教訓をpitfalls/メモリ/Skillルールに蒸留する定期ワークフロー。ユーザーが「蒸留して」「distillを回して」と言ったとき、または週次の振り返りで起動する。Fable期間中はFableセッションの判断分岐を資産化する主経路。
---

# distill — セッション蒸留ワークフロー

トランスクリプト(`~/.claude/projects/**/*.jsonl`)をDuckDBに取り込み、学びの濃いセッションを特定して、教訓をテキスト資産(pitfalls.md / メモリ / Skillルール)に落とす。

**設計方針**: ライブ記録はしない。Claude Codeが全セッションを自動でトランスクリプト保存しているので、蒸留時にバッチ取り込みする(DuckDB単一ライター問題を回避。並列セッションへの仕込みは一切不要)。サブエージェントのトランスクリプト(`<session_id>/subagents/`)はランキング対象外——親セッションの蒸留時に必要なら参照する。

## 前提

- `duckdb` Pythonパッケージ(session-memoryと同じ環境に導入済み)
- DB既定パス: `~/claude-skills/distill/distill.duckdb`(環境変数 `DISTILL_DUCKDB_PATH` で上書き可)

## ワークフロー(週1目安)

### Step 1: 取り込み(増分)

```bash
python3 ~/.claude/skills/distill/ingest.py ingest
```

前回から変更のあったトランスクリプトだけ再解析される。

### Step 2: 候補の特定

```bash
python3 ~/.claude/skills/distill/ingest.py rank --limit 10
```

未蒸留セッションをスコア順に表示する。スコアの中身: ツールエラー×3 + 中断×5 + 同一ツール連続(4回目以降)×2 + ユーザープロンプト数 + 時間係数。**エラー・中断・反復 = 判断分岐があった痕跡**という仮説に基づく。重みは `ingest.py` の `RANK_VIEW` を編集して調整する。

### Step 3: 蒸留(上位1〜3件)

各セッションについて:

1. `transcript_path` のJSONLを読む(大きい場合はサブエージェントに委譲し、以下の観点で要約させる):
   - **判断分岐**: どこで方針転換したか。転換前に何を確認したか
   - **失敗と回復**: エラーの原因は何で、何を試して、何が効いたか
   - **最初に知っていれば遠回りしなかったこと**
2. 抽出した教訓を着地させる:
   - 繰り返す罠 → `~/.claude/skills/fable-protocol/references/pitfalls.md` に追記(状況/兆候/誤り/対処の形式)
   - プロジェクト固有の知見 → 該当プロジェクトのメモリに保存
   - 手順化できる型 → /retrospective-codify でSkill/ルール化
3. 処理済みマークを付ける:

```bash
python3 ~/.claude/skills/distill/ingest.py mark --session-id <ID> --note "pitfalls 2件追記"
```

### Step 4: 報告

蒸留したセッション数、追記した教訓の件数と着地先を報告する。

## 補助クエリ

DBを直接見たいとき:

```bash
duckdb ~/claude-skills/distill/distill.duckdb -readonly \
  "SELECT model, count(*), round(avg(n_tool_errors),1) FROM sessions GROUP BY 1"
```

- `sessions` — セッション単位のメトリクス
- `tool_stats` — セッション×ツールの呼び出し数/エラー数
- `learning_rank` — スコア付きビュー
- `distilled` — 蒸留済み管理

## Fable期間中の運用メモ

- Fableセッション(`model LIKE 'claude-fable%'`)は判断の質が高いため、エラーが少なくスコアが低くても蒸留価値がある。`rank --all` と併せて `WHERE model LIKE 'claude-fable%'` で別途拾うこと
- 目的は「Fableが回避した判断分岐」の言語化。Opusなら踏んでいた罠をFableがどう避けたかは、エラーログには残らない——転換点の前後の思考(要約)とツール選択順に現れる
