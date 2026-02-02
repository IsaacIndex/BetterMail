## MODIFIED Requirements
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
