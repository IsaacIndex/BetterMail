## 1. Implementation
- [x] 1.1 Harden message URL construction and handle Mail open failures with user-facing status in the inspector.
- [x] 1.2 Implement fallback search by Message-ID (via AppleScript) that surfaces matching message details and actions to open or copy identifiers when direct open fails.
- [x] 1.3 Add logging/telemetry and regression coverage (unit or integration harness) for Message-ID normalization and fallback outcomes; document manual validation steps.

## Manual Validation
- Launch BetterMail, select a message, and click "Open in Mail" to confirm the status line reports success.
- Trigger a fallback search (e.g. select a message that is no longer in Mail) and confirm the inspector shows match or no-match guidance.
- When no match is found, use "Copy Message-ID" and "Copy Subject" to verify the clipboard contents update.
- When matches are shown, click "Open in Mail" on a match and confirm Mail opens the selected message.
