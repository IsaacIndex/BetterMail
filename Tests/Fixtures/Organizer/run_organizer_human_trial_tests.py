#!/usr/bin/env python3
"""Focused tests for the non-automating organizer human-trial helper."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT_PATH = REPO_ROOT / "script" / "run_organizer_human_trial.py"
SPEC = importlib.util.spec_from_file_location("run_organizer_human_trial", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
HARNESS = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = HARNESS
SPEC.loader.exec_module(HARNESS)


def artifact_for(plan, ordinal="01", capture_date="20260830", terminal=True):
    run_id = plan.run_id(ordinal, capture_date)
    if terminal and not plan.setup_only:
        event_names = HARNESS.PASS_REQUIRED_EVENT_SEQUENCE_BY_TASK[plan.task]
    else:
        event_names = ("workspace-ready", "task-visible", "task-ready")
    events = [
        {
            "event": event,
            **(
                {}
                if event in {"task-ready", "action-start", "search-start"}
                else {"status": "success"}
            ),
        }
        for event in event_names
    ]
    status = "pending" if plan.setup_only or not terminal else "insufficient-evidence"
    return {
        "runId": run_id,
        "fixtureId": HARNESS.FIXTURE_ID,
        "protocolId": HARNESS.PROTOCOL_ID,
        "appBuild": "build-1.0-1",
        "evidenceType": plan.expected_evidence_type,
        "status": status,
        "eventSummary": [dict(event) for event in events],
        "records": [
            {
                "trialId": run_id,
                "taskId": plan.task,
                "stratum": plan.stratum,
                "status": status,
                "mailCallCount": 0,
                "normalizedCommandCount": (
                    0 if plan.setup_only or plan.task == "retrieval" else 1
                ),
                "eventSummary": events,
            }
        ],
    }


def frozen_contract(plan):
    if plan.task == "first-organization":
        return ["node-100-0000"], ["group-flat-00"], None, "organization"
    if plan.task == "five-conversation-organization":
        return (
            [f"node-100-{index:04d}" for index in range(5)],
            [
                "group-flat-00",
                "group-flat-01",
                "group-nested-00",
                "group-nested-01",
                "group-flat-02",
            ],
            "synthetic-query-organized-0004",
            "organization",
        )
    return (
        ["node-100-0004"],
        ["group-flat-02"],
        "synthetic-query-organized-0004",
        "retrieval",
    )


def raw_timing_entry(kind, stratum, duration=None, outcome="pass"):
    if outcome == "none":
        sample_count = valid_count = success_count = failure_count = invalid_count = 0
    elif outcome == "invalid":
        sample_count = invalid_count = 1
        valid_count = success_count = failure_count = 0
    else:
        sample_count = valid_count = 1
        invalid_count = 0
        success_count = 1 if outcome == "pass" else 0
        failure_count = 1 if outcome == "fail" else 0
    entry = {
        "kind": kind,
        "stratum": stratum,
        "sampleCount": sample_count,
        "validTrialCount": valid_count,
        "successCount": success_count,
        "failureCount": failure_count,
        "invalidCount": invalid_count,
        "cancelledCount": 0,
    }
    if duration is not None:
        entry.update(
            {
                "medianMilliseconds": duration,
                "p80Milliseconds": duration,
                "p90Milliseconds": duration,
            }
        )
    return entry


def raw_artifact_for(
    plan,
    ordinal="01",
    capture_date="20260830",
    primary_duration=1000,
    primary_outcome="pass",
    retrieval_duration=500,
    retrieval_outcome="pass",
    terminal=True,
    pre_task_ready=False,
):
    artifact = artifact_for(plan, ordinal, capture_date, terminal=terminal)
    run_id = plan.run_id(ordinal, capture_date)
    sources, destinations, query, target = frozen_contract(plan)
    record = artifact["records"][0]
    record.update(
        {
            "trialId": run_id,
            "sourceNodeKeys": sources,
            "destinationGroupKeys": destinations,
            "queryKey": query,
            "targetOutcome": target,
        }
    )
    if pre_task_ready:
        record["status"] = "pending"
        artifact["status"] = "pending"
        record["normalizedCommandCount"] = 0
        record["eventSummary"] = [
            {"event": "workspace-ready", "status": "success"},
            {"event": "task-visible", "status": "success"},
        ]
        primary_outcome = "none"
        primary_duration = None
    elif primary_outcome == "fail":
        record["status"] = "fail"
        artifact["status"] = "fail"
        record["coarseFailureReason"] = "action-failure"
    artifact["eventSummary"] = [dict(event) for event in record["eventSummary"]]
    primary_kind = HARNESS.PRIMARY_TIMING_KIND[plan.task]
    artifact["timing"] = [
        raw_timing_entry(
            primary_kind,
            plan.stratum,
            primary_duration,
            primary_outcome,
        )
    ]
    if plan.task == "five-conversation-organization":
        artifact["timing"].append(
            raw_timing_entry(
                "retrieval",
                plan.stratum,
                retrieval_duration,
                retrieval_outcome,
            )
        )
    return artifact


def sanitized_pass_record(plan, ordinal, duration, capture_date="20260830"):
    sources, destinations, query, target = frozen_contract(plan)
    run_id = plan.run_id(ordinal, capture_date)
    stratum = "post-relaunch" if plan.task == "retrieval" else plan.stratum
    if plan.task == "retrieval":
        run_id += "-retrieval-relaunch"
        event_names = [
            "workspace-ready",
            "task-visible",
            "task-ready",
            "search-start",
            "retrieval-visible",
        ]
    elif plan.task == "first-organization":
        event_names = [
            "workspace-ready",
            "task-visible",
            "task-ready",
            "action-start",
            "bettermail-commit",
            "rethread-complete",
            "group-visible",
            "visible-result",
        ]
    else:
        event_names = [
            "workspace-ready",
            "task-visible",
            "task-ready",
            "action-start",
            "bettermail-commit",
            "rethread-complete",
            "group-visible",
            "visible-result",
            "search-start",
            "retrieval-visible",
        ]
    events = [
        {
            "sequence": index,
            "event": event,
            "count": 1,
            **({"status": "success"} if event not in {"task-ready", "action-start", "search-start"} else {}),
        }
        for index, event in enumerate(event_names, start=1)
    ]
    return {
        "trialId": run_id,
        "appBuild": "build-1.0-1",
        "evidenceType": "timed-human-task",
        "taskId": plan.task,
        "sourceNodeKeys": sources,
        "destinationGroupKeys": destinations,
        "queryKey": query,
        "stratum": stratum,
        "status": "pass",
        "durationMilliseconds": duration,
        "targetOutcome": target,
        "mailCallCount": 0,
        "normalizedCommandCount": 0 if plan.task == "retrieval" else 1,
        "eventSummary": events,
    }


def adjudicated_pass_capture(plan, ordinal, duration=1000):
    record = sanitized_pass_record(plan, ordinal, duration)
    primary = HARNESS.TimingObservation(
        plan.task,
        record["stratum"],
        "pass",
        duration,
    )
    post_commit = None
    if plan.task == "five-conversation-organization":
        post_commit = HARNESS.TimingObservation(
            "retrieval", "post-commit", "pass", 500
        )
    return HARNESS.AdjudicatedCapture(
        plan=plan,
        ordinal=ordinal,
        path=Path(f"{plan.capture_stem}-{ordinal}.json"),
        artifact={"appBuild": "build-1.0-1"},
        sanitized_record=record,
        primary_observation=primary,
        post_commit_observation=post_commit,
    )


class OrganizerHumanTrialHarnessTests(unittest.TestCase):
    def test_phase_plan_builds_frozen_run_ids_and_commands(self):
        setup = HARNESS.PHASES["first-cold-setup"]
        timed = HARNESS.PHASES["first-cold"]

        self.assertEqual(
            setup.run_id("01", "20260830"),
            "synthetic-human-first-cold-01-20260830",
        )
        setup_command = HARNESS.command_for_phase(
            setup, "01", "20260830", Path("/Applications/BetterMail")
        )
        timed_command = HARNESS.command_for_phase(
            timed, "01", "20260830", Path("/Applications/BetterMail")
        )

        self.assertIn("--organizer-benchmark-reset", setup_command)
        self.assertNotIn("--organizer-benchmark-reset", timed_command)
        self.assertEqual(timed_command[-1], "cold-relaunch")
        self.assertEqual(
            HARNESS.PHASES["retrieval-warm-source"].run_id("07", "20260830"),
            "synthetic-human-five-warm-07-20260830",
        )

    def test_date_and_ordinal_validation_fail_closed(self):
        self.assertEqual(HARNESS.validate_ordinal("11"), "11")
        self.assertEqual(HARNESS.validate_capture_date("20260830"), "20260830")
        for invalid in ("00", "1", "100", "aa"):
            with self.subTest(ordinal=invalid):
                with self.assertRaises(HARNESS.HarnessError):
                    HARNESS.validate_ordinal(invalid)
        for invalid in ("20260230", "2026-08-30", "2026083"):
            with self.subTest(capture_date=invalid):
                with self.assertRaises(HARNESS.HarnessError):
                    HARNESS.validate_capture_date(invalid)

    def test_capture_preserves_exact_bytes_and_never_overwrites(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.json"
            destination = root / "captures" / "trial.json"
            raw = b'{\n  "status" : "insufficient-evidence"\n}\n'
            source.write_bytes(raw)

            captured = HARNESS.copy_bytes_exclusive(source, destination)

            self.assertEqual(captured, raw)
            self.assertEqual(destination.read_bytes(), raw)
            with self.assertRaises(HARNESS.HarnessError):
                HARNESS.copy_bytes_exclusive(source, destination)

    def test_continuation_report_must_be_rewritten_before_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "OrganizerMetrics.json"
            report.write_bytes(b"before")
            previous = HARNESS.file_sha256(report)

            with self.assertRaises(HARNESS.HarnessError):
                HARNESS.require_fresh_runtime_report(report, previous)

            report.write_bytes(b"after")
            HARNESS.require_fresh_runtime_report(report, previous)

    def test_run_phase_wires_stale_continuation_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            capture_root = root / "captures"
            metrics_root = root / "metrics"
            plan = HARNESS.PHASES["first-cold"]
            report = HARNESS.runtime_report_path(
                plan, "01", "20260830", metrics_root
            )
            report.parent.mkdir(parents=True)
            report.write_bytes(b"unchanged prior report")

            with mock.patch.object(HARNESS, "verify_prerequisite"), mock.patch.object(
                HARNESS, "ensure_app_not_running"
            ), mock.patch.object(
                HARNESS, "verify_installed_signing", return_value="a" * 64
            ), mock.patch.object(
                HARNESS,
                "ensure_session_manifest",
                return_value=capture_root / "20260830" / "session-manifest.json",
            ), mock.patch.object(
                HARNESS.subprocess,
                "run",
                return_value=HARNESS.subprocess.CompletedProcess([], 0),
            ), redirect_stdout(StringIO()):
                with self.assertRaisesRegex(
                    HARNESS.HarnessError, "refusing to capture stale evidence"
                ):
                    HARNESS.run_phase(
                        "first-cold",
                        "01",
                        "20260830",
                        True,
                        capture_root=capture_root,
                        metrics_root=metrics_root,
                    )

    def test_context_rejects_wrong_contract_and_external_mail_calls(self):
        plan = HARNESS.PHASES["first-warm"]
        artifact = artifact_for(plan)
        artifact["runId"] = "synthetic-wrong-run"
        artifact["records"][0]["mailCallCount"] = 1
        artifact["records"][0]["eventSummary"].append(
            {"event": "mail-result", "status": "success"}
        )

        errors = HARNESS.context_errors(artifact, plan, "01", "20260830")

        self.assertTrue(any("runId must be" in error for error in errors))
        self.assertTrue(any("mailCallCount" in error for error in errors))
        self.assertTrue(any("external Mail events" in error for error in errors))

    def test_timed_context_requires_terminal_lifecycle_event(self):
        plan = HARNESS.PHASES["five-warm"]
        artifact = artifact_for(plan, terminal=False)
        artifact["status"] = "insufficient-evidence"
        artifact["records"][0]["status"] = "insufficient-evidence"

        errors = HARNESS.context_errors(artifact, plan, "01", "20260830")

        self.assertTrue(any("retrieval-visible" in error for error in errors))

    def test_timed_context_requires_full_lifecycle_and_matching_run_state(self):
        plan = HARNESS.PHASES["five-warm"]
        artifact = raw_artifact_for(plan)
        record = artifact["records"][0]
        record["eventSummary"] = [
            event
            for event in record["eventSummary"]
            if event.get("event") != "group-visible"
        ]
        artifact["eventSummary"] = [dict(event) for event in record["eventSummary"]]

        errors = HARNESS.context_errors(artifact, plan, "01", "20260830")

        self.assertTrue(any("group-visible" in error for error in errors))

        artifact = raw_artifact_for(plan)
        artifact["status"] = "fail"
        errors = HARNESS.context_errors(artifact, plan, "01", "20260830")
        self.assertTrue(any("top-level and record status" in error for error in errors))

    def test_cold_setup_rejects_commands_and_mutation_events(self):
        plan = HARNESS.PHASES["five-cold-setup"]
        artifact = artifact_for(plan)
        record = artifact["records"][0]
        record["normalizedCommandCount"] = 1
        record["eventSummary"].append(
            {"event": "bettermail-commit", "status": "success"}
        )

        errors = HARNESS.context_errors(artifact, plan, "01", "20260830")

        self.assertTrue(any("normalized commands" in error for error in errors))
        self.assertTrue(any("mutation events" in error for error in errors))

    def test_prerequisite_paths_match_the_same_isolated_run(self):
        with tempfile.TemporaryDirectory() as directory:
            capture_root = Path(directory)
            cold = HARNESS.PHASES["first-cold"]
            retrieval = HARNESS.PHASES["retrieval-cold-source"]

            self.assertEqual(
                HARNESS.prerequisite_capture(
                    cold, "03", "20260830", capture_root
                ),
                capture_root / "20260830" / "setup-first-cold-03.json",
            )
            self.assertEqual(
                HARNESS.prerequisite_capture(
                    retrieval, "09", "20260830", capture_root
                ),
                capture_root / "20260830" / "five-cold-09.json",
            )

    def test_retrieval_prerequisite_requires_completed_source_retrieval(self):
        with tempfile.TemporaryDirectory() as directory:
            capture_root = Path(directory)
            retrieval = HARNESS.PHASES["retrieval-warm-source"]
            source_plan = HARNESS.PHASES["five-warm"]
            source = HARNESS.capture_path_for(
                source_plan, "01", "20260830", capture_root
            )
            source.parent.mkdir(parents=True)
            source.write_text("{}", encoding="utf-8")
            incomplete = artifact_for(source_plan, terminal=False)

            with mock.patch.object(
                HARNESS,
                "decode_and_validate",
                return_value=(incomplete, []),
            ):
                with self.assertRaisesRegex(
                    HARNESS.HarnessError,
                    "did not complete five-conversation organization",
                ):
                    HARNESS.verify_prerequisite(
                        retrieval, "01", "20260830", capture_root
                    )

    def test_retrieval_prerequisite_rejects_failed_source_with_terminal_noise(self):
        with tempfile.TemporaryDirectory() as directory:
            capture_root = Path(directory)
            retrieval = HARNESS.PHASES["retrieval-warm-source"]
            source_plan = HARNESS.PHASES["five-warm"]
            source = HARNESS.capture_path_for(
                source_plan, "01", "20260830", capture_root
            )
            source.parent.mkdir(parents=True)
            source.write_text("{}", encoding="utf-8")
            failed = raw_artifact_for(
                source_plan,
                primary_outcome="fail",
                terminal=False,
            )

            with mock.patch.object(
                HARNESS,
                "decode_and_validate",
                return_value=(failed, []),
            ):
                with self.assertRaisesRegex(
                    HARNESS.HarnessError,
                    "did not complete five-conversation organization",
                ):
                    HARNESS.verify_prerequisite(
                        retrieval, "01", "20260830", capture_root
                    )

    def test_session_manifest_pins_one_binary_without_local_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            capture_root = Path(directory)
            path = HARNESS.ensure_session_manifest(
                "a" * 64, "20260830", capture_root
            )
            manifest = json.loads(path.read_text(encoding="utf-8"))

            self.assertEqual(manifest["teamIdentifier"], "TN3L2WBKR5")
            self.assertEqual(
                manifest["signingCertificateSHA1"],
                "59D9099E689B4FCF247C0E2C021C3B62E80AE4B2",
            )
            self.assertIs(manifest["unaidedHumanActionAttestation"], True)
            self.assertNotIn("/Users/", path.read_text(encoding="utf-8"))
            with self.assertRaises(HARNESS.HarnessError):
                HARNESS.ensure_session_manifest(
                    "b" * 64, "20260830", capture_root
                )

    def test_session_manifest_validation_rejects_tampering(self):
        with tempfile.TemporaryDirectory() as directory:
            capture_root = Path(directory)
            path = HARNESS.ensure_session_manifest(
                "a" * 64, "20260830", capture_root
            )
            self.assertEqual(
                HARNESS.validate_session_manifest(path, "20260830"), []
            )
            manifest = json.loads(path.read_text(encoding="utf-8"))
            manifest["teamIdentifier"] = "MSTX4LWLXN"
            path.write_text(json.dumps(manifest), encoding="utf-8")

            errors = HARNESS.validate_session_manifest(path, "20260830")

            self.assertTrue(any("teamIdentifier" in error for error in errors))

    def test_signature_details_reject_wrong_signed_identifier(self):
        details = "\n".join(
            [
                "Identifier=com.example.changed",
                "Signature size=4799",
                "TeamIdentifier=TN3L2WBKR5",
            ]
        )

        with self.assertRaises(HARNESS.HarnessError):
            HARNESS.validate_signature_details(
                details, "BetterMail.app", HARNESS.APP_BUNDLE_ID
            )

    def test_preflight_checks_stopped_app_then_reports_signed_binary(self):
        calls = []
        with mock.patch.object(
            HARNESS,
            "ensure_app_not_running",
            side_effect=lambda: calls.append("process"),
        ), mock.patch.object(
            HARNESS,
            "verify_installed_signing",
            side_effect=lambda: calls.append("signing") or "a" * 64,
        ), redirect_stdout(StringIO()) as output:
            executable_sha256 = HARNESS.preflight_installed_trial()

        self.assertEqual(calls, ["process", "signing"])
        self.assertEqual(executable_sha256, "a" * 64)
        self.assertIn("No app launch", output.getvalue())

    def test_preflight_does_not_inspect_signing_while_host_app_runs(self):
        with mock.patch.object(
            HARNESS,
            "ensure_app_not_running",
            side_effect=HARNESS.HarnessError("BetterMail is already running"),
        ), mock.patch.object(HARNESS, "verify_installed_signing") as verify:
            with self.assertRaisesRegex(HARNESS.HarnessError, "already running"):
                HARNESS.preflight_installed_trial()

        verify.assert_not_called()

    def test_audit_rejects_orphaned_continuation_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            capture_root = Path(directory)
            HARNESS.ensure_session_manifest("a" * 64, "20260830", capture_root)
            plan = HARNESS.PHASES["first-cold"]
            capture = HARNESS.capture_path_for(
                plan, "01", "20260830", capture_root
            )
            capture.write_text("{}", encoding="utf-8")
            artifact = artifact_for(plan)

            with mock.patch.object(
                HARNESS,
                "decode_and_validate",
                return_value=(artifact, []),
            ), redirect_stdout(StringIO()), redirect_stderr(StringIO()) as errors:
                status = HARNESS.audit_session("20260830", capture_root)

            self.assertEqual(status, 1)
            self.assertIn("required prior capture is missing", errors.getvalue())

    def test_pre_task_ready_invalid_is_safe_to_retain_and_exclude(self):
        plan = HARNESS.PHASES["first-warm"]
        artifact = raw_artifact_for(plan, pre_task_ready=True)
        record = artifact["records"][0]

        self.assertTrue(HARNESS.is_pre_task_ready_invalid(record))
        self.assertEqual(
            HARNESS.context_errors(artifact, plan, "01", "20260830"), []
        )
        capture = HARNESS.adjudicate_capture(
            plan, "01", Path("first-warm-01.json"), artifact
        )
        replacement = adjudicated_pass_capture(plan, "11")
        observations = [capture.primary_observation] + [
            adjudicated_pass_capture(plan, f"{ordinal:02d}").primary_observation
            for ordinal in range(2, 11)
        ] + [replacement.primary_observation]

        summary = HARNESS.summarize_timing_slice(
            "first-organization", "warm", observations
        )

        self.assertEqual(capture.sanitized_record["status"], "invalid")
        self.assertEqual(
            capture.sanitized_record["coarseFailureReason"],
            "instrumentation-before-task-ready",
        )
        self.assertEqual(summary["validTrialCount"], 10)

    def test_post_task_ready_failure_uses_over_threshold_duration(self):
        plan = HARNESS.PHASES["first-warm"]
        artifact = raw_artifact_for(
            plan,
            primary_outcome="none",
            primary_duration=None,
            terminal=False,
        )

        self.assertEqual(
            HARNESS.context_errors(artifact, plan, "01", "20260830"), []
        )

        capture = HARNESS.adjudicate_capture(
            plan, "01", Path("first-warm-01.json"), artifact
        )
        gate, _ = HARNESS.build_timed_gate([capture])
        warm = next(
            entry
            for entry in gate["strata"]
            if entry["taskId"] == "first-organization"
            and entry["stratum"] == "warm"
        )

        self.assertEqual(capture.primary_observation.status, "fail")
        self.assertEqual(capture.primary_observation.duration_milliseconds, 30_001)
        self.assertEqual(warm["validTrialCount"], 1)
        self.assertEqual(
            capture.sanitized_record["coarseFailureReason"], "app-termination"
        )

    def test_nearest_rank_p80_includes_failed_over_threshold_trials(self):
        observations = [
            HARNESS.TimingObservation(
                "first-organization", "warm", "pass", 10_000 + index
            )
            for index in range(7)
        ] + [
            HARNESS.TimingObservation(
                "first-organization", "warm", "fail", 30_001
            )
            for _ in range(3)
        ]

        summary = HARNESS.summarize_timing_slice(
            "first-organization", "warm", observations
        )

        self.assertEqual(summary["validTrialCount"], 10)
        self.assertEqual(summary["p80Milliseconds"], 30_001)
        self.assertEqual(summary["withinThresholdRate"], 0.7)

    def test_retrieval_slice_uses_phase_and_five_uses_retrieval_timing(self):
        retrieval_plan = HARNESS.PHASES["retrieval-warm-source"]
        retrieval_artifact = raw_artifact_for(
            retrieval_plan, primary_duration=432
        )
        retrieval_capture = HARNESS.adjudicate_capture(
            retrieval_plan,
            "01",
            Path("retrieval-relaunch-warm-source-01.json"),
            retrieval_artifact,
        )
        five_plan = HARNESS.PHASES["five-warm"]
        five_artifact = raw_artifact_for(
            five_plan,
            primary_duration=99_999,
            retrieval_duration=321,
        )
        five_capture = HARNESS.adjudicate_capture(
            five_plan, "01", Path("five-warm-01.json"), five_artifact
        )

        self.assertEqual(retrieval_capture.primary_observation.stratum, "post-relaunch")
        self.assertEqual(retrieval_capture.sanitized_record["stratum"], "post-relaunch")
        self.assertEqual(
            five_capture.post_commit_observation.duration_milliseconds, 321
        )
        self.assertNotEqual(
            five_capture.post_commit_observation.duration_milliseconds,
            five_capture.primary_observation.duration_milliseconds,
        )

    def test_missing_post_commit_retrieval_fails_closed_as_incomplete(self):
        plan = HARNESS.PHASES["five-warm"]
        artifact = raw_artifact_for(
            plan,
            retrieval_duration=None,
            retrieval_outcome="none",
        )
        capture = HARNESS.adjudicate_capture(
            plan, "01", Path("five-warm-01.json"), artifact
        )

        gate, issues = HARNESS.build_timed_gate([capture])

        self.assertIsNone(capture.post_commit_observation)
        self.assertEqual(gate["status"], "pending")
        self.assertTrue(any("missing its post-commit" in issue for issue in issues))

    def test_proposed_six_slice_pass_validates_and_is_privacy_safe(self):
        captures = []
        for phase in ("first-warm", "first-cold", "five-warm", "five-cold"):
            captures.extend(
                adjudicated_pass_capture(HARNESS.PHASES[phase], f"{ordinal:02d}")
                for ordinal in range(1, 11)
            )
        for phase in ("retrieval-warm-source", "retrieval-cold-source"):
            captures.extend(
                adjudicated_pass_capture(HARNESS.PHASES[phase], f"{ordinal:02d}")
                for ordinal in range(1, 11)
            )
        base = json.loads(
            HARNESS.BASE_ACCEPTANCE_STATUS_PATH.read_text(encoding="utf-8")
        )

        proposed, issues = HARNESS.propose_acceptance_status(
            base, captures, "20260830"
        )
        validation_errors = HARNESS.validate_proposed_acceptance_status(
            Path("acceptance-status-proposed.json"), proposed
        )

        self.assertEqual(issues, [])
        self.assertEqual(
            proposed["gateStatus"]["timedHumanTasks"]["status"], "pass"
        )
        self.assertEqual(
            len(proposed["gateStatus"]["timedHumanTasks"]["strata"]), 6
        )
        self.assertEqual(validation_errors, [])
        encoded = json.dumps(proposed)
        for forbidden in ("rawSubject", "sender", "mailboxPath", "rawThreadId"):
            self.assertNotIn(forbidden, encoded)

    def test_six_slice_gate_keeps_and_accepts_an_extra_valid_trial(self):
        captures = []
        for phase in ("first-warm", "first-cold", "five-warm", "five-cold"):
            captures.extend(
                adjudicated_pass_capture(HARNESS.PHASES[phase], f"{ordinal:02d}")
                for ordinal in range(1, 11)
            )
        captures.append(
            adjudicated_pass_capture(HARNESS.PHASES["first-warm"], "11")
        )
        for phase in ("retrieval-warm-source", "retrieval-cold-source"):
            captures.extend(
                adjudicated_pass_capture(HARNESS.PHASES[phase], f"{ordinal:02d}")
                for ordinal in range(1, 11)
            )

        gate, issues = HARNESS.build_timed_gate(captures)
        warm = next(
            entry
            for entry in gate["strata"]
            if entry["taskId"] == "first-organization"
            and entry["stratum"] == "warm"
        )

        self.assertEqual(issues, [])
        self.assertEqual(gate["status"], "pass")
        self.assertEqual(gate["validFirstOrganizationTrials"], 21)
        self.assertEqual(warm["validTrialCount"], 11)

    def test_proposal_rejects_mixed_capture_builds(self):
        first = adjudicated_pass_capture(HARNESS.PHASES["first-warm"], "01")
        second = adjudicated_pass_capture(HARNESS.PHASES["first-warm"], "02")
        second = HARNESS.AdjudicatedCapture(
            plan=second.plan,
            ordinal=second.ordinal,
            path=second.path,
            artifact={"appBuild": "build-other"},
            sanitized_record={**second.sanitized_record, "appBuild": "build-other"},
            primary_observation=second.primary_observation,
            post_commit_observation=second.post_commit_observation,
        )
        base = json.loads(
            HARNESS.BASE_ACCEPTANCE_STATUS_PATH.read_text(encoding="utf-8")
        )

        with self.assertRaisesRegex(HARNESS.HarnessError, "mixed app builds"):
            HARNESS.propose_acceptance_status(
                base, [first, second], "20260830"
            )

    def test_collection_rejects_mixed_setup_and_timed_builds(self):
        with tempfile.TemporaryDirectory() as directory:
            capture_root = Path(directory)
            session = capture_root / "20260830"
            session.mkdir()
            setup_plan = HARNESS.PHASES["first-cold-setup"]
            timed_plan = HARNESS.PHASES["first-cold"]
            setup_artifact = artifact_for(setup_plan)
            setup_artifact["appBuild"] = "build-setup-other"
            timed_artifact = raw_artifact_for(timed_plan)
            artifacts = {
                setup_plan.name: setup_artifact,
                timed_plan.name: timed_artifact,
            }
            for plan in (setup_plan, timed_plan):
                HARNESS.capture_path_for(
                    plan, "01", "20260830", capture_root
                ).write_text("{}", encoding="utf-8")

            def decode(_raw, _path, plan, *_args, **_kwargs):
                return artifacts[plan.name], []

            with mock.patch.object(
                HARNESS, "validate_session_manifest", return_value=[]
            ), mock.patch.object(
                HARNESS, "decode_and_validate", side_effect=decode
            ):
                with self.assertRaisesRegex(
                    HARNESS.HarnessError, "including setup evidence"
                ):
                    HARNESS.collect_adjudicated_captures(
                        "20260830", capture_root
                    )

    def test_proposal_binds_exact_fixture_and_protocol(self):
        base = json.loads(
            HARNESS.BASE_ACCEPTANCE_STATUS_PATH.read_text(encoding="utf-8")
        )
        for field, value in (
            ("fixtureId", "organizer-100-stale"),
            ("protocolId", "visual-email-organizer-stale"),
        ):
            with self.subTest(field=field):
                stale = dict(base)
                stale[field] = value
                with self.assertRaisesRegex(HARNESS.HarnessError, field):
                    HARNESS.propose_acceptance_status(
                        stale, [], "20260830"
                    )

    def test_unknown_capture_filename_is_not_in_phase_vocabulary(self):
        plan, ordinal = HARNESS._capture_phase_from_name("hand-edited-result.json")

        self.assertIsNone(plan)
        self.assertIsNone(ordinal)


if __name__ == "__main__":
    unittest.main()
