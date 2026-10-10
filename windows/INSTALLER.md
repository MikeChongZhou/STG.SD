# Windows installer and Microsoft Store distribution

STG is distributed as a signed Inno Setup EXE installer. Microsoft Store can list this standard Win32 installer: the customer finds and starts installation from Store, while the installer controls setup, upgrades, and removal.

## Build the installer

On Windows, install:

- .NET 8 SDK;
- Inno Setup 6;
- a code-signing certificate trusted by Windows, before production submission.

Provide `STG_GOOGLE_CLIENT_SECRET` as an environment variable or in Git-ignored `android/local.properties`, then run:

```powershell
./scripts/build_windows_installer.ps1
```

The self-contained x64 installer is written to `dist/ScreenTimeGuardian-Setup-<version>-x64.exe`. Sign that immutable EXE and submit its HTTPS download URL to the Store's Win32 product submission. Store certification requires the published installer to be an offline EXE or MSI, remain unchanged at its submitted URL, and be signed by a certificate that chains to the Microsoft Trusted Root Program.

## Uninstall data choice

The Inno Setup uninstaller appears when the customer removes STG from Windows Settings or runs the uninstaller directly. It asks, in English and Chinese, whether to retain personal settings and screen-time data.

- **Keep** retains `%AppData%\ScreenTimeGuardian` and stored cloud credentials. Reinstalling STG uses the data again. The startup entry is still removed because the app is no longer installed.
- **Delete** removes that folder, diagnostics, startup registration, and stored OneDrive/Google Drive credentials.

The application files are removed in both cases.
