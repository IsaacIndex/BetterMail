# Native SwiftUI Component Audit

Audit baseline: `origin/main` at `1e3e4b3` (2026-08-23).

## Goal and decision rule

This audit covers every declared app UI type in `BetterMail`, the two MailKit view-controller boundaries, and the active graph renderer. Prefer stock SwiftUI scenes, containers, controls, presentation APIs, focus behavior, and accessibility semantics whenever they preserve the interaction contract. Keep custom views when they express BetterMail-specific information rather than recreating a stock control. Keep AppKit only where a concrete SwiftUI capability gap remains.

## App shell and shared surfaces

| Component | Decision | Notes |
| --- | --- | --- |
| `BetterMailApp` | Keep native | Already uses `WindowGroup`, scene commands, `MenuBarExtra`, and `Settings`. |
| `ContentView` | Keep native | `NavigationSplitView` with explicit sidebar selection is the correct desktop root. |
| `MailboxSidebarView` | Native selection adopted | `List(selection:)` and `.sidebar` own selection highlight, keyboard navigation, and selected-state accessibility. The custom drag indicator remains because it represents sibling reordering. |
| `ThreadListView` | Mixed | Native segmented `Picker` and `ControlGroup` replace hand-built mode and zoom controls. The layered canvas/nav/action composition remains because it controls canvas insets and non-reflowing overlays. |
| `BackfillConfirmationSheet` | Keep native | Already uses `DatePicker`, buttons, and default/cancel keyboard actions. |
| `MailboxFolderMoveSheet` | Native list adopted | The destination chooser uses `List(selection:)` and `ContentUnavailableView`; the domain workflow and account/mode controls remain. |
| `AutoRefreshSettingsView` | Keep native | Already a grouped `Form` built from `Section`, `Picker`, `Toggle`, `LabeledContent`, `Stepper`, `TextEditor`, `DatePicker`, `ProgressView`, and `alert`. |
| `DayCoverageCalendarView` | Keep custom SwiftUI | The month grid decorates every day with unknown/fetching/partial/verified/failed state. `DatePicker` cannot express those cells. |
| `DayFetchConfirmationSheet` | Native form adopted | Uses form sections and standard cancellation/confirmation placement while retaining the rich preflight details. |
| `ProcessingActivityMenuContent` / `ProcessingActivityRow` | Native collection adopted | The retained activity timeline uses a bounded native collection; row content remains domain-specific. |
| `ProcessingActivityShelf` | Keep custom behavior | SwiftUI has no system nonmodal toast. The four-second, pointer-transparent shelf remains, with system glass and a reduce-transparency fallback. |
| `ToastOverlay` | Keep custom SwiftUI | SwiftUI has no native transient toast presentation. Its material surface already uses a system material. |
| `GlassBackground` / `GlassWindowBackground` | Keep as shared surface adapters | They centralize system glass/material and the accessibility reduce-transparency fallback; they are not replacement controls. Remove them from a surface when a native container owns that surface. |
| `GlobalMinimapOverlay` | Dormant | The call site is disabled. Do not expand it until viewport alignment is re-enabled and tested. |
| `FocusedValues` | Keep native | Correct scene-command routing for the active canvas and display settings. |

## Mail, action, and inspector components

| Component | Decision | Notes |
| --- | --- | --- |
| `ActionItemsView` | Native collection adopted | `List(selection:)`, checkbox `Toggle`, and `ContentUnavailableView` replace gesture selection, a drawn checkbox, and a hand-built empty state. |
| `ActionItemRow` | Keep domain row | Sender/date/tag composition is app-specific; selection and completion semantics come from native controls. |
| `ThreadSummaryDisclosureView` | Native disclosure adopted | `DisclosureGroup` owns expanded/collapsed semantics. Regenerate remains a separate button so it cannot toggle disclosure. |
| `ThreadInspectorView` | Keep domain content | Message title, recipients, MIME-derived content, open-in-Mail state, and copy feedback are app-specific. `LabeledContent`, `GroupBox`, and semantic foreground styles are incremental cleanup candidates. |
| `InspectorAddressField` / `InspectorAddressRow` | Keep domain content | Recipient parsing, collapsed limits, selectable addresses, and copy actions do not map to one stock field. A `DisclosureGroup` can eventually own overflow. |
| `InspectorEmailContent` | Keep domain content | Multiline selectable mail content and copy feedback are specialized. |
| `InspectorField` | Candidate | A simple label/value instance can become `LabeledContent`. |
| `InspectorCopyButtonStyle` | Candidate | Prefer standard mini buttons or a `ControlGroup` when visual parity is accepted. |
| `ThreadFolderInspectorView` | Keep domain form | Folder color, Mail destination, debounced preview/save, summary, and minimap form one specialized inspector. Its field groups can incrementally move to `Form`/`Section`/`LabeledContent`. |
| `FolderMinimapSurface` | Keep custom `Canvas` | It renders normalized nodes, edges, time ticks, selection, and a viewport overlay; no stock control is equivalent. |

