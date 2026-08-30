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
| Test-log export | Menu/About | Settings share sheet | Existing platform implementation | Existing platform implementation |
| Report copy/export | CSV with bitmap | Share sheet with bitmap | Share sheet | CSV |
| Tracking aligned table/sort/export | Eight sortable columns + CSV | Eight sortable columns + share-sheet CSV | Existing platform implementation | Eight sortable columns + CSV |

Authenticated social-blog collection is intentionally provider-authorized: a release must supply each provider's approved API/OAuth configuration or use a user-visible authenticated browser session. Credentials remain in platform secure storage and are not part of the sync contract.
