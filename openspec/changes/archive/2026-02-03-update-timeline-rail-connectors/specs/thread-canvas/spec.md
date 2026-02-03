## ADDED Requirements
### Requirement: Timeline Rail Connector Alignment
The system SHALL render the Timeline View vertical rail so it visually meets each entry's dot at both the top and bottom with no visible gap, even when entries vary in height due to multi-line summaries or wrapped tags. The rail SHALL maintain consistent thickness and positioning relative to the dots across light and dark themes.

#### Scenario: Rail touches dot edges
- **WHEN** a timeline entry is rendered
- **THEN** the vertical rail reaches the dot at the top and bottom edges with no visible gap between the line and the dot

#### Scenario: Variable-height entries stay connected
- **WHEN** a timeline entry grows taller because of multi-line summaries or wrapped tags
- **THEN** the rail spans the full entry height and still meets the dot edges without offsets or breaks
