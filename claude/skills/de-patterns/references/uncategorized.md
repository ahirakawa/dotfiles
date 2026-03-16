# 未分類

既存カテゴリに当てはまらない記事を一時的に収集するファイル。
同テーマの記事が3件以上溜まったら、新カテゴリへの昇格を検討する。

---

## Snowflake Native UUID: 分散データ基盤での識別子設計

Sources:
- https://medium.com/towards-data-engineering/snowflakes-native-uuid-data-type-an-architect-s-deep-dive-dcefc30f323a

### VARCHAR UUID の問題

- フォーマット不統一（ハイフンあり/なし、大文字/小文字混在）による JOIN 失敗
- 文字列比較のパフォーマンスコスト
- バリデーションロジックをアプリケーション側で持つ必要

### Native UUID の設計上の意味

- 128-bit 固定長で格納効率が向上、比較も高速化
- INSERT 時にフォーマット検証が自動で走る（不正値は弾かれる）
- Snowflake はユニーク制約を強制しない設計 → ingestion スループット優先。重複排除は上流パイプラインの責務
- **教訓**: 識別子の型をネイティブにすることで「暗黙の前提」がスキーマに明示される。VARCHAR で UUID を扱っている既存テーブルは移行を検討する価値あり

---

## エンジニアリング意思決定の記録 -- ADRが続かない問題

Sources:
- https://news.ycombinator.com/item?id=47368874

### よくある失敗パターン

- ADR（Architecture Decision Records）を導入 → 6週間で形骸化
- PRテンプレートに「なぜ」を書く欄 → 1ヶ月で無視される
- Notionのアーキテクチャドキュメント → 14ヶ月更新なし
- 結果: 新メンバーが「コード考古学」に3週間費やす

### HNコミュニティの実践知見

- 手動で書かせる仕組みは長続きしない。**自動生成 + 軽い追記**が現実的
- PR description をLLMで自動生成し、レビュアーが修正する方が継続する
- git blameとPRの紐付けを強制するだけでも「なぜ」への到達速度が改善する
- **教訓**: 「書く習慣を作る」より「書かなくても残る仕組み」を設計すべき。データパイプラインのメタデータ管理と同じ原則

---

## DuckDB: 8GB MacBook で大規模データ処理はどこまで可能か

Sources:
- https://duckdb.org/2026/03/11/big-data-on-the-cheapest-macbook

### ベンチマーク結果

- **ClickBench**（1億行, 14GB Parquet）: cold median 0.57秒。AWS c6a.4xlarge（16vCPU, 32GB RAM）の cold median 1.34秒を上回る
- **TPC-DS SF100**: 全99クエリ完走、median 1.63秒、合計15.5分
- **TPC-DS SF300**: 全クエリ完走、median 6.90秒、合計79分。ピーク時80GBのディスクスピル

### なぜ安価なマシンが勝てるのか

- cold run ではローカル NVMe（1.5GB/s）がネットワークストレージに対して圧倒的に有利
- hot run では c6a.4xlarge と13%差まで肉薄（CPU 10スレッド少なく、RAM 1/4にもかかわらず）
- DuckDB の out-of-core 処理がメモリ制約下でもクエリ完走を保証

### 実務への示唆

- **教訓**: 探索的分析やアドホッククエリは必ずしもクラウドの大きなインスタンスが必要ではない。DuckDB + ローカルSSD で十分なケースが多い
- ただし本記事の推奨はクラウド側に DuckDB を配置し、MacBook はクライアントとして使う構成
