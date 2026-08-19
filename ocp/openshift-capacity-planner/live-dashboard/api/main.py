"""
OpenShift Capacity Planner — FastAPI backend
============================================
Serves live metrics from PostgreSQL for DEV and SIT clusters.

Endpoints
---------
GET /api/v1/health              → liveness probe
GET /api/v1/status              → latest snapshot for BOTH envs
GET /api/v1/metrics/{env}       → latest snapshot for one env
GET /api/v1/history/{env}       → last N hours of snapshots (trend)
GET /api/v1/pools/{env}         → dedicated node pool detail
GET /api/v1/namespaces/{env}    → top tenant namespace usage
"""

import csv
import io
import os
import json
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Optional

import ssl
import asyncpg
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse

# ── DB connection ─────────────────────────────────────────────
# Individual params are preferred — they avoid URL-encoding issues
# with passwords that contain special characters (# @ : etc.).
# Always use SSL — Azure PostgreSQL Flexible Server enforces it.
_ssl_ctx = ssl.create_default_context()
_ssl_ctx.check_hostname = False
_ssl_ctx.verify_mode = ssl.CERT_NONE  # Azure uses self-signed intermediates

_DATABASE_URL = os.getenv("DATABASE_URL", "")

if _DATABASE_URL:
    # Legacy / Docker Compose path — ensure sslmode is present in DSN
    _dsn = _DATABASE_URL
    if "sslmode=" not in _dsn:
        _sep = "&" if "?" in _dsn else "?"
        _dsn += f"{_sep}sslmode=require"
    DB_KWARGS: dict = {"dsn": _dsn, "ssl": _ssl_ctx}
else:
    DB_KWARGS = {
        "host":     os.getenv("DB_HOST",     "postgres"),
        "port":     int(os.getenv("DB_PORT", "5432")),
        "user":     os.getenv("DB_USER",     "planner"),
        "password": os.getenv("DB_PASSWORD", "planner"),
        "database": os.getenv("DB_NAME",     "capacity"),
        "ssl":      _ssl_ctx,   # SSLContext is accepted by all asyncpg versions
    }

pool: asyncpg.Pool = None  # type: ignore


@asynccontextmanager
async def lifespan(app: FastAPI):
    global pool
    pool = await asyncpg.create_pool(
        **DB_KWARGS,
        min_size=2,
        max_size=10,
        command_timeout=30,
    )
    yield
    await pool.close()


app = FastAPI(
    title="OpenShift Capacity Planner API",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET"],
    allow_headers=["*"],
)


# ── Helpers ───────────────────────────────────────────────────
def _float(v, default=0.0):
    try:
        return float(v) if v is not None else default
    except (TypeError, ValueError):
        return default


def _int(v, default=0):
    try:
        return int(v) if v is not None else default
    except (TypeError, ValueError):
        return default


def _row_to_dict(row) -> dict:
    """Convert asyncpg Record to plain dict with serializable types."""
    d = dict(row)
    for k, v in d.items():
        if isinstance(v, datetime):
            d[k] = v.isoformat()
        elif hasattr(v, "__float__"):
            d[k] = float(v)
    return d


def _pressure_color(pressure: str) -> str:
    colors = {"GREEN": "#27ae60", "YELLOW": "#f39c12", "RED": "#e74c3c"}
    return colors.get((pressure or "").upper(), "#95a5a6")


# ── Routes ────────────────────────────────────────────────────

@app.get("/api/v1/health")
async def health():
    try:
        async with pool.acquire() as conn:
            await conn.fetchval("SELECT 1")
        return {"status": "ok", "db": "connected"}
    except Exception as exc:
        raise HTTPException(status_code=503, detail=str(exc))


@app.get("/api/v1/status")
async def status():
    """Latest snapshot for both DEV and SIT — used by the dashboard overview."""
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            "SELECT * FROM latest_snapshots ORDER BY env"
        )
    result = {}
    for row in rows:
        d = _row_to_dict(row)
        env = d["env"]
        d["pressure_color"] = _pressure_color(d.get("pressure", ""))
        # Remove large JSON blobs from overview — fetch details separately
        d.pop("raw_summary", None)
        d.pop("raw_planning", None)
        d.pop("raw_util", None)
        result[env] = d

    return {"envs": result, "fetched_at": datetime.now(timezone.utc).isoformat()}


@app.get("/api/v1/metrics/{env}")
async def metrics(env: str):
    """Full latest snapshot for one environment."""
    env = env.upper()
    if env not in ("DEV", "SIT"):
        raise HTTPException(status_code=400, detail="env must be DEV or SIT")

    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            """
            SELECT * FROM capacity_snapshots
            WHERE env = $1
            ORDER BY collected_at DESC
            LIMIT 1
            """,
            env,
        )

    if row is None:
        raise HTTPException(status_code=404, detail=f"No data for env={env}")

    d = _row_to_dict(row)
    d["pressure_color"] = _pressure_color(d.get("pressure", ""))
    return d


