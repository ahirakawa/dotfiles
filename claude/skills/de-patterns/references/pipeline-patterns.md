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
