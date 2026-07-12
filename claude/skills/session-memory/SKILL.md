---
name: session-memory
description: セッションの要約をDuckDBに保存する。会話の終了時にユーザーが手動で呼び出す。
---

# Session Memory Save

会話の要約を生成し、`session-memory save` コマンドで DuckDB に保存する。

## 手順

### Step 1: セッション情報の特定

以下の情報を特定する:

1. **session_id**: この会話のセッションID。会話中のシステムメッセージやトランスクリプトパスから特定する。不明な場合は `~/.claude/projects/` 配下の最新の `.jsonl` ファイル名（拡張子除く）から推定する
2. **cwd**: 現在の作業ディレクトリ（`pwd`で取得）
3. **started_at**: セッション開始時刻。不明な場合は特定したトランスクリプトファイルの作成日時を使う
4. **transcript_path**: `~/.claude/projects/{escaped_cwd}/{session_id}.jsonl` のパス。escaped_cwdは作業ディレクトリのパスで `/` を `-` に置換したもの（先頭の `-` を含む）

### Step 2: 要約の生成

会話全体を振り返り、以下のJSON形式で要約を生成する:

```json
{"topics": ["topic1", "topic2"], "summary": "English summary of this session..."}
```

- **topics**: このセッションで議論した主要トピックのリスト（英語）
- **summary**: セッション全体の要約（英語、200words以内）

### Step 3: 保存コマンドの実行

```bash
session-memory save \
  --session-id <session_id> \
  --cwd <cwd> \
  --started-at <started_at> \
  --transcript-path <transcript_path> \
  --summary '<JSON summary>'
```

### Step 4: 結果の報告

保存が成功したらその旨をユーザーに伝える。
