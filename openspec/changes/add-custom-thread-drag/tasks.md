## 1. Implementation
- [ ] Replace system drag start with DragGesture on nodes (single-thread only) and surface a drag state in the view.
- [ ] Draw a custom drag preview that follows the pointer and fades/scales on pickup/drop.
- [ ] Hit-test folder columns during drag and drop: move thread into folder on drop.
- [ ] Detect drop onto empty canvas to remove folder membership.
- [ ] Add guardrails: cancel on Escape or leaving window; clean up drag state on end.
- [ ] Verify accessibility: ensure nodes remain accessible and drag affordance isn’t required for activation.
- [ ] Add tests or a debug flag if feasible; otherwise manual check list.
- [ ] Update spec delta and validate.