Native `.inspector(isPresented:)` was evaluated and intentionally not adopted in this pass. The current 320-point panel overlays the graph without changing its viewport. A native inspector reserves width and reflows the graph, so migration requires explicit product acceptance plus Timeline/Graph interaction QA. The same constraint applies to Action Items for consistency.

## Thread canvas components

| Component | Decision | Notes |
| --- | --- | --- |
| `ThreadCanvasView` / `ScrollViewportHost` | Keep custom SwiftUI layout | The two-dimensional, zoomable, virtualized day/folder/thread canvas is the product visualization, not a recreated stock list. |
| `ThreadCanvasDayBand` | Keep custom | Encodes time bands and pinned labels. |
| `FolderColumnBackground` / `FolderColumnHeader` | Keep custom | Encode nested BetterMail Group geometry, drag targets, pin/jump actions, and mailbox state. |
| `ThreadCanvasConnectorColumn` | Keep custom | Draws explicit thread and group relationships. |
| `ThreadTimelineCanvasNodeView` / `ThreadCanvasNodeView` | Keep custom | Node cards combine selection, tags, action-item state, drag, and graph/timeline geometry. |
| `ThreadTimelineTagChip` / `ThreadDragPreview` | Keep custom | Small domain visualizations rather than general controls. |
| `ScrollViewResolver` | Keep narrow AppKit bridge | It observes exact two-axis bounds, configures scroll elasticity, preserves horizontal position during vertical jumps, and performs clamped programmatic scrolling. Replacing it requires parity with `ScrollPosition`/`onScrollGeometryChange` under live jump, zoom, paging, and minimap tests. |

Support-only canvas types such as preference keys, render contexts, cache entries, geometry models, drag state, legend data, and `TextVisibility` do not render independent UI and therefore need no component substitution.

## Graph SwiftUI chrome

| Component | Decision | Notes |
| --- | --- | --- |
| `GraphCanvasView` | Keep custom composition | It layers the renderer, hover metadata, controls, contextual actions, instructions, legend, sheets, and toolbar. |
| `GraphToolbar` | Native control groups adopted | Stock `ControlGroup`, buttons/stateful buttons, focus rings, and control sizing replace hand-painted toolbar chrome while retaining its bottom-canvas placement. |
| `GraphSettingsSheet` / `GraphAutomationSettingsSection` | Native form adopted | `Form`, `Section`, `LabeledContent`, and standard controls replace custom scrolling setting cards. |
| `GraphAutomationQueueSheet` | Candidate | Convert card stacks to a native `List` with destination/status sections after keyboard and mutation-flow tests are added. |
| `GraphRestoreHistoryControl` / `GraphRestoreHistoryRow` | Candidate | Presentation is already native `Button` + `popover` + `alert`; the history body can become `List`/`Section` plus `ContentUnavailableView`. |
| `GraphSuggestionReviewSheet` | Mostly native | Already uses a sheet, `TextField`, checkbox `Toggle`, `alert`, progress, and buttons. Its member stack can become a native `List`/`Form`. |
| `SnipMoveSheet` | Mostly native | Already uses `List`, `Picker`, progress, empty state, and buttons. The local Escape event monitor stays until `onExitCommand` is proven while search owns focus. |
| `ObsidianGraphControls` | Mostly native | Inner steppers, toggles, sliders, buttons, and `DisclosureGroup`s are native. The floating panel is domain canvas chrome. |
| `GraphHoverCard` | Keep custom | It is pointer-positioned, pointer-transparent, and richer than a system help tag; an interactive popover would change semantics. |
| `GraphGroupingActionBar` | Keep custom placement | Its actions are already native buttons; the dashed suggestion state and bottom context are domain-specific. |
| `GraphLegend` and legend shapes | Keep custom | `DisclosureGroup` is already native and the custom glyphs explain graph-specific marks. |
| `GraphCanopyStatus` | Remove candidate | No production call site was found. |

