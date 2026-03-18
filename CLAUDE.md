# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

BetterMail is a native macOS SwiftUI companion app for Apple Mail. It ingests inbox data via AppleScript, caches messages in Core Data, threads conversations using the JWZ algorithm, and renders them on an infinite canvas with draggable folder groups. Optional Apple Intelligence summaries are available on macOS 15.2+.

## Build Commands

```bash
# Build (output to /tmp for review)
xcodebuild \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build \
  > /tmp/xcodebuild.log 2>&1

# Triage build output
tail -n 200 /tmp/xcodebuild.log
grep -n "error:" /tmp/xcodebuild.log || true
grep -n "BUILD FAILED" /tmp/xcodebuild.log || echo "BUILD SUCCEEDED"

# Run all tests
xcodebuild test \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -destination 'platform=macOS'

# Run a single test class
xcodebuild test \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -destination 'platform=macOS' \
  -only-testing:BetterMailTests/ThreadCanvasLayoutTests
```

After any logic change, build and resolve all compilation errors before considering the task complete. Capture the full build log in `/tmp` so it can be reviewed.

## Signing Setup

Copy `Config/AppSigning.xcconfig.example` → `Config/AppSigning.xcconfig` and `Config/ExtensionSigning.xcconfig.example` → `Config/ExtensionSigning.xcconfig`, then fill in `DEVELOPMENT_TEAM_ID`, `BETTERMAIL_BUNDLE_ID`, and `MAIL_EXTENSION_BUNDLE_ID`.

## Architecture

### Data flow

```
Mail.app ──AppleScript──► MailAppleScriptClient
                                │
                          MessageStore (Core Data)
                                │
                          JWZThreader + ManualGroups overlay
                                │
                    ThreadCanvasViewModel (@MainActor)
                                │
                         ThreadCanvasView (SwiftUI infinite canvas)
```

### Key modules

| Module | Location | Responsibility |
|--------|----------|----------------|
| DataSource | `Sources/DataSource/` | AppleScript-based Mail.app ingestion via `MailAppleScriptClient` |
| Storage | `Sources/Storage/` | Core Data via `MessageStore.shared`; model built programmatically in `makeModel()` |
| Threading | `Sources/Threading/` | JWZ algorithm (`JWZThreader`); manual group overlays applied on top |
| Services | `Sources/Services/` | `BatchBackfillService`, `EmailSummaryProvider`, `SummaryRegenerationService` |
| ViewModels | `Sources/ViewModels/` | `ThreadCanvasViewModel` — the central orchestrator for refresh, state, and selection |
| UI | `Sources/UI/` | SwiftUI views; `ThreadCanvasView` renders the infinite canvas |
| Settings | `Sources/Settings/` | `@StateObject` UserDefaults-backed settings objects (AutoRefresh, Appearance, etc.) |

### Entry points

- **App entry:** `BetterMailApp.swift` (`@main`)
- **Root layout:** `ContentView.swift` — `NavigationSplitView` with `MailboxSidebarView` (left) and `ThreadListView` (right)
- **Canvas:** `ThreadListView.swift` composes `ThreadCanvasView`, inspector overlay, nav bar overlay, and selection action bar

### Concurrency model

- All UI state lives on `@MainActor` via `ThreadCanvasViewModel`
- Heavy work (AppleScript, Core Data, threading, summarization) runs off-main via background actors and `performBackgroundTask`
- Use `async/await` exclusively — do not introduce Combine or Rx-style paradigms

### Canvas rendering

The infinite canvas uses a 7-day block expansion on scroll with a quantized scroll offset for virtualization. `ThreadCanvasLayout.swift` computes the visible render window. Folder headers pin when out of range. Scroll detection goes through an `NSScrollView` observer.

### MailKit extension

`MailHelperExtension/` is a separate Xcode target containing `ContentBlocker`, `MessageActionHandler`, `ComposeSessionHandler`, and `MessageSecurityHandler`. Do not move files between this target and the main app.

## Constraints

- **Do not** change bundle identifiers, signing configs, entitlements, or minimum OS versions
- **Do not** add third-party dependencies without explicit approval
- **Do not** use private APIs or undocumented Apple frameworks
- **Do not** move files between targets or rename targets/schemes
- **Do not** introduce Combine or RxSwift

## Code Conventions

- Prefer `struct` over `class` unless reference semantics are needed
- Prefer `let` over `var`; avoid force unwraps (`!`) and force casts (`as!`)
- Use `guard` for early exits; explicit access control on all declarations
- 4-space indentation, 120-character line length (enforced by `.swift-format.json`)
- One type per file unless types are tightly coupled
- Test naming: `test_<Method>_<Condition>_<ExpectedResult>()`
- Tests must be deterministic and isolated — no network calls; use mocks/stubs

## Documentation

When changing logic, update `README.md` or the relevant file in `docs/` and `TechDocs/index.md` to reflect the change.
