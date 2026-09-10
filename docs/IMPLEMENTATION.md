# Implementation map

The four targets share the contract in `shared/sync-contract.md` but do not share binaries.

| Capability | macOS | iOS/iPadOS | Android | Windows |
|---|---|---|---|---|
| UTC 1,440-bit bitmap + SQLite | Yes | Yes, App Group | Yes | Yes |
| Local-day/DST reconstruction | Yes | Yes | Yes | Yes |
| 20/40/daily reminders | Yes | DeviceActivity estimate | Yes | Yes |
| Meeting-mode silent reminders | Yes | Yes | Yes | Yes |
| Private-cloud account sync | iCloud/Graph/Google APIs | iCloud/Graph/Google APIs | SAF provider folder | iCloud for Windows/Graph/Google APIs |
| Device discovery on incremental sync | Yes | Yes | Yes | Yes |
| Settings upload without local secrets | Yes | Yes | Yes | Yes |
| OpenRouter public total-token Top 20 | No key | No key | Existing platform implementation | No key |
| Complete aggregate + per-device bitmap report | Yes | Yes | Existing platform implementation | Yes |
| Test-log export | Settings | Settings share sheet | Settings share sheet | Settings |
| Report copy/export | CSV with bitmap | Share sheet with bitmap | Share sheet | CSV |
| Tracking aligned table/sort/export | Eight sortable columns + CSV | Eight sortable columns + share-sheet CSV | Existing platform implementation | Eight sortable columns + CSV |

Blog collection is outside the current product scope and is not implemented on any platform.
