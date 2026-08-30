# Revised Goal Scope — 2026-08-30

Scope record version: `visual-email-organizer-revised-goal-scope-v1`

This note records owner-approved execution exclusions for the current goal. It
does not rewrite the frozen `visual-email-organizer-v1` acceptance protocol and
does not convert missing evidence into a pass.

## Owner-approved exclusions

- OpenSpec task 7.7 is excluded in full. No warm/cold organization timing or
  post-commit/post-relaunch retrieval trials will be run for this goal.
- The actual VoiceOver session named in OpenSpec task 8.5 is excluded. No
  VoiceOver operation is claimed.

| Goal item | Revised status | Original v1 status |
| --- | --- | --- |
| Task 7.7 human timing and retrieval | Excluded by owner | Pending / unmeasured |
| Task 8.5 actual VoiceOver session | Excluded by owner | Pending / unobserved |
| Task 8.5 authorized disposable-route Mail mutation | Completed | Observed / covered |

## Final non-human checkpoint

- The signed deterministic suite executed 720 tests with one intentional skip
  and zero failures.
- The required simulator reset and guarded clean build/install completed for
  the current source. The installed app and Mail extension independently pass
  deep strict verification and trusted code-signing-chain validation, use CMS
  rather than ad-hoc signatures, retain their repository bundle identifiers,
  report `TeamIdentifier=TN3L2WBKR5`, and use certificate SHA-1
  `59D9099E689B4FCF247C0E2C021C3B62E80AE4B2`.
- Two normal relaunches of the exact final installed bundle settled without a
  Keychain/SecurityAgent sheet or `com.bettermail.graph-spatial` prompt.
- One exactly disclosed, user-authorized message was moved through Snip and
  restored immediately through source-scoped Organization History. BetterMail
  recorded both completed actions, the conversation returned to Unorganized,
  and a read-only Apple Mail inspection confirmed the restored message in its
  original source mailbox. The durable evidence is aggregate-only and contains
  no mail content, account, route, or raw identifier.

## Still required

- The non-excluded implementation, deterministic, build, signing, install,
  installed-interaction, accessibility-descriptor, documentation, and live Mail
  checks are complete.
- Only the closing source observation remains: fetch origin immediately before
  success is concluded.

## Evidence interpretation

The frozen acceptance-status artifact remains `insufficient-evidence`: its
timed-human counts stay at zero, and its VoiceOver item remains unobserved. Unit
tests, agent-assisted interaction, deterministic timing, and accessibility-tree
inspection must not be promoted into human or VoiceOver evidence.

The revised goal may be reported complete only after all still-required work is
proven. That conclusion must explicitly identify task 7.7 and the VoiceOver
portion of task 8.5 as scope exclusions, not successful acceptance gates.
