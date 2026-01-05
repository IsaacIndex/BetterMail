# Concurrency Notes

## Architecture
- **NSAppleScriptRunner (actor)**: Compiles and executes AppleScript off the main thread to avoid UI stalls during Mail fetch.
- **SidebarBackgroundWorker (actor, single instance per VM)**: Serializes refresh, rethread, subject gathering, and summary generation off the main actor. Main-actor hops are only for applying UI state (`roots`, `unreadTotal`, summaries, `isRefreshing`, status timestamps).
- **ThreadSidebarViewModel (@MainActor)**: Owns UI state. Starts tasks that delegate heavy work to the worker and only applies results on the main actor.

## Flows (visual)
- Sequence diagram with off-main notes: `openspec/changes/refactor-refresh-concurrency/refresh-flow.mmd`
  - Init: cached load → worker rethread → summary on worker → UI apply.
  - Refresh: worker fetches via AppleScript runner → store upsert → worker rethread → worker summaries → UI apply and clear `isRefreshing`.

## Non-blocking guarantees
- AppleScript fetches, Core Data upserts, JWZ thread build, subject extraction, and summary generation all run on the worker actor (not on `@MainActor`).
- UI thread only performs lightweight state updates; `isRefreshing` is cleared on the main actor after refresh completes or fails.
