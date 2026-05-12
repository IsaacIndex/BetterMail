
# AGENTS.md

This document defines how AI coding agents (e.g. ChatGPT, Copilot, or other LLM-based tools) should interact with this Xcode project.

The goal is to keep changes **safe**, **reviewable**, and **aligned with iOS/macOS best practices**.

---

## 1. Scope of Agent Responsibilities

AI agents MAY:

- Propose or modify **Swift / SwiftUI / UIKit** source code
- Refactor for **readability, safety, and modern Swift style**
- Add **documentation comments** and inline explanations
- Suggest **unit tests** and **UI tests** (XCTest)
- Improve **accessibility**, **localization readiness**, and **performance**

AI agents MUST NOT:

- Change bundle identifiers, signing, provisioning profiles, or entitlements
- Modify App Store metadata or in-app purchase configuration
- Introduce private APIs or undocumented Apple frameworks
- Add third‑party dependencies without explicit approval
- Change minimum OS versions unless requested

---

## 2. Project Assumptions

Unless stated otherwise, assume:

- Language: **Swift (latest stable)**
- Architecture: **MVVM** (or existing architecture in project)
- UI Framework: **SwiftUI**, falling back to UIKit when required
- Concurrency: **Swift Concurrency (async/await)**
- Dependency management: **Swift Package Manager (SPM)**

Do NOT introduce Combine, RxSwift, or other paradigms unless explicitly requested.

---

## 3. Code Style & Conventions

Follow standard Apple conventions:

- Swift API Design Guidelines
- Prefer `struct` over `class` unless reference semantics are required
- Prefer immutability (`let`) over mutability (`var`)
- Avoid force unwraps (`!`) and force casts (`as!`)
- Use `guard` for early exits

Formatting:

- 4‑space indentation
- One type per file unless small related types are tightly coupled
- Explicit access control (`public`, `internal`, `private`)

---

## 4. File & Folder Rules

- Preserve existing folder structure
- New files must follow existing naming conventions
- Views, ViewModels, Models, and Services should be clearly separated
- Use `TechDocs/index.md` for architecture references and update TechDocs when refactors change structure or behavior.
- When logic is added, updated, or removed, update `README.md` or relevant `docs/` content to reflect the change.

Do NOT:

- Move files across targets
- Rename targets or schemes
- Reorganize folders unless explicitly requested

---

## 5. Testing Guidelines

When adding or modifying logic:

- Prefer **unit tests** over UI tests
- Tests should be deterministic and isolated
- Avoid network calls in tests (use mocks or stubs)

Test naming:

- `test_<Method>_<Condition>_<ExpectedResult>()`

---

## 6. Error Handling

- Prefer `throws` over optional error signaling
- Define domain‑specific error types
- Never silently swallow errors

If an error is user‑visible, clearly state how it should be surfaced in UI.

---

## 7. Performance & Safety

- Avoid unnecessary main‑thread work
- Be explicit about actor isolation (`@MainActor`)
- Avoid retain cycles in closures
- Prefer value types for models

---

## 8. Accessibility & Localization

All UI changes should consider:

- Dynamic Type
- VoiceOver labels and hints
- Color contrast
- Localizable strings (`Localizable.strings`)

Hard‑coded user‑visible strings should be avoided.

---

## 9. Review & Output Expectations

When responding, AI agents should:

- Clearly explain **what changed** and **why**
- Highlight any **trade‑offs or assumptions**
- Keep diffs minimal and focused
- Provide copy‑paste‑ready Swift code

If requirements are unclear, ask for clarification **before** making structural changes.

---

## 10. Out of Scope

AI agents should explicitly refuse to:

- Bypass Apple platform restrictions
- Assist with App Store policy evasion
- Generate code intended to exploit system vulnerabilities

# Review

At the last step of a change, if it involves logic change, always try to build the app and resolve any compilation errors. Capture the full build log in /tmp so agents (e.g., Codex) can read it.

```bash
# Clear cache first
xcrun simctl erase all
# Build and capture *all* output (stdout + stderr) so agents can review failures.
xcodebuild \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build \
  > /tmp/xcodebuild.log 2>&1

# Quick triage helpers
tail -n 200 /tmp/xcodebuild.log
grep -n "error:" /tmp/xcodebuild.log || true
grep -n "BUILD FAILED" /tmp/xcodebuild.log || echo "BUILD SUCCEEDED"
```

## Local Raycast / Spotlight Bundle

Raycast, Spotlight, and Dock launch the installed local bundle at:

```bash
/Users/isaacibm/Applications/BetterMail.app
```

The repo-local Xcode build product is not the same bundle. When a change should be visible from Raycast, Spotlight, or Dock, agents must rebuild and install the app bundle after the normal validation build succeeds:

```bash
xcodebuild \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= \
  clean build \
  > /tmp/xcodebuild.log 2>&1

ditto \
  DerivedData/Build/Products/Debug/BetterMail.app \
  /Users/isaacibm/Applications/BetterMail.app

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f /Users/isaacibm/Applications/BetterMail.app

mdimport /Users/isaacibm/Applications/BetterMail.app
```

Use the ad-hoc signing override above only for this local install path; do not commit signing, entitlement, bundle identifier, or provisioning changes for it. If an app icon or other bundle metadata changed and Raycast/Dock still shows stale data, reset caches with `qlmanage -r cache`, restart Raycast, and restart Dock only after verifying the installed bundle contains the expected resources.
