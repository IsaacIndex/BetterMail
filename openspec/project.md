# Project Context

## Purpose
BetterMail is a macOS SwiftUI companion for Apple Mail. It automates Mail.app via Apple Events/AppleScript, caches message metadata in Core Data, reconstructs conversation threads with the JWZ algorithm, and optionally summarizes what matters using Apple Intelligence when supported hardware is available. A bundled MailKit helper target demonstrates how future automation hooks (content blocking, compose customization, message actions) will integrate with the main app.

## Tech Stack
- Swift 5.10+ with SwiftUI for the macOS app shell (`BetterMail/BetterMailApp.swift`, `Sources/UI`)
- Core Data-backed persistence (`Sources/Storage/MessageStore.swift`) plus lightweight model structs
- AppleScript/Apple Events interop via `NSAppleScript` and `NSWorkspace` (`AppleScriptRunner.swift`, `MailAppleScriptClient.swift`)
- Swift Concurrency for async refresh, threading, and background work coordination
- Foundation Models / Apple Intelligence APIs (`Sources/Services/EmailSummaryProvider.swift`) when macOS 15.2+ is available
- MailKit extension target (`MailHelperExtension/`) built with AppKit nibs for UI surfaces
- XCTest for logic verification (threading focus today; more coverage expected as modules grow)

## Project Conventions

### Code Style
- Follow Swift API Design Guidelines, 4-space indentation, and one primary type per file (see `BetterMail/AGENTS.md`).
- Prefer `struct` + `let`, avoid force unwraps/casts, and lean on `guard` for early exits.
- Keep UI updates on the main actor (`@MainActor`) and annotate async entry points accordingly.
- User-visible strings must be ready for localization; avoid hard-coded English inside view files.

### Architecture Patterns
- MVVM-ish separation:
  - **Data ingestion** lives in `AppleScriptRunner.swift` and `Sources/DataSource/MailAppleScriptClient.swift`, which ensure Mail.app is running and execute scripts.
  - **Storage** is centralized in `Sources/Storage/MessageStore.swift`, keeping Core Data access off the main actor and exposing async helpers.
  - **Threading** is encapsulated in `Sources/Threading/JWZThreader.swift`, which converts fetched messages into conversation trees and annotates unread state.
  - **View models** (e.g., `Sources/ViewModels/ThreadCanvasViewModel.swift`) orchestrate refresh timers, selection, and summary fetches for SwiftUI views in `Sources/UI/`.
  - **Services** such as `EmailSummaryProvider` wrap optional Apple Intelligence/Foundation Models capabilities so the rest of the app can query summaries via protocol abstractions.
- The MailKit helper target mirrors this modularity: each handler class owns one MailKit surface (content blocker, compose, message action, security).
- Logging utilities live in `Sources/Support/Log.swift` to keep OSLog categories consistent.

### Testing Strategy (Ignore for now)
- Use XCTest targets under `BetterMail/Tests/` (currently focused on threading logic) to validate non-UI business rules.
- Favor deterministic unit tests; mock AppleScript/Mail responses instead of driving real Mail.app sessions.
- When adjusting data transforms (threading, summary providers, store migrations), add targeted regression tests before UI-level checks.
- Tests are run via Xcode (`⌘U`) or `xcodebuild test -scheme BetterMail -destination 'platform=macOS'`.

### Git Workflow
- Default branch is `main`; create short-lived feature branches for meaningful changes and keep diffs minimal.
- Significant capabilities, architecture shifts, or behavioral changes require an OpenSpec proposal under `openspec/changes/<change-id>/` before implementation.
- Reference the relevant spec(s) or proposal tasks in commit messages/PR descriptions, and ensure `openspec validate --strict` passes when specs are touched.

## Domain Context
- BetterMail depends on the system Apple Mail app. `AppleScriptRunner` ensures Mail.app is launched and authorized before issuing AppleScript queries through `MailAppleScriptClient`.
- Messages and threads are cached locally in `~/Library/Application Support/BetterMail/Messages.sqlite` so the SwiftUI sidebar (`ThreadListView`, `MessageRowView`) can render instantly while background refreshes run.
- The JWZ threading implementation normalizes message ids, populates intermediate containers, and surfaces per-thread counts that drive unread badges and ordering.
- Apple Intelligence summaries are optional: `EmailSummaryProvider` gracefully degrades with status messaging when Foundation Models are unavailable (macOS < 15.2 or unsupported hardware).
- The MailKit helper (`MailHelperExtension/`) currently ships demonstration handlers (content filtering, compose customization, security prompts) and will eventually evolve into automation tie-ins with the main app.

## Important Constraints
- Do not modify bundle identifiers, entitlements (`BetterMail.entitlements`), signing configs (`Config/*.xcconfig`), or minimum macOS targets without explicit approval.
- The app must request and maintain Automation permissions for `com.apple.mail`; failures here break ingestion and Mail control helpers.
- Long-running work (Mail fetch, Core Data operations, summary generation) should run off the main actor to keep the SwiftUI UI responsive.
- Apple Intelligence functionality only executes on macOS 15.2+ hardware that Apple enables—code paths must handle absence gracefully.
- No third-party dependencies are currently allowed; stick to Apple frameworks and internal modules unless stakeholders approve.

## External Dependencies
- **Apple Mail (com.apple.mail):** Primary data source accessed via AppleScript; user must grant Automation permission.
- **AppleScript / Apple Events runtime:** Used for message ingestion and Mail control commands.
- **Foundation Models / Apple Intelligence:** Provides optional system-language-model summaries (macOS 15.2+ requirement).
- **Apple Developer signing assets:** Team IDs and bundle IDs are injected through `Config/AppSigning.xcconfig` and `Config/ExtensionSigning.xcconfig`.
- **MailKit (Apple Mail Extensions):** Powers the helper target's handlers for compose, message actions, and content blocking.
