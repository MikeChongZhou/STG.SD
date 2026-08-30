# Screen Time Guardian 1.1.6

- OpenRouter tracking now uses the public observed effective weighted input/output prices, including cache and provider discounts; revenue remains explicitly estimated.
- Weekly OpenRouter maintenance resumes after the latest stored completed week instead of using a fixed four-week detail window.
- Windows iCloud sync only uses the existing Apple App Library `sync` directory created by iOS/macOS and never creates a parallel ordinary folder.
- Windows daily reports use a compact bitmap-first layout with summary values in the title row and active intervals in each bitmap heading.
- iOS first-run setup is split into notification authorization, Persistent notification presentation, Screen Time authorization, individual app/domain selection, and optional completed private-cloud setup.
- Android supports Android 7.1.1 (API 25) with core-library desugaring and guarded notification/service APIs.
- All four applications report version 1.1.6.
