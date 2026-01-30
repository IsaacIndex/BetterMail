## 1. Implementation
- [ ] 1.1 Audit the current Timeline View rail/dot layout to pinpoint the gap source (padding, line inset, or drawing bounds).
- [ ] 1.2 Update the rail/dot rendering so the connector line meets the dot edges at both top and bottom across variable row heights.
- [ ] 1.3 Verify visually in light/dark glass themes with multi-line summaries and tag wraps; capture before/after screenshot if possible.
- [ ] 1.4 Run `openspec validate update-timeline-rail-connectors --strict`.
