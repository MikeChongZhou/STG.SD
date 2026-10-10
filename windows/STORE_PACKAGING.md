# Microsoft Store packaging

STG uses an MSIX packaging project at `ScreenTimeGuardian.Package/`. It wraps the existing WPF/WinForms desktop application as a full-trust MSIX package, so Store users install and update it through Microsoft Store and can remove it from Windows Settings.

## One-time Partner Center setup

1. Reserve **Screen Time Guardian** in Partner Center.
2. In Visual Studio on Windows, open `ScreenTimeGuardian.Package.wapproj` and choose **Publish → Associate App with the Store**. This writes the exact Partner Center identity name and publisher into `Package.appxmanifest`; do not invent them.
3. Commit the associated manifest. The Store re-signs submitted packages, so no distribution certificate is needed for the Store upload package.

## Build an upload package

On Windows with Visual Studio 2022's **.NET desktop development** and **Windows application development** workloads installed:

```powershell
./scripts/build_windows_store.ps1
```

The result is an `.msixupload` under `windows/ScreenTimeGuardian.Package/AppPackages/`; upload it to the reserved product in Partner Center. The project produces an x64/ARM64 bundle for Store delivery.

## Removal and user data

MSIX places active STG data in the package's `LocalState` folder. Windows removes that folder on a normal uninstall, including when the user uses **Settings → Apps → Installed apps** directly.

Windows does not allow an app to intercept that system uninstall and display its own prompt. STG therefore exposes **Remove app…** in the tray menu and Settings. It asks the customer whether to retain their personalized settings and screen-time data, then opens the app's Windows Settings page for the actual uninstall:

- **Keep** copies the data to a local restoration area and keeps stored cloud credentials. The next STG installation restores the copy once and deletes the restoration area.
- **Delete** removes package data, legacy ZIP-install data, restoration data, startup registration, and stored OneDrive/Google Drive credentials before opening Windows Settings.
- Direct removal from Windows Settings cannot be prompted by STG; it performs a clean MSIX removal of package-owned data.
