## 1. Planning and Audit
- [ ] 1.1 Inventory modules (DataSource, Storage, Threading, Services, ViewModels, UI, Support, Settings, MailHelperExtension) and catalog functions/variables needing renames, access control, and actor annotations.
- [ ] 1.2 List deprecated or unused surfaces (e.g., MessageRowView, legacy thread list artifacts, dead MailHelper handlers) with proposed actions (remove, wrap, or replace) and communicate any breaking removals.

## 2. Refactor Execution
- [ ] 2.1 Apply naming/access-control/actor updates module-by-module with mechanical refactors and test updates to avoid behavior regressions.
- [ ] 2.2 Remove or gate deprecated artifacts per the action list, adding replacements or @available annotations where needed.
- [ ] 2.3 Run formatter/lints as available and update build settings if they block the refactor (no new dependencies).

## 3. Tech Documentation
- [ ] 3.1 Create `TechDocs/` folder with architecture overview, module map, data flow/concurrency notes, MailKit helper summary, and deprecation log.
- [ ] 3.2 Capture refactor migration notes (renamed APIs, removed types) and link them from README/AGENTS as appropriate.

## 4. Validation
- [ ] 4.1 `openspec validate refactor-repo-health-docs --strict --no-interactive`
- [ ] 4.2 `xcodebuild -project BetterMail.xcodeproj -scheme BetterMail -configuration Debug -destination 'platform=macOS,arch=arm64' build > /tmp/xcodebuild.log 2>&1` and triage failures.
