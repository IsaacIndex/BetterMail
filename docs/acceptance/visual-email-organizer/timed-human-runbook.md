# Timed Human Organizer Trial Runbook

This runbook operationalizes the frozen
`visual-email-organizer-v1` timing contract. It does not change any gate,
denominator, threshold, fixture key, or valid-trial rule.

Only an unaided human participant operating the installed BetterMail surface
can produce `timed-human-task` evidence. Agent-assisted rehearsals, scripted UI
actions, unit tests, and deterministic fixture checks are diagnostic only and
must not enter the human denominators.

VoiceOver is deliberately deferred for the current pass. Keep it off during
these trials so the timing strata remain comparable. These synthetic runs also
keep Apple Mail locked and do not authorize or exercise real Mail mutations.

## Fixed environment

- Installed app: `/Users/isaacibm/Applications/BetterMail.app`
- Fixture: `organizer-100-v1`
- Metrics root:
  `/Users/isaacibm/Library/Containers/isaacwongnh.BetterMail/Data/Library/Application Support/BetterMail/OrganizerBenchmark/organizer-100-v1/`
- Temporary capture directory:
  `/tmp/bettermail-organizer-human-trials/<YYYYMMDD>/`
- Required banner before the participant acts:
  `Ready · organizer-100-v1 · <task> · <stratum> · Apple Mail locked, External Mail calls: 0`

Use a fresh lowercase run ID for every organization trial, for example
`synthetic-human-first-warm-01-20260830`. Ordinals `01` through `10` are the
planned denominator. If a trial is invalid before `task-ready`, retain its
capture and use `11` or higher for its replacement. Never replace a failure
after `task-ready`. Never reuse a run ID for a different participant or trial.
The only allowed reuse is the explicit setup/relaunch sequence below.

## Guarded capture helper

Before the participant is ready, run the no-launch installed-bundle preflight:

```bash
python3 script/run_organizer_human_trial.py preflight
```

It requires the BetterMail host app to be stopped, then deep-strict-verifies
the installed app and extension, exact certificate SHA-1, Team Identifier,
signed and plist bundle identifiers, and certificate-chain trust. It prints the
installed executable SHA-256 but does not launch, create a session manifest or
capture, assert unaided participation, or touch Mail.

Run every measured phase through the repository helper:

```bash
python3 script/run_organizer_human_trial.py run \
  first-warm 01 20260830 --attest-unaided
```

The helper does not send keyboard, pointer, AppleScript, or Accessibility UI
input. It requires the participant's unaided-action attestation, refuses to
run while another BetterMail process exists, and then:

1. deep-strict-verifies the installed app and Mail extension independently;
2. rejects ad-hoc signatures, the wrong Team Identifier, changed bundle IDs,
   an untrusted code-signing chain, or any leaf certificate other than SHA-1
   `59D9099E689B4FCF247C0E2C021C3B62E80AE4B2`;
3. pins the installed executable SHA-256 in the local dated session manifest,
   preventing mixed-build trials, including cold-setup evidence;
4. launches exactly one frozen phase and waits without sending UI input; and
5. after BetterMail exits, copies `OrganizerMetrics.json` byte-for-byte to a
   new capture file, never overwriting an earlier capture.

The helper preserves an invalid or incomplete raw report before returning an
error. A pre-`task-ready` invalid capture remains audit-safe but is excluded
from the denominator; retain it and use ordinal `11` or higher for the
replacement. Do not delete that capture. `--dry-run` prints the command and
paths but does not check signing, launch the app, or create evidence.
After `task-ready`, an app termination or incomplete pending trial remains a
denominator failure. A capture that claims completion is accepted only when
its top-level and record state agree and the full ordered task lifecycle is
present; inconsistent success evidence fails closed.

The runtime writes exactly one mutable file per run ID:
`<metrics-root>/<run-id>/OrganizerMetrics.json`. Copy that file to the capture
directory immediately after each measured phase and before relaunching the same
run ID. The helper performs this copy after the participant quits. A relaunch
replaces the runtime file; it does not append a second trial.

## Frozen visible actions

The first-organization task has one placement:

| Conversation | Destination |
| --- | --- |
| `Synthetic conversation 0001` | `Confirmed Group 01` |

The five-conversation task has five placements, in this order:

| Conversation | Destination |
| --- | --- |
| `Synthetic conversation 0001` | `Confirmed Group 01` |
| `Synthetic conversation 0002` | `Confirmed Group 02` |
| `Synthetic conversation 0003` | `Nested Group 01` |
| `Synthetic conversation 0004` | `Nested Group 02` |
| `Synthetic conversation 0005` | `Confirmed Group 03` |

After the five placements, enter the exact query
`synthetic-query-organized-0004` and wait until `Synthetic conversation 0005`
is visibly returned and remains selectable.

Use the same input method throughout a stratum. The preferred visual path is
to drag the conversation onto the named Group, wait for the intended target to
highlight, and then release. If the non-pointer equivalent is being measured,
select the source and invoke **Move selection here** on the named destination.

Do not invoke **Group** on the source row. That action creates a new Group; it
does not move the source into the frozen destination. The runtime correctly
classifies that outcome as `wrong-completion`.

## Validity and failure rules

1. Do not act until the complete Ready banner appears with the exact task and
   stratum, `Apple Mail locked`, and `External Mail calls: 0`.
2. A fixture or instrumentation problem before `task-ready` is invalid. Record
   the coarse reason, preserve the captured file, and rerun under a new run ID.
3. After `task-ready`, cancellation, wrong destination, missing visible result,
   failed action, app termination, or missing retrieval is a failed timed
   trial. Preserve it in the denominator; do not replace it with a clean run.
