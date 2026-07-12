# エージェント設計パターン

feed-curator が自動収集した記事の日本語要約を蓄積する。

---

## Deep Agents がサンドボックスなしで untrusted code を実行する仕組み（LangChain）

Sources:
- https://www.langchain.com/blog/running-untrusted-agent-code-without-a-sandbox

### アーキテクチャ

- WASM + QuickJS 方式: C実装のJavaScriptエンジン QuickJS を WebAssembly にコンパイルし、in-process のメモリ隔離VMとして使う。AWS Lambda、Shopify Functions、Figma と同じモデル
- 従来サンドボックスの「広い権限から引き算」ではなく「何も持たない状態から必要な機能だけを橋渡しする」足し算型の capability 設計
- サブエージェント呼び出しも process manager や network stack を渡すのではなく、narrow contract を持つ関数として提供（同時実行数・スポーン数を制限）

### 実行の永続一時停止

- QuickJS のメモリ状態を LangGraph state にシリアライズし、human-in-the-loop の承認待ちを挟んでもスナップショットから再開できる。プログラム側からは「時間のかかった非同期呼び出し」に見える

### 制約

- Meta の Rule of Two（機密データアクセス / 信頼できないコンテンツ暴露 / 状態変更・外部通信のうち同時に2つまで）を適用
- quickjs-rs / langchain-quickjs はまだ experimental
- **教訓**: エージェントのコード実行安全性は「コンテナで囲う」以外に「実行環境自体を capability ベースで最小化する」設計軸がある。prompt injection 前提の設計では足し算型が本命
