# Windows 1.0.6 — changes since the previous Windows package

## Private-cloud synchronization

- Replaced the mounted-folder picker with explicit **Off**, **OneDrive**, and **Google Drive** providers.
- OneDrive now uses Microsoft account device-code authorization and Microsoft Graph `approot` with the least-privilege `Files.ReadWrite.AppFolder` scope.
- Google Drive now uses the system browser, OAuth authorization code flow with PKCE and a random loopback callback, and the hidden `appDataFolder` scope.
- Access and refresh tokens are stored only in Windows Credential Manager. They are excluded from the database, logs, and synchronized settings.
- Added account status, reconnect, sign-out, launch sync, resume/unlock sync, tray **Sync now**, dashboard **Sync now**, and Report **Sync now**.
- Incremental sync checks cloud filenames to discover devices, synchronizes readable device names/settings, uploads the current plus 13 prior UTC bitmap days, and downloads other-device bitmaps.

## Screen-time and reminders

- Adopted the revised desktop 20-minute-block reminder state machine and persisted the last eye/posture timestamps and alternating reminder slot.
- Uses combined, deduplicated device time for daily-limit decisions and local time-zone reconstruction for daily reports.
- Added detailed diagnostic events for lifecycle, each active-minute sample, local/all-device totals, reminder decisions, sync state/counts, report refreshes, and tracking refresh/export.
- Added test-log export to the tray menu, Settings, and About.

## Report and OpenRouter tracking

- Report contains the all-device, this-PC, and plan summary; complete 1,440-minute aggregate and per-device bitmaps; readable device names; active intervals; and CSV export.
- OpenRouter uses public ranking data without an API key, with the previous completed Monday–Sunday week and current-month views.
- Tracking includes input/output/total tokens, input/output prices, whole-dollar revenue with grouping, strict toggled sorting on every column, and CSV export.

## Interface

- Reworked the dashboard into metric cards, plan progress, four prominent navigation actions, and a private-cloud status card.
- Reworked Settings into clearly separated Private Cloud, General, Reminders, and Diagnostics sections.
- Applied a consistent Segoe UI, light-card, teal-accent visual system to Dashboard, Settings, Report, Tracking, reminders, and About.
- Replaced the About message box with a readable multi-paragraph window containing privacy, usage, private-cloud, and open-source notices.
