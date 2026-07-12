#!/usr/bin/env python3
"""distill ingest — Claude Code トランスクリプト(~/.claude/projects/**/*.jsonl)を
DuckDB に取り込み、「学びの濃いセッション」をランキングする。

蒸留時にのみ実行するバッチ設計(単一ライター)。並列セッションへの仕込みは不要。

Usage:
  python3 ingest.py ingest [--projects-dir DIR] [--db PATH]
  python3 ingest.py rank [--limit N] [--db PATH] [--all]
  python3 ingest.py mark --session-id ID [--note TEXT] [--db PATH]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path

import duckdb

DEFAULT_DB = os.environ.get(
    "DISTILL_DUCKDB_PATH",
    str(Path.home() / "claude-skills" / "distill" / "distill.duckdb"),
)
DEFAULT_PROJECTS_DIR = str(Path.home() / ".claude" / "projects")

SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (
  session_id       TEXT PRIMARY KEY,
  project          TEXT,
  transcript_path  TEXT,
  file_mtime       TIMESTAMP,
  started_at       TIMESTAMP,
  ended_at         TIMESTAMP,
  duration_min     DOUBLE,
  model            TEXT,
  n_user_prompts   INTEGER,
  n_assistant_msgs INTEGER,
  n_tool_calls     INTEGER,
  n_tool_errors    INTEGER,
  n_interrupts     INTEGER,
  max_tool_streak  INTEGER,
  n_sidechain_msgs INTEGER,
  output_tokens    BIGINT,
  ingested_at      TIMESTAMP
);
CREATE TABLE IF NOT EXISTS tool_stats (
  session_id TEXT,
  tool_name  TEXT,
  calls      INTEGER,
  errors     INTEGER
);
CREATE TABLE IF NOT EXISTS distilled (
  session_id   TEXT PRIMARY KEY,
  distilled_at TIMESTAMP,
  note         TEXT
);
"""

# 学びの濃さスコア: 失敗・軌道修正・反復の痕跡を重く見る。
# 重みはここを書き換えて調整する。
RANK_VIEW = """
CREATE OR REPLACE VIEW learning_rank AS
SELECT
  session_id, project, model, started_at, duration_min,
  n_tool_calls, n_tool_errors, n_interrupts, max_tool_streak, n_user_prompts,
  n_tool_errors * 3
    + n_interrupts * 5
    + GREATEST(max_tool_streak - 3, 0) * 2
    + n_user_prompts * 1
    + LEAST(COALESCE(duration_min, 0) / 30.0, 4) AS score,
  transcript_path
FROM sessions;
"""


def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).replace(tzinfo=None)
    except ValueError:
        return None


def analyze_transcript(path: Path) -> dict | None:
    """1トランスクリプトを走査してセッションメトリクスを返す。"""
    first_ts = last_ts = None
    model = None
    n_user_prompts = n_assistant = n_tool_calls = n_tool_errors = 0
    n_interrupts = n_sidechain = 0
    output_tokens = 0
    tool_counts: dict[str, int] = {}
    tool_errors: dict[str, int] = {}
    streak = max_streak = 0
    prev_tool = None
    pending_tool_names: dict[str, str] = {}  # tool_use_id -> name

    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                t = d.get("type")
                ts = parse_ts(d.get("timestamp"))
                if ts:
                    first_ts = first_ts or ts
                    last_ts = ts
                if d.get("isSidechain"):
                    n_sidechain += 1

                if t == "assistant":
                    msg = d.get("message") or {}
                    model = msg.get("model") or model
                    n_assistant += 1
                    usage = msg.get("usage") or {}
                    output_tokens += usage.get("output_tokens") or 0
                    for b in msg.get("content") or []:
                        if isinstance(b, dict) and b.get("type") == "tool_use":
                            name = b.get("name") or "?"
                            n_tool_calls += 1
                            tool_counts[name] = tool_counts.get(name, 0) + 1
                            pending_tool_names[b.get("id", "")] = name
                            if name == prev_tool:
                                streak += 1
                            else:
                                streak = 1
                                prev_tool = name
                            max_streak = max(max_streak, streak)

                elif t == "user":
                    msg = d.get("message") or {}
                    content = msg.get("content")
                    if isinstance(content, str):
                        n_user_prompts += 1
                        if "Request interrupted" in content:
                            n_interrupts += 1
                    elif isinstance(content, list):
                        has_text = False
                        for b in content:
                            if not isinstance(b, dict):
                                continue
                            bt = b.get("type")
                            if bt == "tool_result":
                                if b.get("is_error"):
                                    n_tool_errors += 1
                                    name = pending_tool_names.get(
                                        b.get("tool_use_id", ""), "?"
                                    )
                                    tool_errors[name] = tool_errors.get(name, 0) + 1
                            elif bt == "text":
                                has_text = True
                                if "Request interrupted" in (b.get("text") or ""):
                                    n_interrupts += 1
                        if has_text:
                            n_user_prompts += 1
    except OSError:
        return None

    if n_assistant == 0 and n_user_prompts == 0:
        return None  # 空セッションはスキップ

    duration_min = (
        (last_ts - first_ts).total_seconds() / 60.0 if first_ts and last_ts else None
    )
    return {
        "session_id": path.stem,
        "project": path.parent.name,
        "transcript_path": str(path),
        "file_mtime": datetime.fromtimestamp(path.stat().st_mtime),
        "started_at": first_ts,
        "ended_at": last_ts,
        "duration_min": duration_min,
        "model": model,
        "n_user_prompts": n_user_prompts,
        "n_assistant_msgs": n_assistant,
        "n_tool_calls": n_tool_calls,
        "n_tool_errors": n_tool_errors,
        "n_interrupts": n_interrupts,
        "max_tool_streak": max_streak,
        "n_sidechain_msgs": n_sidechain,
        "output_tokens": output_tokens,
        "tool_counts": tool_counts,
        "tool_errors": tool_errors,
    }


