## 1. Implementation
- [ ] 1.1 Move thread building off the main actor using a detached `.utility` task and hop back only to apply UI state, including the initial refresh invoked at startup.
- [ ] 1.2 Execute summary generation in a detached `.utility` task, updating summary state on the main actor.
- [ ] 1.3 Guarantee `isRefreshing` is reset on the main actor across success, failure, and early-return paths.
- [ ] 1.4 Validate build or targeted tests if feasible (`xcodebuild -scheme BetterMail -quiet build`).
