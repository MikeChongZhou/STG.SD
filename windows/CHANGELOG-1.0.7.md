# Windows 1.0.7

## Fixes after 1.0.6

- Enabled .NET Per-Monitor V2 DPI awareness and DPI autoscaling for every window.
- Replaced auto-sized theme buttons with measured, fixed minimum dimensions so labels and button surfaces are not vertically cropped.
- Increased Report and Tracking toolbar/status heights, enlarged Settings and reminder windows, and made Report bitmap cards resize with the available client width.
- Reworked OneDrive sign-in so the app starts polling Microsoft immediately while a dedicated authorization window remains visible. The window shows/copies the device code, can reopen the browser, displays progress, and closes automatically after credentials are stored.
- Changed Windows Credential Manager token serialization from UTF-16 to UTF-8, avoiding the doubled token blob size that could cause a completed browser login to fail when saved. Existing UTF-16 entries remain readable.
- Saves the OneDrive credential before the optional Microsoft profile lookup; a profile-read failure no longer discards a valid cloud authorization.
- Shows live synchronization/sign-in status directly in Settings.
- Added automatic meeting detection by reading Windows microphone and webcam capability-use state for packaged and traditional desktop applications.
- A reminder now uses meeting mode when either the manual switch is on or an application is actively using the microphone/camera. Effective meeting mode is silent and immediately closeable; normal reminders play the Windows alert sound.
- Added **Detect meeting now** and a readable detection result in Settings, plus detailed `[meeting]` diagnostic events.
