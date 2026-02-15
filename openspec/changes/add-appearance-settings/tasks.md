## 1. Implementation
- [ ] 1.1 Add an appearance settings model with persisted mode values (`system`, `light`, `dark`) and safe fallback behavior for unknown stored values.
- [ ] 1.2 Inject appearance settings at app root and apply the selected mode as the effective color scheme for the main scene and settings scene.
- [ ] 1.3 Add a new Appearance section in Settings with localized labels and help text for selecting `System`, `Light`, or `Dark`.
- [ ] 1.4 Replace hard-coded dark color-scheme forcing in navigation and inspector surfaces with appearance-aware logic that respects the selected mode.
- [ ] 1.5 Update glass/background/foreground style tokens to preserve legibility and aesthetic parity in both light and dark appearances (including Reduce Transparency behavior).

## 2. Validation
- [ ] 2.1 Add or update unit tests for appearance mode persistence/default mapping and fallback behavior. (Depends on 1.1)
- [ ] 2.2 Add or update UI-level checks for settings mode switching and immediate visual application without functional regressions. (Depends on 1.2, 1.3, 1.4, 1.5)
- [ ] 2.3 Build app and capture full output in `/tmp/xcodebuild.log` using project-required command sequence (`xcrun simctl erase all`, then `xcodebuild ... > /tmp/xcodebuild.log 2>&1`), triaging any compile errors. (Depends on 1.1-1.5)

## 3. Documentation
- [ ] 3.1 Update `/Users/isaacibm/GitHub/better-email-client/BetterMail/README.md` and any relevant docs/spec references to reflect appearance settings behavior and defaults after implementation.
