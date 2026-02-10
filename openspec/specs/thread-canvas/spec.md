# thread-canvas Specification

## Purpose
TBD - created by archiving change add-thread-canvas-ui. Update Purpose after archive.
## Requirements
### Requirement: Thread Canvas Axes
The system SHALL render emails on a canvas where the vertical axis represents day buckets and the horizontal axis represents thread columns.

#### Scenario: Day and thread mapping
- **WHEN** the canvas is displayed
- **THEN** each email node is positioned in the day bucket matching its message date and in the column for its thread

### Requirement: Default Range and Column Order
The system SHALL default the canvas to the most recent 7 days, SHALL order thread columns by most recent activity, and SHALL allow the day range to expand in 7-day increments using cache-only paging when the user scrolls downward. Scroll detection SHALL be driven by GeometryReader updates of the canvas content frame so two-axis scrolling can still trigger paging. When threads belong to a folder, the system SHALL order the folder as a unit by the folder's most recent activity and SHALL keep member threads adjacent horizontally.

#### Scenario: Default range and ordering
- **WHEN** the canvas loads
- **THEN** day bands cover the last 7 days and thread columns are ordered by latest message date, with foldered threads ordered by their folder's latest date

#### Scenario: Folder adjacency
- **WHEN** multiple threads belong to the same folder
- **THEN** those threads are laid out in adjacent horizontal columns

#### Scenario: Cache-only paging
- **WHEN** the user scrolls near the end of the current day range
- **THEN** the canvas expands by the next 7-day block using cached messages only

#### Scenario: Two-axis scroll detection
- **WHEN** the user scrolls the canvas vertically or diagonally
- **THEN** GeometryReader content-frame updates drive the scroll position used for paging

### Requirement: Node Content and Selection
The system SHALL render each node with sender, subject, and time, and SHALL update the inspector panel when a node is selected. The inspector panel SHALL present a body preview trimmed to 10 lines with an ellipsis when the message body exceeds 10 lines, and SHALL provide an "Open in Mail" button to view the full message in Apple Mail. The "Open in Mail" control SHALL normalize the Message-ID before launching Mail and SHALL surface an inline failure state (e.g., when Mail returns `MCMailErrorDomain` error 1030) that offers a fallback search to locate the message.

#### Scenario: Selecting a node
- **WHEN** the user clicks a node
- **THEN** the node is highlighted and the inspector panel shows that message's details with a 10-line body preview and an "Open in Mail" button

#### Scenario: Large body preview
- **WHEN** the selected message body exceeds 10 lines
- **THEN** the inspector preview shows the first 10 lines followed by an ellipsis and does not render the full body

#### Scenario: Open in Mail failure surfaces fallback
- **WHEN** the user triggers "Open in Mail" and Mail returns an error instead of opening the URL
- **THEN** the inspector shows that the direct open failed and presents a fallback search action without requiring the user to reselect the node

### Requirement: Navigation and Zoom
The system SHALL support two-axis scrolling and zoom with clamped limits for readability, and SHALL apply three configurable zoom thresholds to control readability states of the canvas: (1) detailed state shows full node text and day labels, (2) compact state shows title-only nodes with ellipsis and month labels, and (3) minimal state hides node text/ellipsis and shows year labels. Thresholds SHALL be user-configurable via Settings and take effect without restarting the app.

#### Scenario: Navigating the canvas
- **WHEN** the user scrolls or zooms
- **THEN** the canvas pans on both axes and scales within defined minimum and maximum zoom levels

#### Scenario: Readability thresholds
- **GIVEN** three user-configurable zoom thresholds for detailed, compact, and minimal states
- **WHEN** the zoom crosses a threshold
- **THEN** the canvas transitions to the corresponding readability state (detailed → compact → minimal) updating node text visibility and day/month/year legend modes accordingly

#### Scenario: Settings-controlled thresholds
- **WHEN** the user updates zoom thresholds in Settings
- **THEN** subsequent canvas renders use the updated values without requiring an app restart

### Requirement: Thread Continuity Connectors
The system SHALL render vertical connector lanes between consecutive nodes in the same thread column. When a thread column represents a manual group that merges multiple JWZ sub-threads, the system SHALL render a separate connector lane for each JWZ sub-thread, with dynamic horizontal offsets based on layout metrics.

#### Scenario: Multi-day thread
- **WHEN** a thread has messages on multiple days
- **THEN** connector segments link the nodes in date order within that column

