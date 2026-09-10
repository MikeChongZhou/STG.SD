# Build and setup

## macOS

Run `bash scripts/build_macos.sh`. The locally ad-hoc-signed bundle (`com.timbertrail.screentimeguardian.macos`) is written to `dist/Screen Time Guardian.app`. Ad-hoc builds intentionally omit restricted iCloud entitlements so launchd can open them; OneDrive and Google Drive remain available. A working iCloud release requires an Apple Development/Developer ID signature and provisioning profile that authorizes this bundle ID and `iCloud.com.timbertrail.screentimeguardian`; a release should also be notarized.

In Settings, choose the sync provider explicitly. Until then STG stays in single-device mode. Selecting a provider immediately begins account connection. iCloud uses the system Apple Account and the private ubiquity container. OneDrive uses Microsoft account device-code authorization in a system authentication window and Microsoft Graph App Folder. Google Drive uses OAuth/PKCE and its hidden `appDataFolder`. None of these paths uses a local folder picker.

Export diagnostics from Settings → Diagnostics → **Export Test Log…**. After a successful export, the active log is cleared.

## iOS/iPadOS

Run `bash scripts/build_ios.sh` for an unsigned generic-device compile. The bundle, including the AppIcon catalog, is copied to `dist/ios/Screen Time Guardian.app`. To sign and install it on a physical device:

1. Open `ios/STG.xcodeproj` after running XcodeGen.
2. The project is configured for the signing/profile TeamIdentifier `DA6DVPSL36` (Chong Zhou). The installed Apple Development certificate's display name includes `4RZCGADCGF`, but its code-signing TeamIdentifier and the existing profiles resolve to `DA6DVPSL36`.
3. Register `com.timbertrail.screentimeguardian.ios`, `com.timbertrail.screentimeguardian.ios.monitor`, `group.com.timbertrail.screentimeguardian`, and `iCloud.com.timbertrail.screentimeguardian` in the developer account.
4. Request and enable the Family Controls distribution entitlement for the app and DeviceActivity extension.
5. Enable notifications and select the apps/categories to monitor.

DeviceActivity callbacks reconstruct an estimated minute map. iOS reports display the estimate label.

Export diagnostics from Settings → Diagnostics → **Export test log**, then choose AirDrop, Files, Mail, or another share-sheet destination. After a successful share, the active log is cleared.

Both Apple targets use Microsoft Entra public-client application ID `a4ff927c-e45a-413e-b5c3-45b026719171` in `STGOneDriveClientID`. Enable public client/device-code flows and delegated scopes `offline_access`, `User.Read`, and `Files.ReadWrite.AppFolder`.

Google Drive requires a Google OAuth native client ID in each target's `STGGoogleClientID` and the Google Drive API enabled. STG derives Google's standard reversed-client-ID callback (`com.googleusercontent.apps.<client-number>:/oauth2redirect`) and requests only `openid email profile` and `drive.appdata`. Add the derived scheme to that target's URL types. Google's Desktop client type also requires its generated client secret. Keep it out of source control and export `STG_GOOGLE_CLIENT_SECRET` while building macOS or Windows; `build_macos.sh` injects it into the local app bundle, while `build_windows.sh` can also read it from the Git-ignored `android/local.properties` used by Android Studio. A Windows release build now stops instead of producing a Google-incompatible package when the value is absent. Installed native apps cannot keep this value confidential, but it must not be published in the source repository. The app stores user refresh/access tokens in Keychain or Windows Credential Manager; logs never include tokens or account addresses.

## Android

Install Android Studio/JDK 17 and run `bash scripts/build_android.sh`. The debug APK is written to `dist/android/ScreenTimeGuardian-1.1.8-debug.apk` and supports Android 9 (API 28) or later.

