## 1. Implementation
- [ ] 1.1 Audit current Open in Mail flow and confirm existing Message-ID AppleScript path stays primary.
- [ ] 1.2 Replace heuristic fallback with filtered global search AppleScript (subject, sender token, day-range) modeled after `OpenInMail (with filter).scpt`.
- [ ] 1.3 Wire new fallback into `MailControl.resolveTargetingPath` and update logs/status mapping.
- [ ] 1.4 Keep copy helpers (Message-ID, subject, mailbox/account) always visible in the inspector status area; adjust localization strings if needed.
- [ ] 1.5 Add/update tests for targeting resolution and UI state to cover filtered fallback and persistent copy controls.
- [ ] 1.6 Run `xcodebuild -project BetterMail.xcodeproj -scheme BetterMail -configuration Debug -destination 'platform=macOS,arch=arm64' build` and fix any errors.