#### Scenario: Merged JWZ sub-threads
- **WHEN** a manual group contains messages from multiple JWZ thread IDs
- **THEN** each JWZ sub-thread renders its own connector lane with a distinct offset

#### Scenario: Grouping or ungrouping realigns connectors
- **WHEN** the user groups or ungroups messages
- **THEN** connector lanes are recalculated and offsets are realigned to the updated thread membership

### Requirement: Canvas Accessibility
The system SHALL expose nodes as accessibility elements and day bands as accessibility headers.

#### Scenario: VoiceOver navigation
- **WHEN** VoiceOver is enabled
- **THEN** users can navigate day headers and hear each node's sender, subject, and time

### Requirement: Manual Thread Grouping Controls
The system SHALL support multi-select with Cmd+click and SHALL present a bottom action bar when one or more nodes are selected, offering actions to group into a target thread, add to folder, or ungroup manual overrides.

#### Scenario: Multi-select action bar
- **WHEN** the user Cmd+clicks to select one or more nodes
- **THEN** a bottom action bar appears with "Group", "Add to Folder", and "Ungroup" actions, and the last clicked node is treated as the target thread

### Requirement: Thread Source Visualization
The system SHALL distinguish JWZ-derived thread connectors from manual override connectors using distinct colors, with JWZ connectors rendered as solid lines and manual override connectors rendered as dotted lines.

#### Scenario: Manual connector styling
- **WHEN** a connector represents a manual override relationship
- **THEN** it renders as a dotted line using the manual thread color while JWZ connectors remain solid

### Requirement: Visible-Range Backfill Action
The system SHALL expose a toolbar action when any visible day band has no cached messages, and SHALL backfill messages for only the currently visible day range on user request.

#### Scenario: Backfill button appears
- **WHEN** the visible viewport includes at least one day band with no cached messages
- **THEN** a toolbar backfill action is displayed

#### Scenario: Backfill fetch scope
- **WHEN** the user triggers the backfill action
- **THEN** the system fetches messages for only the visible day range and updates the cache before rethreading

### Requirement: Custom Thread Drag (Canvas)
The system SHALL provide a custom drag interaction for single-thread drags on the thread canvas using DragGesture (not system drag), rendering a floating preview that follows the pointer without the system lift animation.

#### Scenario: Drag to folder column
- **WHEN** the user starts dragging a thread node and drops it onto a folder column
- **THEN** that thread is moved into the target folder
- **AND** the custom preview follows the pointer for the duration of the drag

#### Scenario: Drag out of folder to canvas
- **WHEN** the user drags a thread node currently in a folder and drops it on empty canvas area
- **THEN** the thread is removed from that folder
- **AND** the preview dismisses cleanly at drop end

#### Scenario: Drag manually attached node
- **WHEN** the user drags a node that is manually attached to a thread
- **THEN** the custom drag uses the thread for that node and supports the same folder drop outcomes

#### Scenario: Drag cancel safety
- **WHEN** the user cancels the drag (e.g., Escape or leaving the window)
- **THEN** the custom preview disappears and no move/remove occurs

### Requirement: Folder Drop Target Highlight
The system SHALL visually highlight a folder column while a thread drag is inside that folder's drop zone so users can confirm the drop target before releasing, including a brief entry pulse animation.

#### Scenario: Highlight while hovering folder area
- **WHEN** the user drags a thread node into the colored background area of a folder column (including its extended header zone)
- **THEN** a distinct border appears on top of that folder's background for as long as the pointer remains inside, with a brief pulse animation on entry
- **AND** the highlight clears immediately when the pointer leaves or the drag cancels/ends elsewhere

#### Scenario: Single active highlight
- **WHEN** multiple folder columns are visible
- **THEN** only the folder whose drop frame currently contains the drag pointer shows the highlight

### Requirement: Folder Header Inspector Entry
The system SHALL treat clicking a folder header on the thread canvas as a selection that opens the folder details panel in the inspector region, replacing any thread inspector content.

#### Scenario: Folder click shows details panel
- **WHEN** the user clicks a folder header
- **THEN** the inspector region shows the folder details panel instead of a thread inspector
- **AND** the previously selected thread is deselected

### Requirement: Nested Folder Drag Targets
The system SHALL support dragging threads into or out of any folder depth on the canvas, treating each nested folder as its own drop target and updating membership accordingly.

