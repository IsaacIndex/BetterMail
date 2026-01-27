# Change: Filtered fallback for Open in Mail

## Why
The current fallback iterates heuristically across scopes and can open the wrong message or return no match without leveraging Mail’s built-in filtering. We need a deterministic, filtered search aligned with the reference AppleScript and keep manual copy helpers visible so users can self-serve when automation misses.

## What Changes
- Keep primary `openMessageViaAppleScript` (Message-ID) path unchanged.
- Replace the heuristic fallback with a single global filtered query (subject, sender token, date range) modeled on `OpenInMail (with filter).scpt`.
- Keep the Message-ID / subject / mailbox copy buttons always visible in the inspector alongside status.

## Impact
- Affected specs: `thread-canvas` (Open in Mail behavior and UI affordances).
- Affected code: `MailControl` targeting logic, Open in Mail state handling, inspector status UI strings/placement.