4. Do not edit a runtime JSON file. Capture it byte-for-byte.
5. Reject the session if the banner ever unlocks Apple Mail or the external
   Mail call count becomes nonzero.

## First organization: 10 warm trials

For each ordinal `01` through `10`, launch a fresh run with reset:

```bash
python3 script/run_organizer_human_trial.py run \
  first-warm 01 20260830 --attest-unaided
```

Change `01` for each subsequent trial. The helper derives and checks the run ID,
runtime report path, and capture filename together.

## First organization: 10 cold/relaunch trials

For each ordinal, first initialize a fresh isolated run in non-timed diagnostic
mode. Wait for Ready, then quit **before making any organization change**:

```bash
python3 script/run_organizer_human_trial.py run \
  first-cold-setup 01 20260830 --attest-unaided
```

Relaunch that same untouched run without reset:

```bash
python3 script/run_organizer_human_trial.py run \
  first-cold 01 20260830 --attest-unaided
```

Complete the placement and capture the report as `first-cold-01.json`. The
diagnostic setup launch is not a timed trial. Pre-organizing during setup makes
the cold trial invalid because the frozen source is no longer unorganized.

## Five-conversation task: 10 warm and 10 cold/relaunch trials

Use the warm or diagnostic-setup/cold sequence:

```bash
python3 script/run_organizer_human_trial.py run \
  five-warm 01 20260830 --attest-unaided
python3 script/run_organizer_human_trial.py run \
  five-cold-setup 01 20260830 --attest-unaided
python3 script/run_organizer_human_trial.py run \
  five-cold 01 20260830 --attest-unaided
```

The helper derives run IDs such as `synthetic-human-five-warm-01-20260830`
and `synthetic-human-five-cold-01-20260830`.

Complete all five mapped placements, enter the frozen query, and wait for the
expected visible selectable result. Copy each organization report immediately
as `five-warm-<ordinal>.json` or `five-cold-<ordinal>.json`.

Each of these 20 reports contains:

- the primary five-conversation duration from `task-ready` to
  `retrieval-visible`; and
- one post-commit retrieval duration from `search-start` to
  `retrieval-visible`.

Together, the 20 five-conversation reports supply the 20 required post-commit
retrieval samples. Keep their organization warm/cold strata separate when
calculating the five-conversation percentiles; combine only their retrieval
samples into the named `post-commit` retrieval slice.

## Retrieval after relaunch: 20 trials

Only after capturing a completed five-conversation report, quit and relaunch
the same persisted run ID in retrieval mode without reset:

```bash
python3 script/run_organizer_human_trial.py run \
  retrieval-warm-source 01 20260830 --attest-unaided
python3 script/run_organizer_human_trial.py run \
  retrieval-cold-source 01 20260830 --attest-unaided
```

Enter the frozen query and wait for the expected selectable conversation. Copy
the new report as `retrieval-relaunch-warm-source-01.json`. Repeat after every
warm and cold five-conversation trial, producing 20 post-relaunch reports. The
source name in the capture filename records which five-conversation run
prepared the persisted state; all 20 retrieval samples aggregate into the
named `post-relaunch` slice.

## Required denominator before adjudication

The captured set is complete only when it contains:

- 10 first-organization warm reports;
- 10 first-organization cold/relaunch reports;
- 10 five-conversation warm reports;
- 10 five-conversation cold/relaunch reports;
- 20 post-commit retrieval samples inside the five-conversation reports; and
- 20 separately captured post-relaunch retrieval reports.

Retain every failed and invalid report with its run ID and coarse reason. Before
promoting any aggregate into `results/`, verify that all reports use one app
build, the frozen protocol and fixture, zero external Mail calls, unique trial
IDs outside the documented setup/relaunch reuse, and the canonical task
lifecycle. Report median, P80, and P90 for each
organization stratum. Report the within-five-second count and rate for both
retrieval slices. Audit the local capture set first:

```bash
python3 script/run_organizer_human_trial.py audit 20260830
```

The audit reports captured, denominator-eligible, and contract-clean counts.
It does not create an aggregate or convert diagnostic data into human evidence.
Once every denominator is present, create a validated local proposal:

```bash
python3 script/run_organizer_human_trial.py aggregate-human 20260830
```

This command classifies pre-Ready invalid trials separately, keeps every
post-Ready failure in percentile math with an over-threshold duration, uses the
runtime retrieval timing entry—not the five-task duration—for post-commit
retrieval, and classifies both retrieval-source phases as `post-relaunch`
regardless of their raw `cold-relaunch` stratum. It calculates median, P80, and
P90 with the recorder's nearest-rank rule and emits all six frozen strata. It
also rejects mixed-build setup evidence, failed retrieval prerequisites, and a
base status whose fixture or protocol differs from the frozen identifiers.
Every retained valid capture participates in the aggregate; each stratum needs
at least ten, so a valid replacement or additional trial above ten remains in
the denominator instead of making an otherwise complete session pending.

The output is a timestamped, non-overwriting
`<capture-session>/aggregate/acceptance-status-proposed-*.json`. It is validated
against the closed acceptance-status and privacy contracts but does not edit
the repository result. A five-conversation capture without its retrieval
timing sample leaves the proposal incomplete; the tool never fabricates that
sample. Review the proposal and raw-capture audit before promoting it into
`results/`.

After promoting the reviewed sanitized aggregate, run:

```bash
env PYTHONDONTWRITEBYTECODE=1 \
  python3 Tests/Fixtures/Organizer/validate_benchmark.py
```

Do not mark tasks 7.7, 7.8, or the timed-human hard gate complete until the
sanitized aggregate artifacts and all retained failure/invalid reasons pass
that validator.