#### Scenario: Drop into nested child
- **WHEN** the user drags a thread and drops it inside a child folder that sits within a parent folder
- **THEN** the thread moves into that child folder (not just the parent)
- **AND** the parent retains the child in its hierarchy

#### Scenario: Drag out of nested folder
- **WHEN** the user drags a thread out of a child folder and drops it on empty canvas
- **THEN** the thread is removed from that child folder while the hierarchy remains intact

#### Scenario: Nested folders as siblings and loose threads
- **WHEN** a parent folder contains multiple child folders and loose threads
- **THEN** drag/drop operations respect the exact hovered target: dropping on a child folder affects only that child, while dropping on the parent's open area affects the parent membership

### Requirement: Nested Folder Drop Highlighting
The system SHALL display a highlight with a brief entry pulse around the specific nested folder that is the active drop target, even when that folder is inside another folder's visual region.

#### Scenario: Pulse on nested target entry
- **WHEN** a drag enters the drop frame of a nested child folder
- **THEN** only that child's drop frame shows the pulsing highlight, and the parent highlight is suppressed

#### Scenario: Clear highlight on exit or other target
- **WHEN** the drag leaves the child folder's drop frame or enters a different folder
- **THEN** the previous highlight clears immediately and the new target (if any) pulses

### Requirement: Thread Canvas View Modes
The system SHALL provide a navigation bar toggle to switch between Default View and Timeline View, SHALL default to Default View on first launch, and SHALL persist the last chosen view mode between app launches using display settings. Both view modes SHALL use the same two-axis canvas renderer and data source so thread columns, manual group connectors, and folder backgrounds/adjacency are rendered identically, with Timeline View applying only styling/legend overlays (e.g., time labels or tags) on top of the shared canvas.

#### Scenario: Toggle between modes
- **WHEN** the user taps the view toggle in the navigation bar
- **THEN** the canvas switches between Default View and Timeline View without requiring a refresh

#### Scenario: Persisted view preference
- **WHEN** the user relaunches the app after selecting a view mode
- **THEN** the canvas starts in the previously selected view mode

#### Scenario: Timeline reuses canvas and honors grouping
- **WHEN** the user switches to Timeline View
- **THEN** manual thread group connectors, JWZ thread columns, and folder backgrounds/adjacency remain present as in Default View, with only timeline-specific overlays changing

### Requirement: Heuristic Mail Targeting
When direct Message-ID lookup fails, the system SHALL attempt AppleScript-based heuristics recommended in Apple Support thread 253933858: constrain search using cached mailbox and account hints when available, and otherwise search by subject + sender + received-date within Mail. The inspector SHALL surface which heuristic succeeded (Message-ID match vs. metadata heuristic) or that no match was found.

#### Scenario: Mailbox-scoped heuristic
- **WHEN** Message-ID lookup fails but mailbox or account hints exist for the selected message
- **THEN** the system searches that mailbox/account for a message matching the cached subject + sender + received date and opens the first match in Mail

#### Scenario: Global heuristic without mailbox hint
- **WHEN** Message-ID lookup fails and no mailbox hint is available
- **THEN** the system searches across Mail for the first message whose subject, sender, and received date match the cached metadata and opens it in Mail

#### Scenario: Status reflects heuristic outcome
- **WHEN** a heuristic succeeds or fails
- **THEN** the inspector status text indicates the path used (Message-ID match, heuristic match, or no match) and keeps copy actions available for manual search

### Requirement: Open in Mail Fallback Search
When direct Mail open fails, the system SHALL search Apple Mail for the selected message's Message-ID via AppleScript and SHALL present the best match (subject, sender, and received date) in the inspector with actions to open that message in Mail without relying on `message://`, copy the Message-ID, and copy the message URL. The search SHALL run asynchronously and expose a loading and completion state.

#### Scenario: Fallback search success shows result
- **WHEN** direct open fails and the fallback search finds a message with the same Message-ID
- **THEN** the inspector shows its subject, sender, and received date with an action to open that message in Mail
- **AND** copy actions for the Message-ID and message URL remain available

#### Scenario: Fallback search no match guidance
- **WHEN** the fallback search completes without a match
- **THEN** the inspector shows that no match was found
- **AND** the user can copy the Message-ID and message URL to search manually in Mail

