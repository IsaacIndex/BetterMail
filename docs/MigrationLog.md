# Migration Log

This log tracks renamed or removed symbols and deprecated components.

## refactor-repo-health-docs

- Removed `MessageRowView` (legacy thread list row). Replacement: `ThreadCanvasView` with `ThreadInspectorView`.
- `MailAppleScriptClient` is now an actor to serialize AppleScript access. Call sites continue using `await`.
