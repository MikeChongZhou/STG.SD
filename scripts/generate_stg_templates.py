#!/usr/bin/env python3
"""Generate the canonical, cross-platform STG SQLite template."""

from __future__ import annotations

import json
from pathlib import Path
import sqlite3
from datetime import datetime


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "shared/openrouter/openrouter-weekly-seed-v1.json"
OUTPUT = ROOT / "apple/STGCore/Sources/STGCore/Resources/stg.sqlite"
OLD_OUTPUTS = (
    ROOT / "shared/database/stg.sqlite",
    ROOT / "apple/STGCore/Sources/STGCore/Resources/stg-template.sqlite",
    ROOT / "windows/ScreenTimeGuardian/Assets/stg-template.sqlite",
    ROOT / "android/app/src/main/assets/stg-template.sqlite",
)

SCHEMA_VERSION = 7
APPLICATION_ID = 0x535447


def main() -> None:
    document = json.loads(SOURCE.read_text(encoding="utf-8"))
    if document.get("schema") != 1 or not document.get("rows"):
        raise SystemExit("invalid OpenRouter seed")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.unlink(missing_ok=True)
    for old_output in OLD_OUTPUTS:
        old_output.unlink(missing_ok=True)

    connection = sqlite3.connect(OUTPUT)
    connection.execute("PRAGMA journal_mode=DELETE")
    connection.execute("PRAGMA synchronous=OFF")
    connection.executescript(
        f"""
        CREATE TABLE bitmap(device_id TEXT NOT NULL,utc_date TEXT NOT NULL,bits BLOB NOT NULL,updated_at INTEGER NOT NULL,PRIMARY KEY(device_id,utc_date));
        CREATE TABLE device(device_id TEXT PRIMARY KEY,name TEXT NOT NULL,kind TEXT NOT NULL,updated_at INTEGER NOT NULL);
        CREATE TABLE reminder_state(device_id TEXT PRIMARY KEY,last_eye_at INTEGER NOT NULL,last_posture_at INTEGER NOT NULL,last_reminder TEXT,updated_at INTEGER NOT NULL);
        CREATE TABLE sync_state(device_id TEXT PRIMARY KEY,last_quick_upload_at INTEGER NOT NULL DEFAULT 0,last_quick_bidirectional_at INTEGER NOT NULL DEFAULT 0,last_incremental_sync_at INTEGER NOT NULL DEFAULT 0,last_statistics_at INTEGER NOT NULL DEFAULT 0,last_weekly_action_at INTEGER NOT NULL DEFAULT 0,last_yearly_action_at INTEGER NOT NULL DEFAULT 0,last_posture_at INTEGER NOT NULL DEFAULT 0,last_eye_at INTEGER NOT NULL DEFAULT 0,bitmap_updated_at INTEGER NOT NULL DEFAULT 0,continuous_minutes INTEGER NOT NULL DEFAULT 0,local_daily_minutes INTEGER NOT NULL DEFAULT 0,aggregate_daily_minutes INTEGER NOT NULL DEFAULT 0,state_local_date TEXT);
        CREATE TABLE pending_quick_upload(device_id TEXT NOT NULL,utc_date TEXT NOT NULL,queued_at INTEGER NOT NULL,PRIMARY KEY(device_id,utc_date));
        CREATE TABLE incremental_download_cursor(remote_device_id TEXT PRIMARY KEY,latest_utc_date TEXT NOT NULL,updated_at INTEGER NOT NULL);
        CREATE TABLE incremental_upload_cursor(sync_target TEXT PRIMARY KEY,latest_utc_date TEXT NOT NULL,updated_at INTEGER NOT NULL);
        CREATE TABLE maintenance_state(action TEXT PRIMARY KEY,completed_at TEXT NOT NULL,updated_at INTEGER NOT NULL);
        CREATE TABLE statistics_state(id INTEGER PRIMARY KEY CHECK(id=1),last_statistics_at INTEGER NOT NULL DEFAULT 0,dirty_from_date TEXT,updated_at INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE daily_statistics(device_id TEXT NOT NULL,report_date TEXT NOT NULL,minutes INTEGER NOT NULL,daily_limit_minutes INTEGER NOT NULL,source_updated_at INTEGER NOT NULL,calculated_at INTEGER NOT NULL,estimated INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(device_id,report_date));
        CREATE TABLE weekly_statistics(device_id TEXT NOT NULL,iso_year INTEGER NOT NULL,iso_week INTEGER NOT NULL,period_start TEXT NOT NULL,period_end TEXT NOT NULL,average_daily_minutes REAL NOT NULL,included_days INTEGER NOT NULL,excluded_days INTEGER NOT NULL,calculated_at INTEGER NOT NULL,estimated INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(device_id,iso_year,iso_week));
        CREATE TABLE monthly_statistics(device_id TEXT NOT NULL,year INTEGER NOT NULL,month INTEGER NOT NULL,period_start TEXT NOT NULL,period_end TEXT NOT NULL,average_daily_minutes REAL NOT NULL,included_days INTEGER NOT NULL,excluded_days INTEGER NOT NULL,calculated_at INTEGER NOT NULL,estimated INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(device_id,year,month));
        CREATE TABLE yearly_statistics(device_id TEXT NOT NULL,year INTEGER NOT NULL,period_start TEXT NOT NULL,period_end TEXT NOT NULL,average_daily_minutes REAL NOT NULL,included_days INTEGER NOT NULL,excluded_days INTEGER NOT NULL,calculated_at INTEGER NOT NULL,estimated INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(device_id,year));
        CREATE TABLE openrouter_weekly(week_start TEXT NOT NULL,week_end TEXT NOT NULL,model TEXT NOT NULL,rank INTEGER NOT NULL,prompt_tokens INTEGER NOT NULL,completion_tokens INTEGER NOT NULL,total_tokens INTEGER NOT NULL,prompt_price REAL,completion_price REAL,revenue REAL,as_of TEXT,missing_dates TEXT NOT NULL DEFAULT '[]',is_complete INTEGER NOT NULL DEFAULT 1,updated_at INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(week_start,model));
        CREATE TABLE archive_manifest(archive_id TEXT PRIMARY KEY,kind TEXT NOT NULL,period_start TEXT NOT NULL,period_end TEXT NOT NULL,local_path TEXT,cloud_path TEXT,checksum TEXT,created_at INTEGER NOT NULL,uploaded_at INTEGER,status TEXT NOT NULL);
        INSERT INTO statistics_state(id,last_statistics_at,dirty_from_date,updated_at) VALUES(1,0,NULL,0);
        PRAGMA user_version={SCHEMA_VERSION};
        PRAGMA application_id={APPLICATION_ID};
        """
    )
    missing_dates = tuple(document.get("missing_dates", ()))
    as_of = document.get("as_of")
    updated_at = int(datetime.fromisoformat(as_of.replace("Z", "+00:00")).timestamp()) if as_of else 0
    rows = []
    for row in document["rows"]:
        missing = [value for value in missing_dates if row["s"] <= value <= row["e"]]
        rows.append((row["s"], row["e"], row["m"], row["r"], -1, -1, row["t"], None, None, None, as_of, json.dumps(missing, separators=(",", ":")), 0 if missing else 1, updated_at))
    connection.executemany(
        "INSERT INTO openrouter_weekly(week_start,week_end,model,rank,prompt_tokens,completion_tokens,total_tokens,prompt_price,completion_price,revenue,as_of,missing_dates,is_complete,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        rows,
    )
    connection.commit()
    connection.execute("VACUUM")
    connection.close()
    print(f"generated {OUTPUT.relative_to(ROOT)} ({OUTPUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