### Requirement: Open in Mail Filtered Fallback
The system SHALL attempt to open the selected message in Apple Mail by normalized Message-ID first. If that attempt fails, the system SHALL run a single global filtered search using Apple Mail’s AppleScript query pattern `(every message whose subject contains <subject> and sender contains <sender> and date received is within the target day>)` modeled after `OpenInMail (with filter).scpt`, where the date window spans from the start of the message’s calendar day to the start of the next day. When a match is found, the system SHALL open it (or select it in the first message viewer) and activate Mail; when no match is found, it SHALL surface an inline failure state.

#### Scenario: Filtered fallback opens match
- **WHEN** the Message-ID open attempt fails and the filtered fallback runs
- **THEN** the system filters all messages (global scope) by subject substring, sender token substring, and received-date within the target day, opens the first match (or selects it in the viewer), and activates Mail

#### Scenario: Filtered fallback finds no match
- **WHEN** the filtered fallback runs and no message matches the subject, sender token, and day range
- **THEN** the inspector shows an inline failure status while leaving manual copy helpers available for the user to try opening in Mail manually

### Requirement: Open in Mail Copy Helpers Persistent
The system SHALL render copy controls for Message-ID, subject, and mailbox/account alongside the Open in Mail status, and these controls SHALL remain visible regardless of success, searching, or failure states so users can quickly copy targeting metadata.

#### Scenario: Copy helpers always available
- **WHEN** the Open in Mail flow is idle, searching, succeeds, or fails
- **THEN** the inspector still presents copy buttons for the selected message’s Message-ID, subject, and mailbox/account values

### Requirement: Folder Header Jump Actions
The system SHALL provide two icon-only action buttons in the footer row of each folder header block on the thread canvas: one to jump to the latest email node in that folder and one to jump to the first email node in that folder. Each button SHALL expose tooltip text on hover and SHALL be keyboard-focusable with accessible labels.

#### Scenario: Folder header actions are visible with tooltips
- **WHEN** a folder header is rendered on the canvas
- **THEN** the footer shows a latest-jump icon button and a first-jump icon button
- **AND** hovering each button shows tooltip text describing its action
- **AND** each button is exposed as an accessible control with a descriptive label

### Requirement: DataStore-Backed Jump Target Resolution
The system SHALL resolve jump targets for folder-header jump actions from DataStore-backed message bounds within the folder scope, rather than limiting targets to currently rendered day bands.

#### Scenario: Latest jump uses DataStore newest bound
- **GIVEN** a folder whose newest email is outside the currently rendered day range
- **WHEN** the user activates the latest-jump button
- **THEN** the system resolves the newest in-scope email node from DataStore-backed bounds
- **AND** the canvas navigates to that node once its day is renderable

#### Scenario: First jump uses DataStore oldest bound
- **GIVEN** a folder whose oldest email is outside the currently rendered day range
- **WHEN** the user activates the first-jump button
- **THEN** the system resolves the oldest in-scope email node from DataStore-backed bounds
- **AND** the canvas navigates to that node once its day is renderable

### Requirement: Responsive Range Expansion for Jump Actions
When a resolved jump target falls outside the rendered day range, the system SHALL expand day-window coverage incrementally and stop as soon as the target day is included, avoiding unbounded synchronous expansion that would stall interaction.

#### Scenario: Incremental expansion stops at target day
- **WHEN** a jump target day is older or newer than the currently rendered day window
- **THEN** day-window expansion proceeds in bounded increments toward the target day
- **AND** expansion stops immediately once the target day is included
- **AND** the system proceeds to scroll to the target node without requiring manual paging

#### Scenario: Jump controls avoid repeated heavy work while busy
- **WHEN** a jump action is already expanding coverage toward a target
- **THEN** additional activations for that folder are ignored or disabled until the active jump completes
- **AND** normal canvas interaction remains responsive during the in-progress jump

### Requirement: Inspector summary regenerate controls
The inspector SHALL show a "Regenerate" action beside the email summary disclosure and the folder summary field, and SHALL reflect running or unavailable states inline.

#### Scenario: Node summary regen control
- **WHEN** a thread node is selected and its summary appears in the inspector
- **THEN** a "Regenerate" control is shown next to the summary title that triggers summary regeneration, and the control shows a busy/disabled state while regeneration is in progress

