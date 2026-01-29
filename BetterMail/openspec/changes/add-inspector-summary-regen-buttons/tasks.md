## 1. Implementation
- [ ] 1.1 Update thread inspector UI to show a regenerate control next to the thread summary disclosure.
- [ ] 1.2 Update folder inspector UI to show a regenerate control next to the folder summary field.
- [ ] 1.3 Wire inspector controls to trigger targeted summary regeneration in ThreadCanvasViewModel (node and folder paths), bypassing cached fingerprints.
- [ ] 1.4 Reflect in-progress/disabled states in the inspector while regeneration runs.

## 2. Validation
- [ ] 2.1 Run `openspec validate add-inspector-summary-regen-buttons --strict`.
- [ ] 2.2 Build app with `xcodebuild -project BetterMail.xcodeproj -scheme BetterMail -configuration Debug -destination 'platform=macOS,arch=arm64' build`.
