CREATE TABLE IF NOT EXISTS agent_runs (
  run_id TEXT PRIMARY KEY,
  agent_type TEXT,
  task_description TEXT,
  language TEXT,
  start_ts TIMESTAMP,
  end_ts TIMESTAMP,
  total_tokens INTEGER,
  total_cost_usd DECIMAL(10,4),
  status TEXT
);

CREATE TABLE IF NOT EXISTS tool_invocations (
  run_id TEXT,
  step INTEGER,
  tool_name TEXT,
  args_hash TEXT,
  args_json TEXT,
  result_summary TEXT,
  ts TIMESTAMP
);

CREATE TABLE IF NOT EXISTS failure_modes (
  run_id TEXT,
  mode_type TEXT,
  evidence TEXT,
  detected_ts TIMESTAMP,
  action_taken TEXT
);

CREATE TABLE IF NOT EXISTS quality_gates (
  run_id TEXT,
  gate_name TEXT,
  passed BOOLEAN,
  output_summary TEXT,
  ts TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_tool_run_step ON tool_invocations(run_id, step);
CREATE INDEX IF NOT EXISTS idx_failure_run ON failure_modes(run_id);
CREATE INDEX IF NOT EXISTS idx_gate_run ON quality_gates(run_id);
