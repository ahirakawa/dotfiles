# Cumulative Table Design Pattern

Source: https://github.com/DataExpert-io/cumulative-table-design

## 概要

日次でイベントデータをスキャンし、固定長ARRAYに累積することで、任意期間の集計を高速化するパターン。

## 3ステップ実装

### Step 1: Daily Aggregation Table

当日のイベントを集計。シンプルな GROUP BY。

```sql
-- 当日のユーザーアクティビティを集計
SELECT
    user_id,
    ds,
    CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END AS is_active_today,
    COUNT(CASE WHEN event_type = 'like' THEN 1 END) AS num_likes_today
FROM events
WHERE ds = '{{ ds }}'
GROUP BY user_id, ds
```

### Step 2: Cumulation Join (FULL OUTER JOIN)

昨日の累積テーブルと今日の日次集計を結合。

```sql
INSERT OVERWRITE TABLE cumulative_users PARTITION (ds = '{{ ds }}')
SELECT
    COALESCE(t.user_id, y.user_id) AS user_id,

    -- ARRAY の構築: CARDINALITY チェックが必須
    CASE
        WHEN y.activity_array IS NULL
            THEN ARRAY[COALESCE(t.is_active_today, 0)]
        WHEN CARDINALITY(y.activity_array) < 30
            THEN CONCAT(ARRAY[COALESCE(t.is_active_today, 0)], y.activity_array)
        ELSE
            SLICE(CONCAT(ARRAY[COALESCE(t.is_active_today, 0)], y.activity_array), 1, 30)
    END AS activity_array

FROM daily_user_activity t  -- today
FULL OUTER JOIN cumulative_users y  -- yesterday
    ON t.user_id = y.user_id
WHERE y.ds = '{{ yesterday_ds }}'
```

### Step 3: ARRAYからメトリクス導出

```sql
-- 月間アクティブ判定
CASE WHEN ARRAY_SUM(activity_array) > 0 THEN 1 ELSE 0 END AS monthly_active

-- 週間アクティブ判定
CASE WHEN ARRAY_SUM(SLICE(activity_array, 1, 7)) > 0 THEN 1 ELSE 0 END AS weekly_active
```

## 実装の罠

| 罠 | 何が起きるか | 正しい実装 |
|----|------------|-----------|
| INNER JOIN を使う | 今日アクティブでないユーザーが累積テーブルから消失 | FULL OUTER JOIN |
| COALESCE を忘れる | 新規ユーザーの配列が NULL → CONCAT が失敗 | COALESCE(t.is_active_today, 0) |
| CARDINALITY チェックなし | 初日〜29日目で SLICE が範囲外エラー | CARDINALITY < 30 の分岐 |
| depends_on_past を設定しない | DAG の並列実行で累積の連鎖が壊れる | depends_on_past: True |
| INSERT INTO を使う | リトライ時にレコードが重複 | INSERT OVERWRITE |

## DB方言の注意

- Presto/Trino: ARRAY_SUM, SLICE, CARDINALITY, CONCAT
- BigQuery: ARRAY_LENGTH, 配列スライスは OFFSET/ORDINAL ベース
- Snowflake: ARRAY_SIZE, ARRAY_SLICE
- PostgreSQL: array_length, 配列添字アクセス
