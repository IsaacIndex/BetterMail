## 1. Implementation
- [x] Deprecate `MessageRowView` with an explicit availability annotation and message.
- [x] Rename `ThreadSidebarViewModel` file/type to `ThreadCanvasViewModel` and update references.
- [x] Add summary state + expansion binding to the inspector and position the disclosure UI before the “From” field.
- [x] Reuse the existing Apple Intelligence disclosure UI for the inspector, preserving progress/status behavior.
- [x] Update or add localized strings for any new user-visible labels used in the inspector.
- [x] Align Liquid Glass layering so the inspector and nav float above the canvas, and offset canvas content to keep day bands visible.

## 2. Validation
- [x] `xcodebuild \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -configuration Debug \
  -destination 'platform=macOS' \
  build`
