## 1. Implementation
- [x] 1.1 Move thread building off the main actor using a detached `.utility` task and hop back only to apply UI state, including the initial refresh invoked at startup.
- [x] 1.2 Execute summary generation in a detached `.utility` task, updating summary state on the main actor.
- [x] 1.3 Guarantee `isRefreshing` is reset on the main actor across success, failure, and early-return paths.
- [x] 1.4 Validate build or targeted tests if feasible (`xcodebuild -scheme BetterMail -quiet build`). (Attempted; failed to write DerivedData under sandbox permissions.)