#### Scenario: Folder summary regen control
- **WHEN** a folder is selected and its summary appears in the inspector
- **THEN** a "Regenerate" control is shown next to the folder summary label that triggers folder summary regeneration, and the control shows a busy/disabled state when regeneration is running or when Apple Intelligence is unavailable

### Requirement: Floating Date Rail
The system SHALL render a floating date rail pinned to the left edge of the thread canvas that keeps day/month/year labels visible while preserving full-width day band backgrounds.

#### Scenario: Rail pinned to viewport
- **WHEN** the user scrolls horizontally or vertically on the canvas
- **THEN** the date rail remains fixed on the left side of the viewport and its labels stay visible

#### Scenario: Rail aligned to day bands
- **GIVEN** day band backgrounds still span the canvas width
- **WHEN** the user scrolls or the visible day window pages
- **THEN** the date rail’s labels remain vertically aligned with the corresponding day band heights and positions

#### Scenario: Rail respects readability thresholds
- **GIVEN** detailed, compact, and minimal readability states
- **WHEN** the zoom crosses a threshold (day→month→year legend changes)
- **THEN** the date rail switches label granularity to the matching mode without desynchronizing from the canvas content

#### Scenario: Rail in both canvas modes
- **WHEN** the user switches between Default View and Timeline View
- **THEN** the floating date rail remains pinned and aligned with day bands in both modes

### Requirement: Timeline Rail Connector Alignment
The system SHALL render the Timeline View vertical rail so it visually meets each entry's dot at both the top and bottom with no visible gap, even when entries vary in height due to multi-line summaries or wrapped tags. The rail SHALL maintain consistent thickness and positioning relative to the dots across light and dark themes.

#### Scenario: Rail touches dot edges
- **WHEN** a timeline entry is rendered
- **THEN** the vertical rail reaches the dot at the top and bottom edges with no visible gap between the line and the dot

#### Scenario: Variable-height entries stay connected
- **WHEN** a timeline entry grows taller because of multi-line summaries or wrapped tags
- **THEN** the rail spans the full entry height and still meets the dot edges without offsets or breaks

### Requirement: Reliable Folder Boundary-Jump Navigation
The system SHALL make folder-header boundary jump actions ("Jump to latest email" and "Jump to first email") reliably land the viewport on the resolved boundary email node in the selected folder scope, including folders whose boundary node is initially outside the rendered day window.

#### Scenario: Latest jump reaches target outside initial day range
- **GIVEN** a folder whose latest email is older than the currently rendered day window
- **WHEN** the user activates "Jump to latest email"
- **THEN** the system expands day coverage as needed to include the target day
- **AND** scrolls the canvas to the latest email node anchor without requiring manual paging

#### Scenario: First jump reaches target outside initial day range
- **GIVEN** a folder whose first email is outside the currently rendered day window
- **WHEN** the user activates "Jump to first email"
- **THEN** the system expands day coverage as needed to include the target day
- **AND** scrolls the canvas to the first email node anchor without requiring manual paging

#### Scenario: Boundary jumps work for nested folders
- **GIVEN** a nested child folder with boundary email nodes
- **WHEN** the user activates either boundary jump from that child folder header
- **THEN** the system resolves the target boundary within that child folder scope
- **AND** scrolls to that node instead of a parent folder node

### Requirement: Responsive Boundary-Jump Expansion Strategy
For folder-header boundary jumps, the system SHALL use a bounded expansion strategy that avoids both hard coverage ceilings for long-history folders and unbounded synchronous UI stalls.

#### Scenario: Long-history folder remains reachable
- **GIVEN** a folder whose boundary target requires significantly more than the default rendered range
- **WHEN** the user activates a boundary jump action
- **THEN** expansion proceeds in bounded increments until the target day is reachable or a defined terminal cap is hit
- **AND** the UI remains responsive during expansion

#### Scenario: Terminal expansion cap is explicit
- **WHEN** a boundary-jump flow reaches its configured expansion cap before target renderability
- **THEN** the jump finishes in a defined failure state with diagnostic logging
- **AND** no indefinite expansion loop continues in the background

### Requirement: Deterministic Scroll Completion for Boundary-Jump
The system SHALL treat boundary-jump scrolling as a retriable completion step that waits for anchor readiness across layout updates and resolves to success or timeout deterministically.

#### Scenario: Anchor appears after rethread
- **GIVEN** the boundary target node becomes renderable only after one or more layout updates
- **WHEN** a boundary-jump flow emits a scroll request
- **THEN** the system retries scroll dispatch against subsequent layout updates until the anchor exists
- **AND** marks the jump complete only after successful scroll or timeout