On first use grant notifications, overlay/full-screen reminder access, and Usage Access, then optionally complete private-cloud setup. Android does not use a folder picker: OneDrive uses Microsoft device-code authorization with `Files.ReadWrite.AppFolder` and Microsoft Graph App Folder; Google Drive uses OAuth/PKCE with the Google Desktop client registration and the hidden `appDataFolder`. The app verifies the account and completes an initial sync before saving the provider. Access and refresh tokens are encrypted with Android Keystore, and logs never include tokens or account addresses. For Google builds, provide `STG_GOOGLE_CLIENT_SECRET` either as an environment variable or as the same key in the Git-ignored `android/local.properties`; Gradle injects it into `BuildConfig` without writing it to tracked source files. The `local.properties` option is required when launching directly from Android Studio unless Android Studio itself was started with that environment variable.

## Windows

Install the .NET 8 SDK to build and run `bash scripts/build_windows.sh`. The framework-dependent output is written to `dist/windows/`. Target computers require the [.NET 8 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/8.0/runtime).

Choose iCloud Drive, OneDrive, or Google Drive in Settings. iCloud Drive uses the Apple Account already signed in through iCloud for Windows and automatically locates Screen Time Guardian's public iCloud document folder; it never opens an arbitrary folder picker. OneDrive starts Microsoft Graph App Folder authorization with `Files.ReadWrite.AppFolder`, while Google Drive uses OAuth/PKCE and the hidden `appDataFolder`. Access and refresh tokens are stored in Windows Credential Manager and are never written to logs or synchronized. The Microsoft public-client and Google Desktop OAuth registrations must permit the flows documented above.

For Windows iCloud sync, install iCloud for Windows, sign in with the same Apple Account used by the Apple devices, and enable iCloud Drive. The Apple builds publish only the Screen Time Guardian container's `Documents` scope, so Windows can find the app folder without gaining access to unrelated iCloud Drive files. The Windows app checks the registered iCloud sync root and the standard iCloud Drive location; Apple Account sign-in and sign-out remain controlled by iCloud for Windows.

The synchronized device record supplies the readable device name used by other
devices' reports instead of displaying the technical device ID. The Report screen includes an
all-device summary, the local-PC summary, the complete aggregate and per-device
minute bitmaps, a **Sync now** button, and CSV export.

Export diagnostics from Settings using **Export test log**. The log records lifecycle, minute samples, report totals, reminder decisions, provider/account state (without account addresses), synchronization counts, and OpenRouter refresh/export events.

Windows uses Per-Monitor V2 DPI scaling. Meeting mode is effective when the user enables it manually or when a reminder-time registry check finds an application actively using the microphone or camera. Automatic and manual meeting mode both silence the reminder and allow it to close immediately.

macOS checks whether the default microphone is actively running when a reminder is due. Android checks the system communication/call audio mode. On either platform, a detected meeting makes the reminder silent and immediately closeable; the manual meeting-mode override remains available.

## OpenRouter

Apple, Windows, and Android tracking read OpenRouter's public ranking, per-model daily activity, and effective-pricing endpoints directly; no account or API key is needed. They display input/output/total tokens, observed effective weighted input/output prices (including cache and provider discounts), and estimated revenue in an aligned table. Revenue is rounded to whole USD with thousands separators and is not OpenRouter financial reporting. Every column toggles descending/ascending sorting and the current rows can be exported as CSV. Tracking opens on Weekly Trends; its Top 10 is recalculated from the latest completed week for the selected metric. The weekly maintenance action incrementally backfills completed UTC Monday–Sunday periods. **Top 20 from date** fetches only when that view is opened or refreshed and runs from the selected date through the latest completed UTC day.

## External release dependencies

- Apple signing identities, App Group/iCloud containers, and approved Family Controls capability.
- Private-cloud OAuth client registrations and Apple iCloud signing/provisioning.
- Platform/API authorization for authenticated X, Truth Social, Xueqiu, or Weibo accounts. STG must not embed a developer-owned login or bypass platform access controls.