## Active graph renderer and platform bridges

| Component | Decision | Notes |
| --- | --- | --- |
| `GraphRepresentable` | Keep narrow bridge | Synchronizes SwiftUI selection/settings with SpriteKit and explicitly tears down callbacks, actions, data, and the scene. |
| `GraphSKView` | Keep AppKit edge | Supplies first responder, mouse-move delivery, point-specific context menus, magnification, and wheel pan/zoom. |
| `ObsidianGraphScene` / `ObsidianGraphSceneNode` | Keep SpriteKit | Retained nodes, force integration, hit testing, camera transforms, hover, drag/drop, and active/settled frame rates are renderer responsibilities. |
| `ObsidianGraphForceSimulator` | Keep model | Deterministic graph physics, not UI chrome. |
| `GraphScene` / `GraphSceneNodes` / `GraphForceSimulator` | Legacy cleanup candidate | Compiled for regression coverage but not mounted by production. Retire only after preserving valuable tests. |
| `GraphAudio`, `GraphData`, `GraphSnipModels`, `GraphTopicRanker` | No UI decision | Support/model types. |

SwiftUI `SpriteView` does not expose the custom `SKView` event boundary used here. Replacing the adapter would remove a small bridge but still require reimplementing context-menu hit testing, trackpad gestures, responder behavior, teardown, and renderer lifecycle. A pure SwiftUI `Canvas` rewrite would also recreate the entire retained renderer and is not justified by the component-native goal.

## Mail extension boundary

| Component | Decision | Notes |
| --- | --- | --- |
| `ComposeSessionViewController` | Keep required MailKit boundary | `MEComposeSessionHandler` returns an `MEExtensionViewController`. Host a real SwiftUI view inside it only when the compose feature has product UI. |
| `MessageSecurityViewController` | Keep required MailKit boundary | `MEMessageSecurityHandler` requires the controller type. A future SwiftUI body still needs this narrow host. |

The existing controllers are placeholder shells. Translating placeholder XIB labels alone would not improve the product; future work should pass real session/signer data into hosted SwiftUI views and test inside Mail.app.

## Validation matrix

| Lane | Status | Evidence and remaining gate |
| --- | --- | --- |
| Static | Passed | All changed Swift files parse, `Localizable.strings` passes `plutil -lint`, `git diff --check` passes, and all 62 render-capable declarations have a recorded decision. |
| Automated | Focused pass | 55 graph, mailbox-navigation, action-item, inspector, day-fetch, display-setting, and activity tests pass. Three unrelated `ThreadCanvasLayoutTests` produce four assertions that reproduce unchanged in a detached `origin/main` worktree at `1e3e4b3`; they are baseline failures rather than regressions from this pass. |
| Build | Passed with local overrides | The clean macOS build succeeds with the installed generic SDK and command-line-only ad-hoc signing overrides; complete log: `/tmp/xcodebuild.log`. The log retains pre-existing concurrency warnings and none references a changed UI file. No project SDK or signing setting was changed. |
| Live main app | Partial pass | The freshly built app launches. Verified source-list click and arrow-key selection, per-segment accessibility IDs, Timeline-to-Graph transitions, native zoom controls, Action Items empty state, activity shelf, Graph toolbar, and the complete scrollable Graph settings form. No action-item data was available to exercise checkbox-versus-row selection, and the summary disclosure, mailbox move list, and day-fetch confirmation were not opened. |
| Pointer and trackpad | Pending | Canvas pan/zoom, exact folder jumps, node/group drag, context menus, graph pinch, and command-scroll zoom still need hands-on acceptance. |
| VoiceOver | Pending | The accessibility tree exposes the source-list rows, all segmented-picker items, native controls, and stable identifiers. A real VoiceOver pass is still required for active Snip/Archive announcement, summary disclosure state, action checkbox behavior, graph node enumeration/activation, and activity announcements. |
| Appearance and accessibility settings | Pending | Light mode, Reduce Motion, Reduce Transparency, and larger app text-scale combinations were not exercised live. |
| MailKit | Pending | Compose/security controller UI can only be accepted inside Mail.app, not from the main app build. |
| Installed/release bundle | Not performed | The temporary DerivedData build was launched directly. No Raycast/Dock bundle was overwritten, and distribution signing/notarization was not attempted. |
