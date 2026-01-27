## 1. Implementation
- [x] 1.1 Replace `message://` fallback with AppleScript-based targeting that prefers Message-ID, then mailbox/account hints, then subject+sender+date heuristics.
- [x] 1.2 Update inspector UI states to show targeting path (Message-ID, metadata heuristic, or no match) and keep copy actions (Message-ID, subject, mailbox path).
- [x] 1.3 Add telemetry/logging and tests for normalization, targeting branches, and no-match guidance across macOS versions.

## Manual Validation
- Trigger "Open in Mail" for messages that have Message-ID present and confirm direct AppleScript open succeeds without launching a URL.
- Trigger for messages lacking Message-ID or stored in other mailboxes; confirm heuristic search finds the message and opens it in Mail.
- Confirm inspector shows explicit status text for success path and for no-match, with copy actions still working.
- Verify no `message://` URLs are opened even when AppleScript targeting fails.
