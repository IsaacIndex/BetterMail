## ADDED Requirements
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
