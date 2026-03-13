# dbt 実装の罠と最適化

Sources:
- https://www.startdataengineering.com/post/uplevel-dbt-workflow/
- https://www.startdataengineering.com/post/how-to-manage-upstream-schema-changes-in-data-driven-fast-moving-company/

## Incremental Model の罠

### unique_key 未指定
- `unique_key` を設定しないと APPEND モードになり、リラン時に重複
- MERGE/DELETE+INSERT ではなく単純 INSERT になる

### is_incremental() の境界条件
```sql
-- 悪い例: 境界レコードが二重取り込み
{% if is_incremental() %}
WHERE updated_at >= (SELECT MAX(updated_at) FROM {{ this }})
{% endif %}

-- 良い例: 半開区間で境界を明確に
{% if is_incremental() %}
WHERE updated_at > (SELECT MAX(updated_at) FROM {{ this }})
{% endif %}
```
- `>=` だと MAX と同じタイムスタンプの全レコードが再取り込みされる
- ただし `>` にすると同一タイムスタンプの後続レコードが漏れるリスクもある
- 最も安全: unique_key による MERGE + `>=` の組み合わせ

### on_schema_change の未設定
- デフォルトは `'ignore'` — カラム追加されてもサイレントに無視
- `'fail'` にしないと、ソース側のスキーマ変更に気づかない
- 選択肢: `'ignore'` / `'fail'` / `'append_new_columns'` / `'sync_all_columns'`

## Snapshot (SCD) の罠

### invalidate_hard_deletes
- 未設定だと、ソースから削除されたレコードが SCD テーブルで永遠に「現行」のまま残る
- `invalidate_hard_deletes: true` で削除を検知して期間を閉じる

### updated_at カラムの信頼性
- ソースの updated_at がバルク更新で同一タイムスタンプになると変更検知が壊れる
- check strategy（カラム値の変更検知）の方が確実な場合がある

## ref() と source() の罠

### 直接テーブル名の参照
- `{{ ref('model') }}` を使わずに直接テーブル名を書くとリネージが切れる
- dbt が依存関係を認識できず、実行順序が保証されない

### cross-project ref
- 別 dbt プロジェクトのモデルを参照するには `{{ ref('project', 'model') }}` が必要
- 直接テーブル名で参照すると、プロジェクト間の依存が不可視になる

## ephemeral model の罠

- CTE に展開されるため、参照するたびにクエリが重複実行される
- デバッグ時に中間結果を確認できない
- 複数モデルから参照すると、各モデルで独立にCTEが展開される
- 基本方針: view か table を使い、ephemeral は本当に軽い変換のみ

## 開発ワークフロー最適化

### dbt run の範囲を絞る
```bash
# 悪い: 全モデル実行
dbt run

# 良い: 対象モデルだけ
dbt run --select "customer_orders"

# 良い: 対象 + 下流
dbt run --select "customer_orders+"
```

### --defer で本番データを参照
```bash
dbt run --select "customer_orders" --defer --state prod-run-artifacts
```
上流モデルがローカルにない場合、本番のマニフェストを参照してスキップ。

### スキーマ変更検知（Elementary）
- source のスキーマチェックを自動化
- 標準偏差ベースの異常検知（デフォルト閾値 3.0）
- 行数、鮮度、NULL率、min/max を監視

### Pre-commit hooks
```yaml
# .pre-commit-config.yaml
- repo: https://github.com/sqlfluff/sqlfluff
  hooks:
    - id: sqlfluff-lint
    - id: sqlfluff-fix
```
コミット前に SQL フォーマットとリントを強制。

## 上流スキーマ変更への4つの戦略

| 戦略 | 方法 | トレードオフ |
|------|------|------------|
| コミュニケーション | チーム間で事前合意 | 開発が遅くなる |
| リアクティブ | 変更後に対応 | 永続的な消火活動 |
| レビュープロセス | データチームがスキーマ設計に参加 | 上流の開発速度に影響 |
| 入力バリデーション | パイプライン入力時に検証 | 検知は早いが防止はできない |

**発見コストの法則**: 発生前 < 処理前 < 実行中 < ステークホルダー発見後 — 早いほど修正コストが低い。
