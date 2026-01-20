## 1. Implementation
- [x] Replace system drag start with DragGesture on nodes (single-thread only) and surface a drag state in the view.
- [x] Draw a custom drag preview that follows the pointer and fades/scales on pickup/drop.
- [x] Hit-test folder columns during drag and drop: move thread into folder on drop.
- [x] Detect drop onto empty canvas to remove folder membership.
- [x] Add guardrails: cancel on Escape or leaving window; clean up drag state on end.
- [x] Verify accessibility: ensure nodes remain accessible and drag affordance isn’t required for activation.
- [x] Add tests or a debug flag if feasible; otherwise manual check list.
- [x] Update spec delta and validate.
