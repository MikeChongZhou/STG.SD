# Screen Time Guardian

Screen Time Guardian (STG) 1.1.6 is a native, local-first screen-time reminder app for macOS, Windows, iOS/iPadOS, and Android.

This repository is a clean implementation of [`stg.系统设计.md`](./stg.系统设计.md). It does not depend on an earlier STG/ScreenGuardian codebase.

## Repository layout

- `shared/` — normative JSON contract and cross-platform test vectors.
- `apple/STGCore/` — Swift core shared by the new macOS and iOS targets.
- `macos/` — native AppKit/SwiftUI menu-bar app.
- `ios/` — native SwiftUI app plus DeviceActivity monitor extension.
- `android/` — native Kotlin application and foreground usage service.
- `windows/` — .NET 8 WPF tray application.

## Data model

Each device owns its UTC minute bitmaps. One row represents a UTC day and contains exactly 1,440 bits (180 bytes). Reports rebuild local calendar days in the configured IANA report timezone. The `alldevices` bitmap is derived by bitwise union and can always be rebuilt.

Cloud synchronization uses ordinary JSON files in a user-authorized private-cloud folder. STG does not apply a sync code or application-level encryption. Provider access tokens and security-scoped bookmarks must stay in platform secure storage.

OpenRouter tracking uses public ranking, activity, and effective-pricing APIs. No OpenRouter account or API key is required. Prices are observed effective weighted prices that include cache/provider discounts; displayed revenue is an estimate, not OpenRouter financial reporting.

## Build quick start

```sh
bash scripts/test_apple_core.sh
bash scripts/build_macos.sh
bash scripts/build_ios.sh
bash scripts/build_android.sh
bash scripts/build_windows.sh
```

The iOS device target requires an Apple team, App Group, iCloud container, and approved Family Controls capability. Windows builds are framework-dependent and require the .NET 8 Desktop Runtime on the target computer.
