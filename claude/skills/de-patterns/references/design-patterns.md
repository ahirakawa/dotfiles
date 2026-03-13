# Data Pipeline Design Patterns

Source: https://www.startdataengineering.com/post/design-patterns/

## パターン分類

パイプライン設計は 抽出 × 振る舞い × 構造 の3軸の組み合わせで決まる。

## 抽出パターン

### Time Ranged Pull
指定時間範囲のデータだけを取得。高速だが、UPSERTが必要。
- 罠: ソースが non-replayable（現在の状態しか返さないAPI等）だと、リランで結果が変わる

### Full Snapshot
毎回全量取得。ディメンション/マスター系に適する。
- 罠: ファクトデータ（クリックストリーム等）に使うとコスト爆発
- 罠: スキーマ変更でパイプラインが壊れる

### Lookback
過去N期間の集約メトリクスを再計算。MAU等に適する。
- 罠: Late-arriving events でランごとにメトリクスが大きく変動する

### Streaming
レコード単位のリアルタイム処理。不正検知等に必須。
- 罠: バックプレッシャー、チェックポイント、ダウンタイムなしデプロイが必要

## 振る舞いパターン

### Idempotent（冪等）
同じ入力で何度実行しても同じ出力。最も重要なパターン。
- 前提条件: Replayable source + Overwritable sink の両方が必要
- 実装: Delete-Write パターン（既存データを消してから書く）

```sql
-- 冪等な書き込み
DELETE FROM target_table WHERE day = '{{ ds }}';
INSERT INTO target_table SELECT ... FROM staging;
```

```python
# ファイルベースの冪等性
output_path = os.path.join(output_loc, run_id)
if os.path.exists(output_path):
    shutil.rmtree(output_path)
# 新しいデータを書き込み
```

- 罠: DELETE のスコープが広すぎると他のデータを巻き込む
- 罠: 非 replayable ソースのエンリッチメントが混ざると冪等性が壊れる
- 罠: 同時実行で一時テーブルが衝突する → run_id で分離する

### Self-Healing（自己修復）
次回実行時に未処理データを自動的にキャッチアップ。
- 冪等にできない場合の代替策
- 罠: コードバグが複数ラン分隠れる可能性がある
- 罠: キャッチアップロジックが重複/部分レコードを防ぐ必要がある

## 構造パターン

### Multi-Hop（多段階）
dbt の staging/intermediate/marts や Databricks の Medallion アーキテクチャ。
- 利点: 失敗した変換だけ再実行、中間テーブルで問題特定
- 罠: ストレージコスト × 処理コストが多段分倍増

### Conditional/Dynamic
実行タイミングや入力値で処理が分岐。
- 罠: 全入力パターンのテストが困難。フレーキーになりやすい

### Disconnected
複数パイプラインが暗黙的にシンクに依存し合う。
- 罠: デバッグ・リネージ追跡・SLA定義が極めて困難

## パターン選択フローチャート

1. 過去データが必要？ → Replayability 要件を決定
2. データサイズは？ → 大: Time Ranged / 小: Full Snapshot / 過去N期間: Lookback / リアルタイム: Streaming
3. 変換の複雑さは？ → 標準: Multi-Hop / 条件分岐: Conditional / 複数チーム: Disconnected
4. シンクは上書き可能？ → Yes: Idempotent / No: Self-Healing

**鉄則: 最もシンプルなパターンから始める。**
