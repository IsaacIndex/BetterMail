# Change: Refactor repository and add tech docs

## Why
- The app evolved quickly; functions and variables across modules diverged from Swift conventions, making maintenance and onboarding harder.
- Deprecated or obsolete UI/components (e.g., legacy thread list) remain in-tree without a clear removal path.
- There is no consolidated technical documentation describing module boundaries, data flow, and MailKit helper responsibilities.

## What Changes
- Establish a repo-wide code-health pass that inventories every module, normalizes function/variable names to Swift API Guidelines, and applies explicit access control + actor annotations without changing behavior.
- Define a deprecation/retirement process for unused components and remove/replace the currently deprecated artifacts that are still compiled.
- Introduce a Tech Docs folder that captures architecture, data flow, concurrency model, MailKit helper surfaces, and refactor migration notes for future contributors.

## Impact
- Affected specs: new `code-health` and `tech-docs` capabilities.
- Affected code: `BetterMail/Sources`, `BetterMail/BetterMail*.swift`, `MailHelperExtension/*`, `Tests/*`, new documentation folder.