def cmd_ingest(args):
    db_path = Path(args.db)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = duckdb.connect(str(db_path))
    conn.execute(SCHEMA)
    conn.execute(RANK_VIEW)

    known = dict(
        conn.execute("SELECT transcript_path, file_mtime FROM sessions").fetchall()
    )
    files = sorted(Path(args.projects_dir).glob("*/*.jsonl"))
    n_new = n_skip = 0
    for f in files:
        mtime = datetime.fromtimestamp(f.stat().st_mtime)
        prev = known.get(str(f))
        if prev is not None and abs((mtime - prev).total_seconds()) < 1:
            n_skip += 1
            continue
        m = analyze_transcript(f)
        if m is None:
            continue
        tool_counts = m.pop("tool_counts")
        tool_errors = m.pop("tool_errors")
        cols = ", ".join(m.keys()) + ", ingested_at"
        ph = ", ".join(["?"] * len(m)) + ", current_timestamp"
        conn.execute(
            f"INSERT OR REPLACE INTO sessions ({cols}) VALUES ({ph})",
            list(m.values()),
        )
        conn.execute("DELETE FROM tool_stats WHERE session_id = ?", [m["session_id"]])
        for name, calls in tool_counts.items():
            conn.execute(
                "INSERT INTO tool_stats VALUES (?, ?, ?, ?)",
                [m["session_id"], name, calls, tool_errors.get(name, 0)],
            )
        n_new += 1
    conn.close()
    print(f"ingested: {n_new} sessions (skipped {n_skip} unchanged)")


def cmd_rank(args):
    conn = duckdb.connect(args.db, read_only=True)
    where = "" if args.all else (
        "WHERE session_id NOT IN (SELECT session_id FROM distilled)"
    )
    rows = conn.execute(
        f"""
        SELECT ROUND(score,1) AS score, session_id, project, model,
               strftime(started_at, '%Y-%m-%d') AS date,
               ROUND(duration_min,0) AS min,
               n_tool_calls AS tools, n_tool_errors AS errs,
               n_interrupts AS intr, max_tool_streak AS streak
        FROM learning_rank {where}
        ORDER BY score DESC LIMIT ?
        """,
        [args.limit],
    ).fetchall()
    cols = ["score", "session_id", "project", "model", "date", "min",
            "tools", "errs", "intr", "streak"]
    print("\t".join(cols))
    for r in rows:
        print("\t".join(str(v) for v in r))
    conn.close()


def cmd_mark(args):
    conn = duckdb.connect(args.db)
    conn.execute(
        "INSERT OR REPLACE INTO distilled VALUES (?, current_timestamp, ?)",
        [args.session_id, args.note],
    )
    conn.close()
    print(f"marked distilled: {args.session_id}")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    pi = sub.add_parser("ingest", help="トランスクリプトを取り込む")
    pi.add_argument("--projects-dir", default=DEFAULT_PROJECTS_DIR)
    pi.add_argument("--db", default=DEFAULT_DB)
    pi.set_defaults(func=cmd_ingest)

    pr = sub.add_parser("rank", help="学びの濃いセッションを表示(未蒸留のみ)")
    pr.add_argument("--limit", type=int, default=10)
    pr.add_argument("--all", action="store_true", help="蒸留済みも含める")
    pr.add_argument("--db", default=DEFAULT_DB)
    pr.set_defaults(func=cmd_rank)

    pm = sub.add_parser("mark", help="セッションを蒸留済みにする")
    pm.add_argument("--session-id", required=True)
    pm.add_argument("--note", default=None)
    pm.add_argument("--db", default=DEFAULT_DB)
    pm.set_defaults(func=cmd_mark)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
