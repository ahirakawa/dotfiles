# ベンダー動向・リリース

feed-curator が自動収集した記事の日本語要約を蓄積する。

---

## Claude Sonnet 5 リリース（Anthropic, 2026-07）

Sources:
- https://www.anthropic.com/news/claude-sonnet-5

### 性能

- Opus 4.8 に迫る性能で、Sonnet 4.6 から推論・ツール使用・コーディング・知識作業が改善。"strict improvement" を主張
- Humanity's Last Exam: 34.6%（ツールなし）→ 46.8%（ツール使用時）。OSWorld-Verified は Sonnet 4.6 が 78.5%

### 価格・トークナイザー

- 導入価格（〜2026-08-31）: 入力 $2/M・出力 $10/M。以降は $3/M・$15/M
- 新トークナイザー採用で同一入力のトークン数が約1.0〜1.35倍になる点に注意（実効コストの見積もりに影響）

### 提供

- Claude.ai / Claude Code / Claude Platform、AWS・Microsoft Foundry・Google Vertex にも展開予定
- **教訓**: 中位モデルの世代交代はコスト最適化の好機だが、トークナイザー変更があるときは $/M 単価だけでなくトークン数の増分まで含めて試算する
