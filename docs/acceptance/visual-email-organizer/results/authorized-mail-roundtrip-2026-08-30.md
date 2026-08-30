# Authorized Apple Mail Round Trip — 2026-08-30

- Evidence type: `accessibility-audit`
- Installed artifact: `/Users/isaacibm/Applications/BetterMail.app`
- Status: pass
- User authorization: explicit action-time approval for the disclosed move and
  immediate restore
- Affected messages: 1
- Authorized move calls: 1
- Authorized restore calls: 1
- Unresolved or partial outcomes: 0

## Observed sequence

1. BetterMail displayed the exact account, source, destination, affected-message
   count, and conditional reversibility before enabling the action.
2. The user explicitly approved that disclosed one-message move and immediate
   restore.
3. The Snip allocation completed; the conversation left the Unorganized queue,
   and Organization History recorded a completed Mail-moving action affecting
   one message.
4. The source-scoped Restore action completed; BetterMail reported the thread
   restored, the conversation returned to Unorganized, and Organization History
   recorded a completed Apple Mail restoration affecting one message.
5. A read-only Apple Mail inspection independently opened the restored message
   and displayed it in its original source mailbox under its original account.

## Privacy boundary

This artifact records only action types, counts, coarse statuses, and the
installed application path. It contains no subject, sender, recipient, account
name, mailbox name or path, exact route, raw message/thread identifier, body,
snippet, credential, or authorization token.
