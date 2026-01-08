# Change: Update thread canvas inspector preview for large bodies

## Why
Selecting a message with a large body can freeze the app. The inspector should show a trimmed preview and route users to Apple Mail for the full content.

## What Changes
- Trim inspector body previews to 10 lines with an ellipsis when longer.
- Add an "Open in Mail" button in the inspector for full message viewing.
- Avoid rendering full message bodies in the inspector on selection.

## Impact
- Affected specs: thread-canvas
- Affected code: Thread inspector UI/view model and any Mail-open action helpers