#### Scenario: Exact anchor unavailable fallback
- **GIVEN** the selected boundary node cannot be rendered as an anchor after expansion
- **WHEN** the boundary-jump flow resolves a fallback
- **THEN** the system preserves selection on the resolved boundary node
- **AND** scrolls to the nearest renderable node for the requested boundary within the same folder scope

### Requirement: Timeline View Unbounded Entries
The system SHALL render Timeline View entries as a vertical sequence aligned to a timeline rail where each entry uses a left dot + time column followed by inline AI tag chips (when available) and a summary/subject body that may wrap to multiple lines; entry height SHALL expand to fit the summary instead of clipping or overlapping adjacent entries. Timeline entries SHALL omit the sender line and rely on summary/subject plus tags for context, while preserving the existing inspector selection behavior.

#### Scenario: Inline rail layout without clipping
- **WHEN** Timeline View is active
- **THEN** each message renders on a shared rail with a leading dot and time label, and the summary text appears to the right with available width, wrapping to additional lines as needed without horizontal clipping

#### Scenario: No overlap with dynamic heights
- **WHEN** a summary spans multiple lines or tags wrap
- **THEN** the entry's vertical size grows and spacing ensures adjacent entries do not overlap or collide, maintaining readable separation on the rail

#### Scenario: Sender hidden, summary-focused body
- **WHEN** a message is shown in Timeline View
- **THEN** the sender line is not displayed; the body uses the summary text when present, otherwise the subject, and remains selectable to open the inspector as before

#### Scenario: AI tag chips inline with time
- **WHEN** AI-generated tags or folder/title tags exist
- **THEN** they render as pill chips inline after the time label (wrapping to the next line if needed) before the summary body, preserving the `(dot) time  [tags]  summary` visual order

### Requirement: Timeline View Entry Presentation
The system SHALL render Timeline View as a single vertical sequence of individual message entries ordered by received time (newest first within the selected range), where each entry shows a time label, sender + subject summary, and one or more tag/title chips. The layout SHALL use the existing inspector selection model so selecting an entry opens the message inspector without leaving Timeline View. When message metadata lacks a concise title or tag, the system SHALL optionally invoke Apple Intelligence to generate a short title or tag set; when Apple Intelligence is unavailable, the entry SHALL fall back to subject-only content without blocking rendering.

#### Scenario: Chronological entries with time labels
- **WHEN** Timeline View is active
- **THEN** each message in the visible date range appears once in a vertical list ordered by received time (newest first) and shows its time label alongside the entry

#### Scenario: Entry content summary and tags
- **WHEN** a message is rendered in Timeline View
- **THEN** its entry shows sender, subject (or summary snippet), and tag/title chips (e.g., folder labels or generated tags) in a compact card style similar to the reference visual

#### Scenario: Selection opens inspector
- **WHEN** the user clicks a timeline entry
- **THEN** that message becomes the current selection and the existing inspector panel opens with its details without exiting Timeline View

#### Scenario: Apple Intelligence-assisted tags optional
- **WHEN** message metadata lacks a concise title or tags
- **THEN** the system may request Apple Intelligence to generate a short title or tag set
- **AND** if Apple Intelligence is unavailable or fails, the entry still renders using available metadata without delay

### Requirement: Timeline Interaction Responsiveness
The system SHALL keep Timeline View scrolling and zooming responsive for typical datasets (up to 200 visible timeline entries) by reusing cached layout and text measurements instead of recomputing work on every scroll delta, maintaining smooth visuals within a 16ms frame budget on supported hardware.

#### Scenario: Smooth scroll under typical load
- **WHEN** Timeline View shows up to 200 entries and the user scrolls vertically, horizontally, or diagonally
- **THEN** the interaction remains visually smooth without blank content, and layout is reused rather than rebuilt on each scroll tick

#### Scenario: Smooth zoom transitions
- **WHEN** the user pinches to zoom between readability thresholds
- **THEN** the canvas scales without stalls or dropped frames, using cached measurements where possible

#### Scenario: Cached layout reuse
- **WHEN** the scroll offset changes but zoom, view mode, day window, and node set remain unchanged
- **THEN** the system reuses cached node frames instead of recalculating layout, keeping main-thread work within the 16ms frame budget

