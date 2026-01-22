## 1. Implementation
- [x] 1.1 Add Core Data model support for persisted thread summaries (entity/attributes) with migration guard.
- [x] 1.2 Expose MessageStore APIs to fetch/upsert/delete cached summaries keyed by thread root and fingerprint.
- [x] 1.3 Update summary pipeline (ThreadCanvasViewModel + worker) to reuse cached summaries when fingerprints match and to invalidate/regenerate on thread changes.
- [x] 1.4 Surface cached status in UI state so inspector/list disclosure reflects whether summary is fresh or reused.
- [x] 1.5 Backfill/delete caches when threads are removed or rethreaded into different roots.

## 2. Testing / Validation
- [x] 2.1 Unit tests for MessageStore summary persistence and fingerprint invalidation behavior.
- [x] 2.2 View model tests (or integration harness) to confirm cached summaries bypass regeneration and refresh when threads change.
- [x] 2.3 `openspec validate add-summary-cache --strict`.
- [x] 2.4 `xcodebuild -project BetterMail.xcodeproj -scheme BetterMail -configuration Debug -destination 'platform=macOS,arch=arm64' build`.
