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

---

## ECL フレームワーク: ETL/ELT の次のパラダイム

Sources:
- https://www.dataengineeringweekly.com/p/data-engineering-after-ai
- https://www.dataengineeringweekly.com/p/etl-is-dead

### ETL が「死んだ」理由

- パイプラインは動き続けるが「DE の定義的な仕事」としては消滅（固定電話的な死）
- スタースキーマ、カタログ、メダリオンアーキテクチャは全て人間の認知最適化 → AI エージェントが操作者になると障害になる
- AI がコード生成を担当する時代、データ移動の機械的作業は差別化要因ではなくなった

### ECL: Extract, Contextualize, Link

- **Extract**: 変わらず必要。信頼性・遅延・障害モードの工学的判断
- **Contextualize**: 新しい重心。生きた意味論的文脈ストアを構築・維持する専用パイプライン
- **Link**: エンティティ間のセマンティック関係を検証された形で接続（MCP 等の標準が対応）

### Context Store

- 従来のゴールド層テーブルに代わる、検証済みセマンティック定義の版管理されたアーティファクト
- **Context Objects**: 長期的な意味定義（「売上」とは何か、誰が検証、信頼度）
- **Decision Objects**: エージェント行動の監査証跡（どの定義を使用、どう推論、何を推奨）
- 二段階バインディング: 早期バインディング（データ契約を生成地点で実装）+ 遅延バインディング（文脈化パイプラインが継続的に意味定義を発見・検証）

### 歴史的振り子と今回の違い

- リレーショナル時代（精密だが硬直）→ Hadoop（柔軟だがセマンティック崩壊）→ レイクハウス（中道だがセマンティック層が後付け）
- 過去の失敗（用語集、セマンティック層、カタログ）の共通因子: 組織的重力が「データを届けて後で意味を理解しよう」に引き戻す
- **今回構造的に異なる理由**: 人間は文脈欠損に許容的（Slack で聞く）、AI エージェントは許容的でない（スケールで幻覚化）→ 維持コスト < セマンティック欠損コスト が初めて成立
- **教訓**: Kimball の次元モデリングのステップ1-2（ビジネスプロセス特定、粒度選択）は永遠に有効。ステップ3-4（スター/ディメンション）はレンダリング選択肢に過ぎない

---

## Full Refresh vs Incremental: 選択基準と実装パターン

Sources:
- https://seattledataguy.substack.com/p/full-refresh-vs-incremental-pipelines

### 判断に影響する5要素

- **Compute コスト**: 5GB の差分処理 vs 1TB の全件リビルドで桁違いの差
- **実装の容易さ**: Full Refresh は CREATE OR REPLACE で完結。Incremental はデータ特性の理解が必須
- **バックフィル複雑度**: 大テーブルの Full Refresh はリビルド時間が膨大。Incremental は修正ウィンドウの設計が必要
- **Update/Delete の有無**: append-only か、更新・削除が発生するかでパターンが変わる
- **ツール制約**: 初期 Redshift に MERGE がなかったように、プラットフォーム機能が設計を制約する

### Full Refresh + Write-Audit-Publish (WAP)

- **Write**: ステージング領域に全件変換結果を作成
- **Audit**: 行数・NULL率・重複・メトリクス乖離を検証
- **Publish**: チェック通過後にのみ本番テーブルを差し替え
- 適用場面: 小〜中規模テーブル、変更追跡が信頼できないソース、シンプルさ優先

### Incremental パターン群

| パターン | 手法 | トレードオフ |
|---------|------|-------------|
| MAX(ID) | `id > max(id)` で追加分のみロード | 高速だが ID の順序性・連続性を前提とする |
| NOT EXISTS | 既存レコードと突き合わせて未登録分をロード | 安全だが計算コスト高 |
| Date-based + Lookback | 直近 N 日分を DELETE & RELOAD | 遅延レコードに対応。余分な compute と引き換えに信頼性を得る |
| Upsert/MERGE | ユニークキーで INSERT/UPDATE を同時実行 | 更新のあるデータに最適 |
| Aggregation (会計方式) | 訂正レコードを追記（正負の金額）で履歴を保持 | 医療・会計系で多用。削除を避け監査証跡を維持 |

- **教訓**: 多くのチームは Full Refresh で始め、コスト増に応じて Incremental へ移行する。「どちらが正解か」ではなく、データサイズ・鮮度要件・プラットフォーム能力に応じた使い分けが重要
