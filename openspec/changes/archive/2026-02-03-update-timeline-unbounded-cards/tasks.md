## 1. Implementation
- [x] 1.1 Review current timeline entry layout and data pipeline (summary text, tags) to map constraints.
- [x] 1.2 Update timeline row structure to `(dot) time  [AI tags]  summary text`, allowing multi-line summary wrapping and responsive spacing.
- [x] 1.3 Remove sender line from timeline entries and adjust text scaling/weights for readability on glass surfaces.
- [x] 1.4 Ensure dynamic heights and vertical spacing prevent entry overlap at all zoom/readability modes.
- [x] 1.5 Refresh accessibility labels/hit areas for the new layout.
- [x] 1.6 Add/adjust view snapshot or layout tests covering long summaries, many tags, and selection states.
- [x] 1.7 Run `openspec validate update-timeline-unbounded-cards --strict`.
