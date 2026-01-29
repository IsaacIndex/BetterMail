# Change: Improve Open in Mail reliability with fallback search

## Why
Direct `message://` opens sometimes fail with `MCMailErrorDomain` (e.g., error 1030), leaving users without a way to view the selected message from the inspector.

## What Changes
- Normalize and harden the "Open in Mail" path so message URLs succeed more often and surface user-facing status on failure.
- Add a fallback flow that searches Mail by Message-ID and lets the user jump to or view the matching message when direct open fails.
- Provide guidance and copy actions when no match is found so users can still locate the message manually.

## Impact
- Affected specs: `thread-canvas`
- Affected code: `MailControl`, `ThreadCanvasViewModel`, `ThreadInspectorView` (or adjacent inspector UI)
