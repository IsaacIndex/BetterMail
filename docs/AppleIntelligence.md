# Apple Intelligence

## Overview
BetterMail uses Apple's Foundation Models (Apple Intelligence) to generate email summaries when the on-device model is available on macOS 15.2+.

## Where It Is Used
- Inbox subject-line summary (digest) (deprecated; not wired into the UI)
- Single email summary (thread context aware)
- Folder summary (rollup of per-message summaries)

## Availability Behavior
The app checks `SystemLanguageModel.default.availability` and returns a capability response:
- Available: `"Apple Intelligence summary ready."` and the provider is enabled.
- Unavailable: provider is disabled and a user-facing message is returned.
- Not supported or not enabled: `"Apple Intelligence summaries require a compatible Mac with Apple Intelligence enabled."`

### Unavailable Reasons and Messages
- `deviceNotEligible`: `"This Mac does not support Apple Intelligence summaries."`
- `appleIntelligenceNotEnabled`: `"Enable Apple Intelligence in System Settings to see inbox summaries."`
- `modelNotReady`: `"Apple Intelligence is preparing the on-device model. Try again shortly."`

## Error Messaging
When generation fails, the user-facing error is:
`"Apple Intelligence could not summarize the inbox: <error description>"`

## Provider Metadata
- Provider ID: `foundation-models`
- Model: `SystemLanguageModel.default`

## Generation Defaults
All summary prompts use the same defaults unless overridden per prompt:
- `temperature`: `0.2`
- `maximumResponseTokens`: varies by prompt (see each prompt doc)
