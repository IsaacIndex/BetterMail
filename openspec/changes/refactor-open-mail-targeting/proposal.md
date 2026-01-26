# Change: Revamp Open in Mail targeting without message:// dependence

## Why
"Open in Mail" remains flaky because it ultimately falls back to `message://` URLs, which frequently fail or open the wrong mailbox. The Apple Support thread (253933858) recommends selecting messages directly via AppleScript properties (message id, subject, sender, date) instead of URL schemes. We need to adopt that approach so opening a message from the inspector is reliable.

## What Changes
- Replace the `message://` fallback with an AppleScript-only targeting flow that first resolves by Message-ID, then narrows search by account/mailbox hints, and finally by subject+sender+date heuristics from the cached message metadata.
- Surface clearer status in the inspector: show which targeting path succeeded, and provide actionable guidance (copy Message-ID, subject, mailbox path) when no hit is found.
- Add regression coverage and logging around targeting outcomes so we can trace failures across macOS versions.

## Impact
- Affected specs: `thread-canvas`
- Affected code: `MailControl`, `ThreadInspectorView` (or equivalent inspector UI), `ThreadCanvasViewModel` (open action), AppleScript glue and tests
