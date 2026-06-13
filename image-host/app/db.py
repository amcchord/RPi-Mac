"""SQLite storage shared by the pimac web app and the builder worker.

The database lives under the data root (PIMAC_ROOT, default /srv/pimac)
so both the web app (user "pimac") and the builder worker (root) can
reach it. WAL mode keeps cross-process access painless.
"""

import json
import os
import secrets
import sqlite3
import time

PIMAC_ROOT = os.environ.get("PIMAC_ROOT", "/srv/pimac")
DATA_DIR = os.path.join(PIMAC_ROOT, "data")
DB_PATH = os.path.join(DATA_DIR, "pimac.db")

RELEASES_DIR = os.path.join(PIMAC_ROOT, "releases")
LIBRARY_DIR = os.path.join(PIMAC_ROOT, "library")
BUILDS_DIR = os.path.join(PIMAC_ROOT, "builds")
SCRATCH_DIR = os.path.join(PIMAC_ROOT, "scratch")

COMPONENT_KINDS = ("rom", "disk", "iso")

SCHEMA = """
CREATE TABLE IF NOT EXISTS components (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL CHECK (kind IN ('rom', 'disk', 'iso')),
    filename TEXT NOT NULL,
    display_name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    size_bytes INTEGER NOT NULL DEFAULT 0,
    sort_order INTEGER NOT NULL DEFAULT 100,
    created_at INTEGER NOT NULL,
    UNIQUE (kind, filename)
);

CREATE TABLE IF NOT EXISTS jobs (
    id TEXT PRIMARY KEY,
    token TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'queued',
    stage TEXT NOT NULL DEFAULT 'Waiting in line...',
    percent INTEGER NOT NULL DEFAULT 0,
    params TEXT NOT NULL,
    error TEXT NOT NULL DEFAULT '',
    output_name TEXT NOT NULL DEFAULT '',
    output_size INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    started_at INTEGER,
    finished_at INTEGER,
    expires_at INTEGER
);

CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""


def connect():
    os.makedirs(DATA_DIR, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=30000")
    conn.executescript(SCHEMA)
    return conn


# ------------------------------------------------------------- settings ---

def get_setting(conn, key, default=None):
    row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    if row is None:
        return default
    return row["value"]


def set_setting(conn, key, value):
    conn.execute(
        "INSERT INTO settings (key, value) VALUES (?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (key, value),
    )
    conn.commit()


def secret_key(conn):
    key = get_setting(conn, "secret_key")
    if key is None:
        key = secrets.token_hex(32)
        set_setting(conn, "secret_key", key)
    return key


# ----------------------------------------------------------- components ---

def component_dir(kind):
    return os.path.join(LIBRARY_DIR, kind + "s")


def component_path(comp):
    return os.path.join(component_dir(comp["kind"]), comp["filename"])


def list_components(conn, kind=None):
    if kind is None:
        rows = conn.execute(
            "SELECT * FROM components ORDER BY kind, sort_order, display_name"
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT * FROM components WHERE kind = ? ORDER BY sort_order, display_name",
            (kind,),
        ).fetchall()
    return [dict(r) for r in rows]


def get_component(conn, comp_id):
    row = conn.execute("SELECT * FROM components WHERE id = ?", (comp_id,)).fetchone()
    if row is None:
        return None
    return dict(row)


def add_component(conn, kind, filename, display_name, description=""):
    path = os.path.join(component_dir(kind), filename)
    size = 0
    if os.path.exists(path):
        size = os.path.getsize(path)
    conn.execute(
        "INSERT INTO components (kind, filename, display_name, description,"
        " size_bytes, created_at) VALUES (?, ?, ?, ?, ?, ?) "
        "ON CONFLICT(kind, filename) DO UPDATE SET size_bytes = excluded.size_bytes",
        (kind, filename, display_name, description, size, int(time.time())),
    )
    conn.commit()
    row = conn.execute(
        "SELECT * FROM components WHERE kind = ? AND filename = ?", (kind, filename)
    ).fetchone()
    return dict(row)


# ----------------------------------------------------------------- jobs ---

def create_job(conn, params):
    job_id = secrets.token_hex(8)
    token = secrets.token_urlsafe(24)
    conn.execute(
        "INSERT INTO jobs (id, token, params, created_at) VALUES (?, ?, ?, ?)",
        (job_id, token, json.dumps(params), int(time.time())),
    )
    conn.commit()
    return job_id, token


def get_job(conn, job_id):
    row = conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
    if row is None:
        return None
    return dict(row)


def update_job(conn, job_id, **fields):
    keys = sorted(fields.keys())
    assignments = ", ".join(k + " = ?" for k in keys)
    values = [fields[k] for k in keys]
    values.append(job_id)
    conn.execute("UPDATE jobs SET " + assignments + " WHERE id = ?", values)
    conn.commit()


def claim_next_job(conn):
    """Atomically pick the oldest queued job and mark it running."""
    row = conn.execute(
        "UPDATE jobs SET status = 'running', started_at = ?,"
        " stage = 'Starting...', percent = 1 "
        "WHERE id = (SELECT id FROM jobs WHERE status = 'queued'"
        " ORDER BY created_at LIMIT 1) RETURNING *",
        (int(time.time()),),
    ).fetchone()
    conn.commit()
    if row is None:
        return None
    return dict(row)


def queue_position(conn, job_id):
    job = get_job(conn, job_id)
    if job is None or job["status"] != "queued":
        return 0
    row = conn.execute(
        "SELECT COUNT(*) AS n FROM jobs WHERE status = 'queued' AND created_at < ?",
        (job["created_at"],),
    ).fetchone()
    return row["n"] + 1
