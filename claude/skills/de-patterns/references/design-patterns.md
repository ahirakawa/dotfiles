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

---

## QUALIFY 句による Window 関数フィルタリング

Sources:
- https://medium.com/@Rohan_Dutt/why-qualify-clause-for-window-filtering-in-sql-powerful-than-you-think-and-how-to-master-them-42792a2758ad

### QUALIFY とは

- Window 関数の結果を直接フィルタできる SQL 句（Snowflake, BigQuery, Databricks で利用可能）
- `WHERE` が集約前、`HAVING` が集約後なのに対し、`QUALIFY` は Window 関数評価後にフィルタする
- サブクエリや CTE でのラップが不要になり、クエリの可読性と保守性が向上

### 典型的なユースケース

- **重複排除**: `QUALIFY ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY updated_at DESC) = 1` で最新レコードのみ取得
- **ランキングフィルタ**: `QUALIFY RANK() OVER (PARTITION BY category ORDER BY sales DESC) <= 3` で上位N件抽出
- **教訓**: incremental モデルや snapshot の重複排除で、サブクエリの入れ子を避けてシンプルに書ける。dbt model の可読性向上に直結

---

## ACID 特性の実践的理解 — トランザクションが守る4つの法則

Sources:
- https://medium.com/towards-data-engineering/choreographing-the-chaos-what-database-engines-are-actually-trying-to-teach-you-4-7bf6e112b6b1

### ACID の実務的意味

- **Atomicity**: 全て成功するか全て取り消すか。99% 完了でも失敗すればロールバック
- **Consistency**: DB は現実世界の表現。銀行残高の合計は送金前後で変わってはならない
- **Isolation**: 並行トランザクションは互いに見えない。Dirty Read / Non-repeatable Read / Phantom Read を防ぐ
- **Durability**: コミット完了後はシステム障害が起きてもデータは永続化される

### 分離レベルの実務トレードオフ

- **Read Uncommitted**: 最速だが Dirty Read あり。分析用途でも危険
- **Read Committed**: コミット済みデータのみ読む。多くの RDBMS のデフォルト
- **Repeatable Read**: 同一トランザクション内で同じ読み取り結果を保証。Phantom Read は防げない
- **Serializable**: 完全な直列化。安全だがデッドロックとパフォーマンス劣化のリスク
- **教訓**: ETL パイプラインで DELETE-INSERT パターンを使う場合、分離レベルの選択が冪等性に直結する

---

## PAGE Compression が ETL 書き込み性能を3倍劣化させた事例

Sources:
- https://medium.com/towards-data-engineering/when-page-compression-quietly-kills-your-write-performance-243a879f985e

### 症状: データ量1/10なのに処理時間3倍

- パーティション分割 + ステージングテーブル導入後、バリデーションが15分→45分に劣化
- 全テーブルへの UPDATE が2秒→9秒に。データ量が少ないのに遅い逆転現象

### 原因: PAGE Compression の隠れた書き込みコスト

- PAGE Compression は行圧縮 + プレフィックス圧縮 + 辞書圧縮の3層構造
- 読み取りは40-80%のストレージ削減で高速化するが、書き込み時は毎回ページの再圧縮が必要
- UPDATE のたびに展開→変更→再圧縮→辞書再構築が走り、CPU とメモリを大量消費

### 解決策と教訓

- ステージングテーブル（書き込み多）は圧縮なし、履歴テーブル（読み取り多）は PAGE Compression
- `ALTER INDEX ... REBUILD WITH (DATA_COMPRESSION = NONE)` で即座に改善
- **教訓**: 圧縮はストレージ最適化であり、ワークロード特性に合わせて使い分ける。ETL の書き込みフェーズに PAGE Compression は禁忌

---

## データ移動パターンの進化: ETL → ELT → CDC → Reverse ETL

Sources:
- https://www.getdbt.com/blog/data-movement-patterns

### ETL vs ELT

| 観点 | ETL | ELT |
|------|-----|-----|
| 変換タイミング | ロード前（外部処理層） | ロード後（DWH 内） |
| 前提 | ストレージ・コンピュートが高価で密結合 | クラウド DWH のスケーラブルな計算力 |
| 利点 | DWH に入るデータが少ない | 柔軟、バージョン管理・テスト可能（dbt） |
| 課題 | 変換が散在、再利用困難 | 管理なしだとテーブル・ダッシュボード爆発 |

### その他の移動パターン

- **バッチ処理**: 定期スケジュールで大量データを一括移動。シンプルだがレイテンシは高い
- **CDC (Change Data Capture)**: ソース DB のトランザクションログから変更のみをキャプチャ。低レイテンシでソースへの負荷が小さい
- **ストリーミング**: イベント単位のリアルタイム処理。不正検知・リアルタイムダッシュボード向け
- **Reverse ETL**: DWH から CRM・マーケティングツール等の業務システムへデータを戻す。分析結果をオペレーションに直結

### パターン選択の判断軸

- レイテンシ要件（バッチ許容 → バッチ / 分単位 → CDC / 秒単位 → ストリーミング）
- **教訓**: ELT が現代の標準だが、ETL が完全に不要になったわけではない。変換をロード前に行う必要があるケース（PII マスキング、フォーマット正規化等）は依然として存在する
