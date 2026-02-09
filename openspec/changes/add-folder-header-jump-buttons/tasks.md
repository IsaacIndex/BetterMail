## 1. Implementation
- [ ] 1.1 Add two icon-only folder-header footer actions (jump latest, jump first) with tooltip text and accessibility labels.
- [ ] 1.2 Implement view-model commands to resolve per-folder first/latest target email nodes from DataStore-backed thread membership/message dates.
- [ ] 1.3 Implement bounded, incremental day-window expansion so jumps can reach unloaded target days without blocking UI.
- [ ] 1.4 Implement final scroll handoff to the resolved target node (or deterministic nearest-day fallback if the exact node is unavailable in layout).

## 2. Validation
- [ ] 2.1 Add/adjust unit tests for target resolution and expansion-stop conditions.
- [ ] 2.2 Manually validate both actions on folders with short and long histories, including cases where target days are outside the initial 7-day window.
- [ ] 2.3 Verify no regression in normal scroll paging behavior and no visible lag spikes during repeated jump actions.
