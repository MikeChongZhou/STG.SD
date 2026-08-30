#!/usr/bin/env python3
"""Build the bundled STG weekly seed from OpenRouter rankings-daily responses."""

from __future__ import annotations

import argparse
import datetime as dt
import json
from collections import defaultdict
from pathlib import Path


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--output", action="append", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    args = arguments()
    daily: list[dict[str, str]] = []
    as_of = ""
    for path in args.inputs:
        document = json.loads(path.read_text(encoding="utf-8"))
        if document.get("error"):
            raise SystemExit(f"OpenRouter response contains an error: {document['error']}")
        daily.extend(document["data"])
        as_of = max(as_of, document.get("meta", {}).get("as_of", ""))

    daily.sort(key=lambda row: (row["date"], row["model_permaslug"]))
    first = dt.date.fromisoformat(daily[0]["date"])
    last_available = dt.date.fromisoformat(daily[-1]["date"])
    completed_end = last_available - dt.timedelta(days=(last_available.weekday() + 1) % 7)

    available_dates = {row["date"] for row in daily}
    missing_dates: list[str] = []
    cursor = first
    while cursor <= last_available:
        if cursor.isoformat() not in available_dates:
            missing_dates.append(cursor.isoformat())
        cursor += dt.timedelta(days=1)

    totals: dict[tuple[dt.date, dt.date], dict[str, int]] = defaultdict(lambda: defaultdict(int))
    for row in daily:
        day = dt.date.fromisoformat(row["date"])
        model = row["model_permaslug"]
        if day > completed_end or model == "other":
            continue
        monday = day - dt.timedelta(days=day.weekday())
        week_start = max(first, monday)
        week_end = min(completed_end, monday + dt.timedelta(days=6))
        totals[(week_start, week_end)][model] += int(row["total_tokens"])

    rows: list[dict[str, object]] = []
    for (week_start, week_end), models in sorted(totals.items()):
        ranked = sorted(models.items(), key=lambda item: (-item[1], item[0]))
        for rank, (model, total_tokens) in enumerate(ranked, 1):
            rows.append({
                "s": week_start.isoformat(),
                "e": week_end.isoformat(),
                "r": rank,
                "m": model,
                "t": total_tokens,
            })

    seed = {
        "schema": 1,
        "source": "OpenRouter /api/v1/datasets/rankings-daily",
        "citation": f"Source: OpenRouter (openrouter.ai/rankings), as of {as_of}.",
        "as_of": as_of,
        "start_date": first.isoformat(),
        "end_date": completed_end.isoformat(),
        "missing_dates": missing_dates,
        "token_breakdown_available": False,
        "rows": rows,
    }
    encoded = json.dumps(seed, ensure_ascii=False, separators=(",", ":")) + "\n"
    for output in args.output:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(encoded, encoding="utf-8")
    print(
        f"wrote {len(rows)} model-week rows across {len(totals)} weeks; "
        f"coverage={first}..{completed_end}; missing_dates={missing_dates}"
    )


if __name__ == "__main__":
    main()
