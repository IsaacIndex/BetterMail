# Change: Add Appearance Settings with Light Mode Support

## Why
BetterMail currently forces dark color scheme in key glass surfaces, which prevents the UI from matching macOS light appearance preferences. Users need light mode support that defaults to system appearance and remains configurable inside BetterMail settings.

## What Changes
- Add a persisted app appearance preference with `System` (default), `Light`, and `Dark` options.
- Add an Appearance section to the app settings window so users can choose their mode without changing system-wide preferences.
- Apply appearance preference at the app level so all primary surfaces (window background, navigation chrome, inspector panels, and canvas presentation) stay visually consistent.
- Update visual-style requirements so glassmorphism aesthetics and legibility are maintained in both light and dark appearances, including Reduce Transparency fallbacks.
- Preserve existing non-appearance behavior (threading, refresh, inspector actions, minimap interactions, and summary flows).

## Impact
- Affected specs:
  - `app-appearance` (new capability)
  - `ui-visual-style` (modified requirements for dual appearance support)
- Affected code (expected):
  - `/Users/isaacibm/GitHub/better-email-client/BetterMail/BetterMail/BetterMailApp.swift`
  - `/Users/isaacibm/GitHub/better-email-client/BetterMail/BetterMail/Sources/UI/AutoRefreshSettingsView.swift`
  - `/Users/isaacibm/GitHub/better-email-client/BetterMail/BetterMail/Sources/Settings/` (new appearance settings model)
  - `/Users/isaacibm/GitHub/better-email-client/BetterMail/BetterMail/Sources/UI/ThreadListView.swift`
  - `/Users/isaacibm/GitHub/better-email-client/BetterMail/BetterMail/Sources/UI/ThreadInspectorView.swift`
  - `/Users/isaacibm/GitHub/better-email-client/BetterMail/BetterMail/Sources/UI/ThreadFolderInspectorView.swift`
  - `/Users/isaacibm/GitHub/better-email-client/BetterMail/BetterMail/Sources/UI/Glassmorphism.swift`
  - `/Users/isaacibm/GitHub/better-email-client/BetterMail/BetterMail/Resources/Localizable.strings`
