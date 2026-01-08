## 1. Implementation
- [ ] Deprecate `MessageRowView` with an explicit availability annotation and message.
- [ ] Rename `ThreadSidebarViewModel` file/type to `ThreadCanvasViewModel` and update references.
- [ ] Add summary state + expansion binding to the inspector and position the disclosure UI before the “From” field.
- [ ] Reuse the existing Apple Intelligence disclosure UI for the inspector, preserving progress/status behavior.
- [ ] Update or add localized strings for any new user-visible labels used in the inspector.

## 2. Validation
- [ ] `xcodebuild \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -configuration Debug \
  -destination 'platform=macOS' \
  build`