@app.get("/api/v1/history/{env}")
async def history(
    env: str,
    hours: int = Query(default=24, ge=1, le=168),
):
    """Time-series data for trend sparklines (last N hours, max 50 points)."""
    env = env.upper()
    if env not in ("DEV", "SIT"):
        raise HTTPException(status_code=400, detail="env must be DEV or SIT")

    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT collected_at, cpu_pct, mem_pct, pods_running, pressure,
                   worker_nodes, cpu_used, mem_used_gib
            FROM capacity_snapshots
            WHERE env = $1
              AND collected_at >= NOW() - ($2 || ' hours')::interval
            ORDER BY collected_at ASC
            LIMIT 50
            """,
            env,
            str(hours),
        )

    return {
        "env": env,
        "hours": hours,
        "points": [_row_to_dict(r) for r in rows],
    }


@app.get("/api/v1/pools/{env}")
async def pools(env: str):
    """Latest dedicated node pool details for one environment."""
    env = env.upper()
    if env not in ("DEV", "SIT"):
        raise HTTPException(status_code=400, detail="env must be DEV or SIT")

    async with pool.acquire() as conn:
        # Get the most recent snapshot id for this env
        snap_id = await conn.fetchval(
            """
            SELECT id FROM capacity_snapshots
            WHERE env = $1
            ORDER BY collected_at DESC LIMIT 1
            """,
            env,
        )
        if snap_id is None:
            raise HTTPException(status_code=404, detail=f"No data for env={env}")

        rows = await conn.fetch(
            """
            SELECT pool_name, taint_key, taint_value, effect,
                   dedicated, node_count, cpu_cores, memory_gib, namespaces
            FROM pool_snapshots
            WHERE snapshot_id = $1
            ORDER BY dedicated DESC, pool_name
            """,
            snap_id,
        )

    result = []
    for row in rows:
        d = _row_to_dict(row)
        # namespaces is stored as JSONB — comes back as a string in asyncpg
        ns = d.get("namespaces")
        if isinstance(ns, str):
            try:
                d["namespaces"] = json.loads(ns)
            except json.JSONDecodeError:
                d["namespaces"] = []
        result.append(d)

    return {"env": env, "pools": result}


@app.get("/api/v1/namespaces/{env}")
async def namespaces(
    env: str,
    top: int = Query(default=20, ge=5, le=100),
):
    """Top tenant namespaces by CPU for one environment (latest snapshot)."""
    env = env.upper()
    if env not in ("DEV", "SIT"):
        raise HTTPException(status_code=400, detail="env must be DEV or SIT")

    async with pool.acquire() as conn:
        snap_id = await conn.fetchval(
            """
            SELECT id FROM capacity_snapshots
            WHERE env = $1
            ORDER BY collected_at DESC LIMIT 1
            """,
            env,
        )
        if snap_id is None:
            raise HTTPException(status_code=404, detail=f"No data for env={env}")

        rows = await conn.fetch(
            """
            SELECT namespace, ns_type, pod_count, cpu_req,
                   mem_req_gib, cpu_pct, mem_pct
            FROM namespace_snapshots
            WHERE snapshot_id = $1 AND ns_type = 'tenant'
            ORDER BY cpu_req DESC NULLS LAST
            LIMIT $2
            """,
            snap_id,
            top,
        )

    return {
        "env": env,
        "namespaces": [_row_to_dict(r) for r in rows],
    }


# ── Aggregate (monthly / quarterly / yearly) ──────────────────
@app.get("/api/v1/aggregate/{env}")
async def aggregate(
    env: str,
    period: str = Query(default="monthly", regex="^(monthly|quarterly|yearly)$"),
):
    """
    Aggregated capacity statistics per period for trend / capacity planning.

    period: monthly | quarterly | yearly
    Returns avg/max CPU%, avg/max Mem%, avg pods, avg worker nodes, snapshot count.
    """
    env = env.upper()
    if env not in ("DEV", "SIT"):
        raise HTTPException(status_code=400, detail="env must be DEV or SIT")

    trunc_map = {
        "monthly":   "month",
        "quarterly": "quarter",
        "yearly":    "year",
    }
    trunc = trunc_map[period]

    async with pool.acquire() as conn:
        rows = await conn.fetch(
            f"""
            SELECT
                DATE_TRUNC('{trunc}', collected_at AT TIME ZONE 'UTC') AS period_start,
                COUNT(*)                         AS snapshot_count,
                ROUND(AVG(cpu_pct)::numeric, 2)  AS avg_cpu_pct,
                ROUND(MAX(cpu_pct)::numeric, 2)  AS max_cpu_pct,
                ROUND(AVG(mem_pct)::numeric, 2)  AS avg_mem_pct,
                ROUND(MAX(mem_pct)::numeric, 2)  AS max_mem_pct,
                ROUND(AVG(pods_running)::numeric, 0) AS avg_pods,
                ROUND(MAX(pods_running)::numeric, 0) AS max_pods,
                ROUND(AVG(worker_nodes)::numeric, 1) AS avg_worker_nodes,
                ROUND(AVG(cpu_used)::numeric, 2)     AS avg_cpu_used,
                ROUND(AVG(mem_used_gib)::numeric, 2) AS avg_mem_used_gib,
                ROUND(AVG(total_cpu)::numeric, 2)    AS avg_total_cpu,
                ROUND(AVG(total_mem_gib)::numeric, 2) AS avg_total_mem_gib
            FROM capacity_snapshots
            WHERE env = $1
            GROUP BY period_start
            ORDER BY period_start ASC
            """,
            env,
        )

    result = []
    for row in rows:
        d = dict(row)
        for k, v in d.items():
            if isinstance(v, datetime):
                d[k] = v.isoformat()
            elif v is not None and hasattr(v, "__float__"):
                d[k] = float(v)
        result.append(d)

    return {
        "env": env,
        "period": period,
        "data": result,
    }


# ── CSV Export ────────────────────────────────────────────────
@app.get("/api/v1/export/{env}")
async def export_csv(
    env: str,
    period: str = Query(default="monthly", regex="^(monthly|quarterly|yearly|raw)$"),
):
    """
    Export capacity data as CSV.

    period: monthly | quarterly | yearly | raw (every snapshot, last 365 days)
    """
    env = env.upper()
    if env not in ("DEV", "SIT"):
        raise HTTPException(status_code=400, detail="env must be DEV or SIT")

    async with pool.acquire() as conn:
        if period == "raw":
            rows = await conn.fetch(
                """
                SELECT
                    collected_at, env, total_cpu, total_mem_gib,
                    cpu_pct, mem_pct, cpu_used, mem_used_gib,
                    node_count, worker_nodes, master_nodes, infra_nodes,
                    pods_running, ns_count, pressure
                FROM capacity_snapshots
                WHERE env = $1
                ORDER BY collected_at ASC
                """,
                env,
            )
            fieldnames = [
                "collected_at", "env", "total_cpu", "total_mem_gib",
                "cpu_pct", "mem_pct", "cpu_used", "mem_used_gib",
                "node_count", "worker_nodes", "master_nodes", "infra_nodes",
                "pods_running", "ns_count", "pressure",
            ]
        else:
            # Reuse aggregate query
            trunc_map = {"monthly": "month", "quarterly": "quarter", "yearly": "year"}
            trunc = trunc_map[period]
            rows = await conn.fetch(
                f"""
                SELECT
                    DATE_TRUNC('{trunc}', collected_at AT TIME ZONE 'UTC') AS period_start,
                    COUNT(*)                          AS snapshot_count,
                    ROUND(AVG(cpu_pct)::numeric, 2)   AS avg_cpu_pct,
                    ROUND(MAX(cpu_pct)::numeric, 2)   AS max_cpu_pct,
                    ROUND(AVG(mem_pct)::numeric, 2)   AS avg_mem_pct,
                    ROUND(MAX(mem_pct)::numeric, 2)   AS max_mem_pct,
                    ROUND(AVG(pods_running)::numeric, 0) AS avg_pods,
                    ROUND(MAX(pods_running)::numeric, 0) AS max_pods,
                    ROUND(AVG(worker_nodes)::numeric, 1) AS avg_worker_nodes,
                    ROUND(AVG(cpu_used)::numeric, 2)     AS avg_cpu_used,
                    ROUND(AVG(mem_used_gib)::numeric, 2) AS avg_mem_used_gib,
                    ROUND(AVG(total_cpu)::numeric, 2)    AS avg_total_cpu,
                    ROUND(AVG(total_mem_gib)::numeric, 2) AS avg_total_mem_gib
                FROM capacity_snapshots
                WHERE env = $1
                GROUP BY period_start
                ORDER BY period_start ASC
                """,
                env,
            )
            fieldnames = [
                "period_start", "snapshot_count",
                "avg_cpu_pct", "max_cpu_pct",
                "avg_mem_pct", "max_mem_pct",
                "avg_pods", "max_pods",
                "avg_worker_nodes",
                "avg_cpu_used", "avg_mem_used_gib",
                "avg_total_cpu", "avg_total_mem_gib",
            ]

    output = io.StringIO()
    writer = csv.DictWriter(output, fieldnames=fieldnames, extrasaction="ignore")
    writer.writeheader()
    for row in rows:
        d = dict(row)
        for k, v in d.items():
            if isinstance(v, datetime):
                d[k] = v.strftime("%Y-%m-%d %H:%M:%S")
        writer.writerow(d)

    filename = f"capacity_{env.lower()}_{period}_{datetime.now(timezone.utc).strftime('%Y%m%d')}.csv"
    return StreamingResponse(
        iter([output.getvalue()]),
        media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )
