## 1. Implementation
- [ ] 1.1 Review current folder drop hit-testing and highlight layering in `ThreadCanvasView` to confirm why the border is hidden under nodes.
- [ ] 1.2 Render the drop-target border above the folder background (covering the drop frame, including the header extension) whenever `activeDropFolderID` is set, using the folder accent color, with a brief entry pulse animation that settles into a steady stroke.
- [ ] 1.3 Ensure drag end/cancel/hover-out clears the highlight state without flicker and does not change drop hit-testing semantics.
- [ ] 1.4 Manual verification: drag a thread into a folder, between folders, and out to canvas to confirm highlight behavior; verify pulse appears only on entry; run `xcodebuild -project BetterMail.xcodeproj -scheme BetterMail -configuration Debug -destination 'platform=macOS,arch=arm64' build`.
