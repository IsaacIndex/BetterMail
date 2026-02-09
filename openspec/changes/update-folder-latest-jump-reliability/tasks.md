## 1. Implementation
- [ ] 1.1 Refactor boundary-jump orchestration (latest and first) into explicit phases (resolve target, ensure coverage, await renderability, scroll) with per-folder in-flight cancellation safety.
- [ ] 1.2 Replace fixed-step day-window expansion with adaptive bounded expansion that can cover long-history folders while avoiding unbounded synchronous work.
- [ ] 1.3 Add robust pending-scroll retry logic tied to layout/anchor readiness and an explicit timeout/fallback completion path.
- [ ] 1.4 Ensure repeated taps on either jump action while in flight are coalesced without freezing other canvas interactions.
- [ ] 1.5 Add structured log markers for resolution failure, expansion ceiling, anchor timeout, and successful scroll completion.

## 2. Validation
- [ ] 2.1 Add/extend unit tests for oldest/newest boundary resolution and expansion planning edge cases (short history, very long history, nested folder membership).
- [ ] 2.2 Manually validate both jump actions in folders with targets inside and outside the initial 7-day range, including nested folders.
- [ ] 2.3 Manually validate repeated jump taps do not introduce lag spikes or dropped final scrolls.
- [ ] 2.4 Build the app and capture the full build log at `/tmp/xcodebuild.log`.
