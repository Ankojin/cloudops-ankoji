-- =============================================================
-- Migration: separate all-worker vs standard-worker-only capacity,
-- and add per-pool requested/utilization/pressure to pool_snapshots.
--
-- Run this once against the LIVE database — init.sql only executes
-- on a brand-new Postgres volume (docker-entrypoint-initdb.d), so it
-- will not apply these changes to an already-running deployment.
--
-- Usage:
--   psql "$DATABASE_URL" -f migration_pool_scoping.sql
-- =============================================================

ALTER TABLE namespace_snapshots
  ADD COLUMN IF NOT EXISTS cpu_used         NUMERIC(10,3),
  ADD COLUMN IF NOT EXISTS mem_used_gib     NUMERIC(10,2),
  ADD COLUMN IF NOT EXISTS cpu_util_pct     NUMERIC(6,1),
  ADD COLUMN IF NOT EXISTS mem_util_pct     NUMERIC(6,1),
  ADD COLUMN IF NOT EXISTS rightsizing_signal VARCHAR(30);

ALTER TABLE capacity_snapshots
  ADD COLUMN IF NOT EXISTS worker_cpu_requested     NUMERIC(10,3),
  ADD COLUMN IF NOT EXISTS worker_mem_gib_requested NUMERIC(10,1),
  ADD COLUMN IF NOT EXISTS all_worker_cpu           NUMERIC(10,3),
  ADD COLUMN IF NOT EXISTS all_worker_mem_gib       NUMERIC(10,1),
  ADD COLUMN IF NOT EXISTS pvc_count                INTEGER,
  ADD COLUMN IF NOT EXISTS pvc_capacity_gib_total    NUMERIC(12,1);

ALTER TABLE pool_snapshots
  ADD COLUMN IF NOT EXISTS cpu_cores_requested    NUMERIC(10,3),
  ADD COLUMN IF NOT EXISTS memory_gib_requested   NUMERIC(10,1),
  ADD COLUMN IF NOT EXISTS cpu_utilization_pct    NUMERIC(6,2),
  ADD COLUMN IF NOT EXISTS memory_utilization_pct NUMERIC(6,2),
  ADD COLUMN IF NOT EXISTS pressure_level         VARCHAR(20);

-- NEW TABLE: PVCs were always collected by collect_capacity.sh but never
-- persisted anywhere — this closes that gap. IF NOT EXISTS makes this safe
-- to re-run alongside the ALTERs above.
CREATE TABLE IF NOT EXISTS pvc_snapshots (
  id             SERIAL PRIMARY KEY,
  snapshot_id    INTEGER REFERENCES capacity_snapshots(id) ON DELETE CASCADE,
  env            VARCHAR(10)   NOT NULL,
  collected_at   TIMESTAMPTZ   NOT NULL,
  namespace      VARCHAR(200),
  pvc_name       VARCHAR(200),
  status         VARCHAR(20),
  capacity_gib   NUMERIC(12,2),
  storageclass   VARCHAR(100)
);

CREATE INDEX IF NOT EXISTS idx_pvc_snapshots_env
  ON pvc_snapshots (env, collected_at DESC);
CREATE INDEX IF NOT EXISTS idx_pvc_snapshots_namespace
  ON pvc_snapshots (env, namespace);
