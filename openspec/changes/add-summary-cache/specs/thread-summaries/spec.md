## ADDED Requirements
### Requirement: Persist Apple Intelligence thread summaries
The system SHALL persist the latest Apple Intelligence summary per thread root with metadata including the input fingerprint, provider identifier, and generated-at timestamp.

#### Scenario: Save generated summary
- **WHEN** Apple Intelligence successfully generates a summary for a thread root
- **THEN** the summary text, generated-at timestamp, provider identifier, and computed fingerprint of the input subjects are stored in the local database keyed by that thread root ID.

#### Scenario: Remove orphaned caches
- **WHEN** a thread root no longer exists after rethreading or deletion
- **THEN** any cached summary for that thread root is removed from the database.

### Requirement: Reuse cached summaries when inputs match
The system SHALL reuse a cached summary when its fingerprint matches the current thread inputs and Apple Intelligence availability is unchanged.

#### Scenario: Warm launch reuse
- **WHEN** the app starts or rethreads and a cached summary exists whose fingerprint matches the current subjects for a thread root
- **THEN** the UI displays that summary immediately without invoking Apple Intelligence, marking the status as reused.

#### Scenario: Provider unavailable
- **WHEN** Apple Intelligence is unavailable but a cached summary exists
- **THEN** the UI shows the cached summary text with a status indicating the last updated time and that Apple Intelligence is unavailable, and no generation attempt occurs.

### Requirement: Invalidate and regenerate on thread change
The system SHALL invalidate cached summaries when the thread inputs change and regenerate them asynchronously when Apple Intelligence is available.

#### Scenario: Thread content changed
- **WHEN** a thread's subject list or membership changes (e.g., new messages fetched or manual grouping updates) and the cached fingerprint differs from the current one
- **THEN** the cached summary is marked stale, the UI reflects that summarization is in progress, and a new summary is generated and stored with the new fingerprint.
