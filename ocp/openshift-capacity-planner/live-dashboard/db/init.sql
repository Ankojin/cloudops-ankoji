-- =============================================================
-- OpenShift Capacity Planner — PostgreSQL Schema
-- =============================================================

-- ─── Main snapshot per collection run ────────────────────────
CREATE TABLE IF NOT EXISTS capacity_snapshots (
  id             SERIAL PRIMARY KEY,
  env            VARCHAR(10)   NOT NULL,        -- 'DEV' | 'SIT'
  collected_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  -- Cluster-wide capacity
  total_cpu      NUMERIC(10,3),
  total_mem_gib  NUMERIC(10,1),
  cpu_pct        NUMERIC(5,2),
  mem_pct        NUMERIC(5,2),
  node_count     INTEGER,
  ns_count       INTEGER,
  pvc_count              INTEGER,
  pvc_capacity_gib_total NUMERIC(12,1),

  -- Worker pool (STANDARD workers only — dedicated/tainted pools excluded).
  -- Used by Growth Forecast and Capacity Planning — Worker Pool, where
  -- mixing in dedicated-pool capacity/demand would misrepresent pressure
  -- on the general-purpose pool.
  worker_nodes            INTEGER,
  worker_cpu              NUMERIC(10,3),
  worker_mem_gib          NUMERIC(10,1),
  worker_cpu_requested    NUMERIC(10,3),
  worker_mem_gib_requested NUMERIC(10,1),
  pressure                VARCHAR(20),

  -- ALL worker nodes, dedicated pools included. Used by the Overview cards
  -- and Worker Pool Utilization widget, which are meant to reflect total
  -- physical worker inventory, not just the standard/general-purpose pool.
  all_worker_cpu          NUMERIC(10,3),
  all_worker_mem_gib      NUMERIC(10,1),

  -- Master pool
  master_nodes   INTEGER,
  master_cpu     NUMERIC(10,3),
  master_mem_gib NUMERIC(10,1),

  -- Infra pool
  infra_nodes    INTEGER,
  infra_cpu      NUMERIC(10,3),
  infra_mem_gib  NUMERIC(10,1),

  -- Live utilization (from Prometheus)
  cpu_used       NUMERIC(10,3),
  mem_used_gib   NUMERIC(10,1),
  pods_running   INTEGER,
  ephem_pod_gib  NUMERIC(10,1),

  -- Full raw JSON blobs (kept for advanced queries / drill-down)
  raw_summary    JSONB,
  raw_planning   JSONB,
  raw_util       JSONB
);

CREATE INDEX IF NOT EXISTS idx_snapshots_env_time
  ON capacity_snapshots (env, collected_at DESC);

-- ─── Per-pool detail per collection run ──────────────────────
CREATE TABLE IF NOT EXISTS pool_snapshots (
  id           SERIAL PRIMARY KEY,
  snapshot_id  INTEGER REFERENCES capacity_snapshots(id) ON DELETE CASCADE,
  env          VARCHAR(10)   NOT NULL,
  collected_at TIMESTAMPTZ   NOT NULL,
  pool_name    VARCHAR(200),
  taint_key    VARCHAR(200),
  taint_value  VARCHAR(200),
  effect       VARCHAR(50),
  dedicated    BOOLEAN,
  node_count   INTEGER,
  cpu_cores    NUMERIC(10,3),
  memory_gib   NUMERIC(10,1),
  cpu_cores_requested     NUMERIC(10,3),
  memory_gib_requested    NUMERIC(10,1),
  cpu_utilization_pct     NUMERIC(6,2),
  memory_utilization_pct  NUMERIC(6,2),
  pressure_level          VARCHAR(20),
  namespaces   JSONB          -- [{namespace, pod_count}, ...]
);

CREATE INDEX IF NOT EXISTS idx_pool_snapshots_env
  ON pool_snapshots (env, collected_at DESC);

-- ─── Per-namespace chargeback per collection run ─────────────
CREATE TABLE IF NOT EXISTS namespace_snapshots (
  id             SERIAL PRIMARY KEY,
  snapshot_id    INTEGER REFERENCES capacity_snapshots(id) ON DELETE CASCADE,
  env            VARCHAR(10)   NOT NULL,
  collected_at   TIMESTAMPTZ   NOT NULL,
  namespace      VARCHAR(200),
  ns_type        VARCHAR(20),  -- 'tenant' | 'platform'
  pod_count      INTEGER,
  cpu_req        NUMERIC(10,3),
  mem_req_gib    NUMERIC(10,1),
  cpu_pct        NUMERIC(6,3),
  mem_pct        NUMERIC(6,3),
  cpu_used       NUMERIC(10,3),
  mem_used_gib   NUMERIC(10,2),
  cpu_util_pct   NUMERIC(6,1),
  mem_util_pct   NUMERIC(6,1),
  rightsizing_signal VARCHAR(30)
);

CREATE INDEX IF NOT EXISTS idx_ns_snapshots_env
  ON namespace_snapshots (env, collected_at DESC);

-- ─── Per-PVC inventory per collection run ─────────────────────
-- NOTE: PVCs were collected by collect_capacity.sh from the start (see
-- pvc_inventory.csv) but never persisted to the database — this table and
-- the corresponding insert_to_db.sh/API wiring closes that gap.
CREATE TABLE IF NOT EXISTS pvc_snapshots (
  id             SERIAL PRIMARY KEY,
  snapshot_id    INTEGER REFERENCES capacity_snapshots(id) ON DELETE CASCADE,
  env            VARCHAR(10)   NOT NULL,
  collected_at   TIMESTAMPTZ   NOT NULL,
  namespace      VARCHAR(200),
  pvc_name       VARCHAR(200),
  status         VARCHAR(20),   -- Bound | Pending | Lost
  capacity_gib   NUMERIC(12,2),
  storageclass   VARCHAR(100)
);

CREATE INDEX IF NOT EXISTS idx_pvc_snapshots_env
  ON pvc_snapshots (env, collected_at DESC);
CREATE INDEX IF NOT EXISTS idx_pvc_snapshots_namespace
  ON pvc_snapshots (env, namespace);

-- ─── Convenience view: latest snapshot per env ───────────────
CREATE OR REPLACE VIEW latest_snapshots AS
SELECT DISTINCT ON (env) *
FROM capacity_snapshots
ORDER BY env, collected_at DESC;

-- ─── Retention: auto-purge snapshots older than 30 days ──────
-- Run via a pg_cron job if available, or a scheduled DELETE.
-- DELETE FROM capacity_snapshots WHERE collected_at < NOW() - INTERVAL '30 days';
