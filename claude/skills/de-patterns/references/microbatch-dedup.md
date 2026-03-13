# Microbatch Hourly Deduplication Pattern

Source: https://github.com/EcZachly/microbatch-hourly-deduped-tutorial

## 概要

日次バッチのレイテンシを削減するため、時間単位でデータを処理・重複排除するパターン。
重複は時間境界を跨いで発生するため、2段階の重複排除が必要。

## 問題

同一イベントが複数の時間バケットに出現する（例: hour=3 と hour=4 の両方に同じ product_id + event_type の組み合わせ）。
時間内の GROUP BY だけでは時間跨ぎの重複を排除できない。

## 2段階の重複排除

### Stage 1: 時間内の重複排除 (GROUP BY)

```sql
INSERT OVERWRITE TABLE hourly_deduped_source
    PARTITION (ds, hour, product_name)
SELECT
    product_id,
    event_type,
    MIN(event_timestamp_epoch) AS min_event_timestamp_epoch,
    MAX(event_timestamp_epoch) AS max_event_timestamp_epoch,
    MAP_FROM_ARRAYS(
        COLLECT_LIST(event_location),
        COLLECT_LIST(event_timestamp_epoch)
    ) AS event_locations
FROM event_source
GROUP BY product_id, event_type
```

### Stage 2: 時間跨ぎの重複排除 (FULL OUTER JOIN)

```sql
WITH earlier AS (
    SELECT * FROM hourly_deduped_source
    WHERE ds = '{{ ds }}' AND hour = '{{ earlier_hour }}'
),
later AS (
    SELECT * FROM hourly_deduped_source
    WHERE ds = '{{ ds }}' AND hour = '{{ later_hour }}'
)
SELECT
    COALESCE(e.product_id, l.product_id) AS product_id,
    COALESCE(e.event_type, l.event_type) AS event_type,
    COALESCE(e.min_event_timestamp_epoch, l.min_event_timestamp_epoch) AS min_ts,
    COALESCE(l.max_event_timestamp_epoch, e.max_event_timestamp_epoch) AS max_ts,
    CONCAT(e.event_locations, l.event_locations) AS event_locations
FROM earlier e
FULL OUTER JOIN later l
    ON e.product_id = l.product_id
    AND e.event_type = l.event_type
```

### バイナリツリー型マージ

時間ペアを段階的にマージして日次集約に到達:
```
hour1 + hour2 → pair_12
hour3 + hour4 → pair_34
pair_12 + pair_34 → quad_1234
... → daily_aggregate
```

## テーブル設計

```sql
-- 時間単位の重複排除済みテーブル
CREATE TABLE hourly_deduped_source (
    product_id BIGINT,
    product_event_type BIGINT,
    min_event_timestamp_epoch BIGINT,
    max_event_timestamp_epoch BIGINT,
    event_locations MAP<STRING, BIGINT>
) PARTITIONED BY (ds STRING, hour STRING, product_name STRING)

-- 日次の最終重複排除済みテーブル
CREATE TABLE deduped_source (
    product_id BIGINT,
    event_type BIGINT,
    event_locations MAP<STRING, BIGINT>,
    min_event_timestamp_epoch BIGINT,
    max_event_timestamp_epoch BIGINT
) PARTITIONED BY (ds STRING, product_name STRING)
```

## 実装の罠

| 罠 | 何が起きるか |
|----|------------|
| 時間内 GROUP BY だけで済ませる | 時間境界を跨ぐ重複が残る |
| COALESCE の min/max を逆にする | イベントの時系列順序が壊れる（min に後のタイムスタンプが入る） |
| FULL OUTER JOIN の結合キーが不足 | 異なるイベントが誤ってマージされる |
| バイナリツリーの途中段階を INSERT INTO で書く | リトライ時に中間結果が重複 |
