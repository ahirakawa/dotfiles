---
name: magi
description: 複数の専門エージェント（reviewer, architect, operator）をAgent Teamsとして起動し、独立判断→直接議論→最終合議で結論を出すMAGI式合議システム。設計判断、技術選定、ビジネス判断など多角的な評価が必要なときに使う。ユーザーが「magiで」「MAGI判定」「合議で判断」と言ったときに起動する。
---

# MAGI 合議システム

3つの専門エージェント（reviewer, architect, operator）を Agent Teams として起動し、独立判断→直接議論→最終合議のプロセスで結論を出す。

**このスキルはメイン会話で展開される。メイン会話がMAGIリード（オーケストレーター）として振る舞う。**

## 手順

### Phase 0: ファクト収集（リードが実行）

判断に必要な **客観的データ** を収集する。

1. 対象がコードの場合: 関連ファイルを Read/Glob/Grep で読み込む
2. 対象が技術選定・ビジネス判断等の場合: **WebSearch で最低3つの異なるクエリ** を実行し、公式情報・実データ・事例を収集する
3. 収集した事実を `## 収集データ` としてまとめる（出典URL付き）

**ルール:**
- 推定値・伝聞ではなく、出典付きの一次データを優先する
- データが見つからなかった項目は「未確認」と明記する
- このフェーズで判断や意見を述べてはならない（事実収集のみ）

### Phase 1: チーム作成と独立判断

#### Step 1: チーム作成

```
TeamCreate(team_name="magi-session", description="MAGI合議セッション")
```

#### Step 2: 3エージェントを並列起動

Agent ツールで **1つのメッセージ内に3つの Agent tool call を含めて並列起動** する。
各エージェントには `team_name="magi-session"` と `name` を指定し、カスタムエージェント定義（.claude/agents/）を `subagent_type` で参照する。

```
Agent(
  subagent_type="reviewer",
  name="reviewer",
  team_name="magi-session",
  prompt="
## あなたの役割: MAGI合議の慎重派（reviewer）
## チーム構成: reviewer(あなた), architect, operator
## 割り当て立場: 慎重派（リスク・品質の観点から批判的に評価せよ）

## 収集データ:
[Phase 0の結果を全文貼る]

## 評価対象:
[ユーザーの入力]

## 指示:
1. 独立して分析し、判定結果を出力せよ（出力がそのままリードに届く）
2. その後、リードからリバッタル（反論ラウンド）の指示がSendMessageで届くので待機せよ
"
)

Agent(
  subagent_type="architect",
  name="architect",
  team_name="magi-session",
  prompt="
## あなたの役割: MAGI合議の推進派（architect）
## チーム構成: reviewer, architect(あなた), operator
## 割り当て立場: 推進派（実現する前提で最善の戦略・設計を提案せよ）

## 収集データ:
[Phase 0の結果を全文貼る]

## 評価対象:
[ユーザーの入力]

## 指示:
1. 独立して分析し、判定結果を出力せよ（出力がそのままリードに届く）
2. その後、リードからリバッタル（反論ラウンド）の指示がSendMessageで届くので待機せよ
"
)

Agent(
  subagent_type="operator",
  name="operator",
  team_name="magi-session",
  prompt="
## あなたの役割: MAGI合議の現実派（operator）
## チーム構成: reviewer, architect, operator(あなた)
## 割り当て立場: 現実派（コスト・実行可能性・リスクを定量的に評価せよ）

## 収集データ:
[Phase 0の結果を全文貼る]

## 評価対象:
[ユーザーの入力]

## 指示:
1. 独立して分析し、判定結果を出力せよ（出力がそのままリードに届く）
2. その後、リードからリバッタル（反論ラウンド）の指示がSendMessageで届くので待機せよ
"
)
```

**立場の割り振りの意図:**
- reviewer = 慎重派: 問題を見つける役。品質・リスクの観点で批判的に評価
- architect = 推進派: 実現する方法を考える役。「どうすればできるか」を設計
- operator = 現実派: 数字で語る役。コスト・工数・損益を定量評価

### Phase 2: 第1ラウンド集約

3者の判断が揃ったら、ユーザーに中間報告する:

```
## MAGI 判定（第1ラウンド）

| 観点 | 立場 | 判定 | 要約 |
|------|------|------|------|
| reviewer（品質） | 慎重派 | ✅ or ❌ | 一言理由 |
| architect（設計） | 推進派 | ✅ or ❌ | 一言理由 |
| operator（運用） | 現実派 | ✅ or ❌ | 一言理由 |

リバッタル（直接議論）を開始します...
```

