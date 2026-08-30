# STG private-cloud contract

All timestamps are RFC 3339 UTC strings. All dates in bitmap filenames are Gregorian UTC dates in `yyyy-MM-dd` form. JSON text is UTF-8.

## Layout

```text
sync/
  <device-id>_setting.json
  <device-id>_bitmap_<yyyy-MM-dd>.json
history/
```

Every incremental sync lists `sync/`, derives device IDs from both filename forms, and reconciles the result with the local device table before downloading data. Each receiving device persists a separate latest-successfully-downloaded UTC date `x(i)` for every remote device `i`. It always downloads that device's current settings document and considers only bitmap documents whose UTC date is greater than or equal to `x(i)`. The boundary is inclusive so changes to the latest/current-day bitmap are not missed. A cursor advances only after a bitmap has been downloaded, validated, and imported successfully; a failure stops advancement for that remote device without blocking other devices.

Upload uses an independent cursor per private-cloud provider/destination. If the latest successfully uploaded UTC date is `Y`, a full incremental sync uploads only bitmap dates from `Y` through the current UTC date, including `Y`. The inclusive boundary allows the latest date to continue accumulating minutes. With no upload cursor, the client seeds the most recent 14 UTC dates. The upload cursor advances after each successful bitmap upload, and settings remain a current singleton document uploaded separately.

## Bitmap document

```json
{
  "device_id": "550e8400-e29b-41d4-a716-446655440000",
  "utc_date": "2026-08-22",
  "bitmap_base64": "180 decoded bytes",
  "updated_at": "2026-08-22T19:20:30Z",
  "reserved": {}
}
```

The decoded byte at `minute / 8` contains the minute bit `1 << (minute % 8)`. Minute 0 is `00:00Z...00:00:59Z`. Documents with an invalid date, a decoded length other than 180 bytes, or a filename/device mismatch are rejected and logged.

## Setting document

```json
{
  "device_id": "550e8400-e29b-41d4-a716-446655440000",
  "device_name": "Mike's Mac",
  "device_kind": "macos",
  "daily_plan_minutes": 600,
  "report_time_zone": "America/Detroit",
  "eye_close_countdown_minutes": 1,
  "posture_close_countdown_minutes": 2,
  "daily_close_countdown_minutes": 3,
  "launch_at_login": true,
  "meeting_mode": false,
  "updated_at": "2026-08-22T19:20:30Z",
  "reserved": {}
}
```

Settings from other devices are comparison candidates. They are never applied without explicit user confirmation.

## Ownership and merging

- A device uploads only files whose `device_id` is its own ID.
- A device never downloads its own bitmap as an authoritative replacement.
- Other-device bitmap documents replace the local cached row for the same `(device_id, utc_date)`.
- `alldevices` is not uploaded. It is rebuilt by OR-ing device rows.
- Quick sync handles the current UTC row and any adjacent row changed by an iOS catch-up window.
- Incremental upload uses its per-provider inclusive cursor; only the first sync seeds the local rolling 14-date window. Incremental download uses the per-remote-device inclusive cursor described above; the first sync imports every available remote bitmap.
