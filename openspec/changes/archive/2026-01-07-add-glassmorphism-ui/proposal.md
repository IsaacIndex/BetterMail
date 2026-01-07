# Change: Add glassmorphism styling across the app UI

## Why
The app currently uses default macOS list styling, which feels dated. A consistent glassmorphism treatment will modernize the look while keeping content readable.

## What Changes
- Introduce a glassmorphism visual style for the main window background, header, list rows, and summary cards.
- Add shared styling utilities/modifiers to keep the effect consistent and maintainable.
- Ensure accessibility preferences (Reduce Transparency) keep text legible with a solid fallback.

## Impact
- Affected specs: new `ui-visual-style` capability
- Affected code: `BetterMail/ContentView.swift`, `BetterMail/Sources/UI/ThreadListView.swift`, `BetterMail/Sources/UI/MessageRowView.swift`, plus new UI styling helpers under `BetterMail/Sources/UI/`