### Phase 2.5: リバッタル（直接議論ラウンド）

**全会一致の場合もこのフェーズを実行する。**

各エージェントに SendMessage で他の2者の主張を送り、**エージェント同士が直接議論する**よう指示する:

```
SendMessage(to="reviewer", message="
## リバッタル開始

以下は他の2者の判断です。

### architect（推進派）の主張:
[architectの出力]

### operator（現実派）の主張:
[operatorの出力]

## 指示:
1. 推進派(architect)の主張に対して反論があれば、architectに直接SendMessageで伝えよ
2. 現実派(operator)の主張について補足・反論があれば、operatorに直接SendMessageで伝えよ
3. 他のエージェントからのSendMessageを受け取り、応答せよ
4. 議論が収束したら（最大2往復）、最終判定をリードにSendMessageで報告せよ
", summary="リバッタル指示をreviewerに送信")

SendMessage(to="architect", message="
## リバッタル開始

以下は他の2者の判断です。

### reviewer（慎重派）の主張:
[reviewerの出力]

### operator（現実派）の主張:
[operatorの出力]

## 指示:
1. 慎重派(reviewer)の懸念に対して、それでも推進すべき理由があればreviewerに直接SendMessageで伝えよ
2. 現実派(operator)のコスト指摘を踏まえた修正案があれば、operatorに直接SendMessageで伝えよ
3. 他のエージェントからのSendMessageを受け取り、応答せよ
4. 議論が収束したら（最大2往復）、最終判定をリードにSendMessageで報告せよ
", summary="リバッタル指示をarchitectに送信")

SendMessage(to="operator", message="
## リバッタル開始

以下は他の2者の判断です。

### reviewer（慎重派）の主張:
[reviewerの出力]

### architect（推進派）の主張:
[architectの出力]

## 指示:
1. 推進派と慎重派の主張を踏まえ、現実的な落とし所をreviewer・architectそれぞれに直接SendMessageで提案せよ
2. 他のエージェントからのSendMessageを受け取り、応答せよ
3. 議論が収束したら（最大2往復）、最終判定をリードにSendMessageで報告せよ
", summary="リバッタル指示をoperatorに送信")
```

**このフェーズでは3者がSendMessageで直接やりとりする。リードは議論を待ち、最終判定の報告を受け取るだけ。**

### Phase 3: 最終合議

リバッタル後の3者の最終判断を集約し、ユーザーに報告する:

```
## MAGI 最終判定

### 第1ラウンド → リバッタル後の変化
| 観点 | 第1ラウンド | リバッタル後 | 変化の理由 |
|------|------------|-------------|-----------|
| reviewer | ✅/❌ | ✅/❌ | ... |
| architect | ✅/❌ | ✅/❌ | ... |
| operator | ✅/❌ | ✅/❌ | ... |

### 合議結果: [全会一致 ✅ / 多数決 ⚠️ / 割れている ❌]

### 事実に基づく根拠（Phase 0 データからの引用）
- 根拠1: [出典付き]
- 根拠2: [出典付き]

### エージェント間で合意した点
- ...

### エージェント間で合意しなかった点
- reviewer の主張: ...
- architect の主張: ...
- operator の主張: ...

### 最終推奨
- 結論を述べる
- 割れている場合: 両論を併記し、判断材料を提示してユーザーに委ねる
- 全会一致の場合でも: 残存リスクや前提条件を明記する
```

### Phase 4: クリーンアップ

合議完了後、チームメイトをシャットダウンしてチームを削除する:

```
SendMessage(to="reviewer", message={type: "shutdown_request", reason: "合議完了"})
SendMessage(to="architect", message={type: "shutdown_request", reason: "合議完了"})
SendMessage(to="operator", message={type: "shutdown_request", reason: "合議完了"})
TeamDelete()
```

## ルール

- Phase 0 を省略してはならない（事実なき判断は無価値）
- Phase 1 では Agent ツールで3者を **必ず並列起動** する（独立性の担保）
- Phase 2.5 のリバッタルは **省略してはならない** （全会一致でも実行）
- Phase 2.5 ではエージェント同士の直接通信を使い、リードは仲介しない
- 1者でも ❌ がある場合、その理由を必ずユーザーに伝える
- 全会一致の ✅ でも、各者の総評は省略しない
- 各エージェントの出力をそのまま引用し、自分の解釈で改変しない
- 数値を含む主張には必ず出典を求める。出典なき数値は「未検証」と注記する
