---
name: mail-applescript-triage
description: Triage Mail.app AppleScript failures quickly and safely on macOS, with parse-vs-runtime checks, app-availability probes, and xcodebuild test/build preflight rules.
---

# Mail AppleScript Triage

## When to use

Use this skill when debugging Mail automation or Swift code that generates/runs AppleScript against Mail.app, especially after errors like:
- `Can’t get application id "com.apple.mail". (-1728)`
- `Expected class name but found identifier. (-2741)`
- generic Apple Event `-10000` failures

## Core rules

- Separate **compile/parse** failures from **runtime/app-availability** failures first.
- Do not loop on the same `osascript` command without new evidence.
- Prefer `tell application "Mail"` probes when `application id "com.apple.mail"` is unstable.
- For generated scripts, run parse-first checks before app-scoped execution checks.
- If tests are requested, preflight scheme testability before `xcodebuild test`.

## Workflow

1. Compile-only gate (does not execute the script; application dictionaries may still be needed)
2. Mail-availability probe
3. Terms-context probe (`tell` vs `using terms from`)
4. Generated script minimization/repro
5. xcodebuild preflight for testability
6. For diagnosis-only requests, report root cause and the next concrete check. For an authorized fix, apply the scoped correction and rerun affected compile/runtime checks before reporting completion; distinguish any blocked runtime proof.

## Canonical commands

### 1) Compile-only check (syntax)

```bash
mail_compile_dir=$(mktemp -d "${TMPDIR:-/tmp}/mail-compile.XXXXXX")
osacompile -o "$mail_compile_dir/check.scpt" /path/to/script.applescript
```

`osacompile` compiles without executing the script. Resolving application terminology can still require the target app dictionary. `osascript -s s` executes the script; `-s s` changes output formatting only. Never use it as a compile-only gate. Retain the temporary output until diagnosis is complete, then remove only the generated temporary directory.

Execute app-scoped probes only when the user's task authorizes runtime inspection and the active tools permit that method. Compile success is not runtime proof. If an app, dictionary, or permission is unavailable, report the precise blocker without running the full target script.

If this fails with `-2741`, treat it as compile-time script construction issue.

### 2) Mail availability (name form)

```bash
osascript -e 'tell application "Mail" to get name of every account'
```

If this fails with connection/app issues, classify as environment/runtime.

### 3) Mail availability (id form fallback/compare)

```bash
osascript -e 'tell application id "com.apple.mail" to get name of every account'
```

If id-form fails but name-form works, avoid id-form in temporary probes.

### 4) Minimal terms-context probe

```bash
cat >/tmp/mail_terms_probe.applescript <<'APPLESCRIPT'
on probe(_c)
  tell application "Mail"
    return (count of (every mailbox of _c))
  end tell
end probe
return "ok"
APPLESCRIPT
osascript -s s /tmp/mail_terms_probe.applescript
```

### 5) xcodebuild preflight before test

```bash
xcodebuild -list -project YourProject.xcodeproj
xcodebuild -showBuildSettings -project YourProject.xcodeproj -scheme YourScheme | rg -n "TEST_HOST|BUNDLE_LOADER|PRODUCT_NAME"
```

If scheme is not test-configured, run `build` instead of `test`.

## Retry discipline

- Max one rerun of an identical command without changed evidence.
- Required before rerun: changed script, changed command, or new diagnostic line.

## Output checklist

- Exact failing command
- Error class: parse vs runtime vs scheme/test-action
- One-line root cause
- Next 1-2 commands to run
- Whether to switch from `test` to `build`
