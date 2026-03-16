# Pipeline Design Patterns

## Little Book of Pipelines パターン

Source: https://github.com/EcZachly/little-book-of-pipelines

### 問題

10+ のアップストリームソースを持つパイプラインで:
- バックフィルが苦痛（ソースごとに異なるロジック）
- オーナーシップが曖昧
- DQ ルールがジョブに散在

### 解決策: 5層アーキテクチャ

1. **ソースのグループ化**: 関連するソースを論理グループにまとめる
2. **共有スキーマ**: グループ横断の統一スキーマ。ストレージを多少犠牲にしてバックフィルを容易にする
3. **Enum 型メタデータレジストリ**: グループ・アイテム・DQルール・定数を Enum で一元管理。1 Enum entry = 1 Spark job
4. **抽象変換クラス**: ソース関数と Enum エントリを受け取る抽象クラス
5. **メタデータカタログテーブル**: Enum を Hive テーブルに変換し、DQ チームやダッシュボードからアクセス可能にする

### このパターンがないと何が起きるか

- DQ ルールが個別ジョブに埋まり、全体像が把握できない
- バックフィル時に複数のコードベースを理解する必要がある
- ソースグループと担当チームの対応関係が不明確になる

## Data Developer Platform アーキテクチャ

Source: https://datadeveloperplatform.org/architecture/

### 3プレーン構成

- **Control Plane**: ガバナンス・ポリシー・メタデータ管理
- **Development Plane**: 宣言的仕様によるワークロード定義
- **Data Activation Plane**: 実行エンジン（SQL、CDC、イベント処理）

### Atomic Resources（構成要素）

| リソース | 役割 |
|---------|------|
| Workflow | バッチ/ストリーミングの DAG |
| Service | リアルタイム API・イベント処理 |
| Policy | アクセス・品質・セキュリティ制御 |
| Depot | データソース接続の抽象化 |
| Cluster | 計算リソース |
| Secret | 認証情報管理 |

### 設計原則

- 有限な atomic リソースを組み合わせて高次アーキテクチャ（Data Mesh, Data Fabric 等）を構成
- 宣言的仕様 > 命令的実装
- バージョン管理をすべてのリソースに適用

---

## Snowflake FinOps: Cortex Code によるクラウドコスト管理の自動化

Sources:
- https://www.snowflake.com/blog/accelerating-finops-cortex-code-snowflake/

### 従来の課題

- クラウドコスト予測がスプレッドシートベースで脆く、スケールしない
- 予測値が下流ツールと分断され、Finance と Engineering で数字が合わない
- 異常検知が手動で、変化のスピードに追いつかない

### Cortex Code による改善

- 自然言語リクエストから Streamlit アプリコードを自動生成し、ガバナンス済みデータに直接接続
- クラウドコスト予測を日次更新に短縮（従来は月次サイクル）
- 予測値を構造化テーブルに格納し、Engineering/Product/Finance が同一数値で KPI を追跡

### 実践的な成果

- 異常検知: ロックした予測値に対する乖離を自動レポート
- マルチクラウド対応: GCP、SaaS、社内 Snowflake 利用を統合管理
- **教訓**: FinOps の本質はツールではなく「ビジネスコンテキストに紐づいた迅速なイテレーション」。データ基盤がすでにあれば、AI コード生成で FinOps を加速できる

---

## AI アシスタントを支えるデータ基盤設計

Sources:
- https://medium.com/towards-data-engineering/behind-every-ai-assistant-is-a-data-platform-why-data-engineering-matters-4269bd9285f4

### ユースケース

- ビジネスユーザーがプロジェクトの財務インパクト（金銭的節約 + 非金銭的効果）を自然言語で問い合わせる AI アシスタント
- 裏側で Snowflake Cortex AI が質問を SQL に変換し、Snowflake 上で実行して結果を返す

### データ基盤設計のポイント

- **ビジネス定義が先**: パイプライン構築前に「節約とは何か」「どのプロジェクトが貢献するか」のビジネス定義を確定
- **断片化データの統合**: プロジェクト承認、コスト、効果、属性が別システムに散在 → ビジネス意味を保持しつつ一貫的にクエリ可能にする
- **Key-based Normalization**: カンマ区切り文字列（"A, B, C"）を正規化して JOIN/集約を可能に
- **STAR Schema**: プロジェクトレベルのファクトテーブル + ビジネスユニット/プログラム/カテゴリのディメンションテーブル
- **教訓**: AI アシスタントの精度はモデルではなくデータ基盤の設計品質で決まる。STAR Schema + ビジネス定義の Single Source of Truth がないと、AI は間違った答えを返す

---

## メタデータ管理の重要性 — 発見・ガバナンス・パフォーマンスの基盤

Sources:
- https://www.getdbt.com/blog/why-metadata-management-is-important

### メタデータの4次元

| 種別 | 内容 |
|------|------|
| Structural | テーブル名、カラム名、データ型、ストレージ場所 |
| Operational | 最終更新日時、変換の実行時間、ジョブの成否 |
| Lineage | 上流ソースから下流モデル・レポートへのデータフロー |
| Business | オーナーシップ、メトリクス定義、DQ 指標、利用パターン |

### 管理しないと何が起きるか

- データ発見に数時間〜数日かかる（カタログなしで同僚に聞き回る）
- ガバナンスがアクセス制御だけに留まり、品質・リネージ・使用状況を横断管理できない
- パフォーマンス問題の根本原因特定が困難（クエリ統計が散在）
- **教訓**: メタデータは dbt のような変換ツールの副産物として自動生成させるのが最も持続可能。手動でのメタデータ収集はスケールしない

---

## Message Queue vs Pub/Sub: 混同が生むスケーリング障害

Sources:
- https://medium.com/towards-data-engineering/message-queues-vs-pub-sub-stop-using-them-interchangeably-01ced86ed570

### よくある障害パターン

- Pub/Sub トピックに複数 worker を接続すると、全 worker が同じメッセージを受信する
- 結果: メール3通送信、重複処理、データ不整合
- **教訓**: 「worker を増やせばスケールする」は Message Queue の場合のみ正しい

### 使い分けの原則

- **Message Queue（タスク分配型）**: 各メッセージは1つの consumer だけが処理。competing consumers パターン。ジョブ実行、メール送信、注文処理向き
- **Pub/Sub（イベント通知型）**: 全 subscriber がメッセージのコピーを受信。fan-out パターン。監査ログ、通知、複数サービスへのイベント伝播向き
- **教訓**: 「処理を1回だけ実行したい」なら Queue、「複数システムに通知したい」なら Pub/Sub。混同するとスケール時に壊れる
