#!/usr/bin/env python3
"""harness: Claude Code セッション観測 stub.

DuckDB CLI を subprocess 経由で呼ぶ。Python パッケージ追加なしで動かすための割り切り。
プロダクション用ではない。stub レベルで loop / budget / gate を記録できれば足りる。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import uuid
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

DB_PATH = os.environ.get("HARNESS_DUCKDB_PATH", "./harness.duckdb")
SKILL_DIR = Path(__file__).resolve().parent

TOKEN_BUDGET = 200_000
COST_BUDGET_USD = 5.00
LOOP_WINDOW = 6
LOOP_THRESHOLD = 3


def _sql_quote(value: object) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, (int, float)):
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"


def _exec(sql: str) -> str:
    res = subprocess.run(
        ["duckdb", DB_PATH, "-json", "-c", sql],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        sys.stderr.write(f"[harness] duckdb error: {res.stderr}\n")
        sys.exit(2)
    return res.stdout


def _query(sql: str) -> list[dict]:
    out = _exec(sql).strip()
    if not out:
        return []
    return json.loads(out)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def args_hash(args_json: str) -> str:
    """正規化済み args 文字列を 16 文字の sha256 prefix に。loop 検出用。"""
    try:
        normalized = json.dumps(json.loads(args_json), sort_keys=True, ensure_ascii=False)
    except json.JSONDecodeError:
        normalized = args_json
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:16]


def cmd_init(_args) -> int:
    init_sql = (SKILL_DIR / "init.sql").read_text(encoding="utf-8")
    _exec(init_sql)
    print(f"initialized: {DB_PATH}")
    return 0


def cmd_start(args) -> int:
    run_id = uuid.uuid4().hex[:12]
    sql = (
        f"INSERT INTO agent_runs (run_id, agent_type, task_description, language, start_ts, status) "
        f"VALUES ({_sql_quote(run_id)}, {_sql_quote(args.agent_type)}, "
        f"{_sql_quote(args.task)}, {_sql_quote(args.language)}, "
        f"{_sql_quote(_now())}, 'running');"
    )
    _exec(sql)
    print(run_id)
    return 0


def cmd_record_tool(args) -> int:
    """tool 呼び出しを記録し、loop 検出時に exit code 3 で abort 推奨を返す。"""
    h = args_hash(args.args_json)
    next_step = _query(
        f"SELECT COALESCE(MAX(step), 0) + 1 AS s FROM tool_invocations "
        f"WHERE run_id = {_sql_quote(args.run_id)};"
    )[0]["s"]
    sql = (
        f"INSERT INTO tool_invocations (run_id, step, tool_name, args_hash, args_json, result_summary, ts) "
        f"VALUES ({_sql_quote(args.run_id)}, {next_step}, {_sql_quote(args.tool)}, "
        f"{_sql_quote(h)}, {_sql_quote(args.args_json)}, {_sql_quote(args.result or '')}, "
        f"{_sql_quote(_now())});"
    )
    _exec(sql)

    if detect_loop(args.run_id):
        record_failure(args.run_id, "degeneration_loop", f"hash {h} repeated", "abort")
        print(f"LOOP_DETECTED step={next_step} hash={h}", file=sys.stderr)
        return 3
    return 0


def detect_loop(run_id: str, window: int = LOOP_WINDOW, threshold: int = LOOP_THRESHOLD) -> bool:
    rows = _query(
        f"SELECT args_hash FROM tool_invocations WHERE run_id = {_sql_quote(run_id)} "
        f"ORDER BY step DESC LIMIT {window};"
    )
    counts = Counter(r["args_hash"] for r in rows)
    return any(c >= threshold for c in counts.values())


def record_failure(run_id: str, mode: str, evidence: str, action: str) -> None:
    sql = (
        f"INSERT INTO failure_modes (run_id, mode_type, evidence, detected_ts, action_taken) "
        f"VALUES ({_sql_quote(run_id)}, {_sql_quote(mode)}, {_sql_quote(evidence)}, "
        f"{_sql_quote(_now())}, {_sql_quote(action)});"
    )
    _exec(sql)


def cmd_check_budget(args) -> int:
    """token / cost が予算を超えているかを判定。超過時は exit code 3 + 記録。"""
    rows = _query(
        f"SELECT total_tokens, total_cost_usd FROM agent_runs WHERE run_id = {_sql_quote(args.run_id)};"
    )
    if not rows:
        print(f"run {args.run_id} not found", file=sys.stderr)
        return 1
    tokens = rows[0].get("total_tokens") or 0
    cost = float(rows[0].get("total_cost_usd") or 0)
    if tokens > TOKEN_BUDGET:
        record_failure(args.run_id, "token_budget_exceeded", f"tokens={tokens}", "abort")
        print(f"TOKEN_EXCEEDED tokens={tokens}", file=sys.stderr)
        return 3
    if cost > COST_BUDGET_USD:
        record_failure(args.run_id, "cost_circuit_breaker", f"cost=${cost}", "abort")
        print(f"COST_EXCEEDED cost={cost}", file=sys.stderr)
        return 3
    print(f"ok tokens={tokens} cost={cost}")
    return 0


def cmd_update_usage(args) -> int:
    sql = (
        f"UPDATE agent_runs SET total_tokens = {args.tokens}, total_cost_usd = {args.cost} "
        f"WHERE run_id = {_sql_quote(args.run_id)};"
    )
    _exec(sql)
    return cmd_check_budget(args)


def cmd_record_gate(args) -> int:
    sql = (
        f"INSERT INTO quality_gates (run_id, gate_name, passed, output_summary, ts) "
        f"VALUES ({_sql_quote(args.run_id)}, {_sql_quote(args.gate)}, "
        f"{_sql_quote(args.passed.lower() == 'true')}, {_sql_quote(args.output or '')}, "
        f"{_sql_quote(_now())});"
    )
    _exec(sql)
    return 0


def cmd_end(args) -> int:
    sql = (
        f"UPDATE agent_runs SET end_ts = {_sql_quote(_now())}, status = {_sql_quote(args.status)} "
        f"WHERE run_id = {_sql_quote(args.run_id)};"
    )
    _exec(sql)
    return 0


def main() -> int:
    p = argparse.ArgumentParser(prog="harness", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init", help="DuckDB スキーマ作成").set_defaults(func=cmd_init)

    sp = sub.add_parser("start", help="run を開始し run_id を発行")
    sp.add_argument("--agent-type", required=True, choices=["claude-code", "codex"])
    sp.add_argument("--task", required=True)
    sp.add_argument("--language", required=True, choices=["rust", "scala", "typescript", "python", "other"])
    sp.set_defaults(func=cmd_start)

    sp = sub.add_parser("record-tool", help="tool 呼び出しを記録（loop 検出付き）")
    sp.add_argument("--run-id", required=True)
    sp.add_argument("--tool", required=True)
    sp.add_argument("--args-json", required=True)
    sp.add_argument("--result", default="")
    sp.set_defaults(func=cmd_record_tool)

    sp = sub.add_parser("update-usage", help="token / cost を更新し budget 超過を判定")
    sp.add_argument("--run-id", required=True)
    sp.add_argument("--tokens", type=int, required=True)
    sp.add_argument("--cost", type=float, required=True)
    sp.set_defaults(func=cmd_update_usage)

    sp = sub.add_parser("check-budget", help="現在の token / cost が予算内かチェック")
    sp.add_argument("--run-id", required=True)
    sp.set_defaults(func=cmd_check_budget)

    sp = sub.add_parser("record-gate", help="quality gate 結果を記録")
    sp.add_argument("--run-id", required=True)
    sp.add_argument("--gate", required=True)
    sp.add_argument("--passed", required=True, choices=["true", "false"])
    sp.add_argument("--output", default="")
    sp.set_defaults(func=cmd_record_gate)

    sp = sub.add_parser("end", help="run を終了")
    sp.add_argument("--run-id", required=True)
    sp.add_argument("--status", required=True, choices=["completed", "aborted", "manual_intervention"])
    sp.set_defaults(func=cmd_end)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
