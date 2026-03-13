# Big Tech のデータエンジニアリング実戦知見

## Netflix: Data Mesh Platform

Sources:
- https://netflixtechblog.com/data-mesh-a-data-movement-and-processing-platform-netflix-1288bcab2873
- https://netflixtechblog.com/streaming-sql-in-data-mesh-0d83f5a00d08

### アーキテクチャ

- Control Plane（Data Mesh Controller）+ Data Plane（Data Mesh Pipeline）の分離
- Processor（Flink ジョブ）を Kafka トピックで接続するパイプライン構成
- 規模: 20,000 Flink ジョブ、数千 Kafka トピック、毎日数兆イベント処理

### スキーマ管理の教訓

- パイプライン作成時に各 Processor が消費/生成するスキーマを定義
- プラットフォームがスキーマバリデーションと互換性チェックを自動実行
- ソース側でスキーマが変更されると、消費側パイプラインの自動アップグレードを試行
- **教訓**: スキーマ進化をプラットフォームレベルで自動処理しないと、大規模環境では破綻する

---

## Uber: Apache Hudi（トリリオンレコード規模）

Sources:
- https://www.uber.com/blog/apache-hudi-at-uber/
- https://www.uber.com/blog/from-batch-to-streaming-accelerating-data-freshness-in-ubers-data-lake/

### 規模

- 19,500 データセット、毎日6兆行を取り込み、300万新規ファイル
- 350論理PB（HDFS/GCS）、35万コミット/日
- 最大テーブル: 4,000億行超

### データセットの4分類

| 種別 | 数 | 特徴 |
|------|-----|------|
| Append-only | 11,200 | バルクインサート、最大ボリューム |
| Upsert-heavy | 4,400 | インデックスベースのルックアップ |
| Derived | 1,600 | 上流テーブルからのインクリメンタル変換 |
| Real-time | 500 | Flink ストリーミング、15分以内の鮮度 |

### 実戦で学んだ教訓

**設定管理がスケーリングのボトルネックになる**
- データセットごとのパラメータオーバーライドが数万の微妙に異なる設定を生む
- 解決: 設定の中央集権化を厳格に徹底

**サイレント障害が最も危険**
- ファイル破損、設定エラー、OSSのバグ — 最も困難なインシデントは沈黙する問題から発生
- 解決: 全 Hudi 操作でメトリクスを発行。SLA違反、ストレージ劣化、破損を自動検知

**障害は不可避、回復が高速であることが重要**
- 数千のパイプラインが24時間稼働すると、レアなコーナーケースも必ず表面化する
- 解決: シャドウパイプライン（安全なテスト）、自動バックフィル/リペア、バリデーションフレームワーク
- 回復を「痛みを伴う数日の作業」から「再現可能なランブックベースのワークフロー」に変換

**スキーマ進化は Day 1 からファーストクラスで扱う**
- フィールドのリネームのような無害に見える変更が数千の下流ジョブを壊す
- 解決: 強い後方互換性ルール、自動スキーマバリデーション、変更提案の事前検証

**最も難しい問題を最初に解く**
- 簡単な課題を先にやって難しい課題を後回しにすると、プラットフォーム全体が脱線する
- Uber の場合: インデックス戦略がバックボーンの意思決定だった

### バッチ→ストリーミング移行の罠

**Small Files 問題**
- ストリーミングは過剰な小さい Parquet ファイルを生成、クエリ性能を劣化させる
- 解決: row-group レベルのマージ（解凍/再エンコード/再圧縮を回避）で10倍高速化

**パーティションスキュー**
- GC 等の一時的な遅延で Kafka 消費が Flink サブタスク間で不均衡に
- 解決: ラウンドロビンポーリング、パーティションごとのクォータ、スキュー検知付きオートスケーリング

**チェックポイント-コミット同期**
- Flink チェックポイント（消費オフセット）と Hudi コミット（書き込み）のずれが障害時にデータ損失/重複を引き起こす
- 解決: Hudi コミットメタデータに Flink チェックポイント ID を埋め込み、決定的な復旧を実現

---

## Airbnb: メトリクス一貫性（Minerva）

Sources:
- https://medium.com/airbnb-engineering/how-airbnb-achieved-metric-consistency-at-scale-f23cc53dea70
- https://medium.com/airbnb-engineering/airbnb-metric-computation-with-minerva-part-2-9afe6695b486

### 問題

- 複数チームが独立して同じメトリクスの異なる定義を作成 → 数字が合わない
- データマート層の重複と矛盾

### Minerva プラットフォーム

- ファクト/ディメンションテーブルを入力、非正規化を実行、集約データを下流に提供
- 12,000+ メトリクス、4,000+ ディメンション、200+ のデータプロデューサー
- 宣言的: ユーザーは「何を」定義、「どう」計算するかはプラットフォームが抽象化
- ビジネスロジック変更時にバックフィルが自動実行

### 教訓

- **メトリクスの Single Source of Truth がないと、組織が大きくなるほど矛盾が増殖する**
- 宣言的なメトリクス定義 + 計算の自動化が解決策
- dbt の metrics/semantic layer も同じ問題を解こうとしている

---

## Airbnb: データ品質（Midas + Wall）

Sources:
- https://medium.com/airbnb-engineering/data-quality-at-airbnb-e582465f3ef7
- https://medium.com/airbnb-engineering/how-airbnb-built-wall-to-prevent-data-bugs-ad1b081d6e8f

### Midas 認証プロセス（4段階レビュー）

1. **Spec Review**: データモデルの設計仕様をレビュー
2. **Data Review**: パイプラインの品質チェックとバリデーションレポート
3. **Code Review**: パイプラインのコードレビュー
4. **Minerva Review**: メトリクス定義のレビュー

### データ品質の4次元（Airbnb 定義）

| 次元 | 意味 |
|------|------|
| Accuracy | 網羅的なチェックと継続的な自動チェック |
| Reliability | データ到着時間の SLA とインシデント管理 |
| Stewardship | ストレージ/コンピュートのベストプラクティス |
| Usability | 明確なラベリングと充実したドキュメント |

### Wall フレームワーク

- YAML 設定ベースの品質チェック（コード変更不要）
- 階層的プロパティシステム: team → file → table → check レベルでカスケードオーバーライド
- Stage-Check-Exchange パターン: ETL ロジックとチェックロジックを分離
- Blocking / Non-blocking チェックの区別
- 結果を Kafka イベントとして発行 → 下流ツールと連携

### 導入効果

- 全重要ビジネス/財務パイプラインが Wall を使用、毎日数千チェック実行
- 一部パイプラインで DAG コードが 70% 以上削減
- Pre-Wall 時代の3つの問題を解決: 標準化の欠如、冗長なツール、ETL とチェックの密結合
