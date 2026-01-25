# AGENTS Guide

Use this document to stay aligned with BetterMail's expectations when assisting through automation.

## Core Principles

1. **Stay in Scope**
   - Focus on Swift, SwiftUI, and app infrastructure that already exists in this repo.
   - Do not change signing data, entitlements, bundle identifiers, or minimum OS versions.
   - Avoid adding new third-party libraries without explicit approval.

2. **Ground Work in Official Documentation**
   - When you need API behavior, life-cycle details, or platform policy guidance, **start with the official Apple Developer Documentation** (developer.apple.com/documentation or developer.apple.com/design/human-interface-guidelines).
   - Prefer doc sets that match the deployment target (iOS/macOS). Document the specific Apple links you used when the reasoning depends on them.

3. **Coding Conventions**
   - Follow Swift API Design Guidelines: prefer `struct`, immutability, and clear access control.
   - No force unwraps or casts; use `guard` for early exits.
   - Keep formatting at 4-space indentation and one type per file unless tightly coupled.

4. **Architecture & Testing**
   - Honor the existing MVVM-ish structure; do not reorganize folders or targets.
   - When changing logic, add or update XCTest-based unit tests (no network calls—mock instead).
   - All user-facing strings must be localizable-ready.
   - Reference `TechDocs/index.md` for architecture and migration notes; keep it current during refactors.

5. **Accessibility & Performance**
   - Respect Dynamic Type, VoiceOver, and color contrast requirements.
   - Keep heavy work off the main actor unless UI-bound, and mark UI-facing tasks with `@MainActor`.
   - Avoid retain cycles; prefer value types for models and async/await for concurrency.

6. **Communication Expectations**
   - Summaries must explain *what* changed and *why*, calling out trade-offs and any Apple docs consulted.
   - Keep diffs minimal and review-friendly; never revert unrelated user changes.
   - If requirements seem ambiguous, ask before making structural changes.

## Prohibited Actions

- Never bypass Apple platform restrictions, private APIs, or App Store policies.
- Do not modify App Store metadata or in-app purchase configuration.
- Do not add Combine/Rx-style paradigms unless specifically requested.

By following this guide—and backing up decisions with official Apple resources—you'll keep BetterMail safe, reviewable, and aligned with platform expectations.
