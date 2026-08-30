#!/usr/bin/env python3
"""Fail-closed regression checks for sanitized organizer acceptance artifacts."""

from __future__ import annotations

import copy
import unittest
from pathlib import Path

from validate_benchmark import (
    ACCEPTANCE_STATUS_SCHEMA_PATH,
    METRIC_SCHEMA_PATH,
    REPO_ROOT,
    load,
    validate_acceptance_status,
    validate_metric_result,
)


STATUS_PATH = (
    REPO_ROOT
    / "docs/acceptance/visual-email-organizer/results/acceptance-status-2026-08-28.json"
)
PENDING_METRICS_PATH = (
    REPO_ROOT
    / "docs/acceptance/visual-email-organizer/results/organizer-metrics-evidence-v1.pending.json"
)


class AcceptanceValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.metric_schema = load(METRIC_SCHEMA_PATH)
        self.status_schema = load(ACCEPTANCE_STATUS_SCHEMA_PATH)
        self.status = load(STATUS_PATH)

    def validate_status(self, artifact: dict) -> list[str]:
        return validate_acceptance_status(
            Path("synthetic-test-status.json"),
            artifact,
            self.metric_schema,
            self.status_schema,
        )

    @staticmethod
    def passing_first_organization_artifact() -> dict:
        artifact = load(PENDING_METRICS_PATH)
        events = [
            {"sequence": 1, "event": "workspace-ready", "phase": "instant", "count": 1, "offsetMilliseconds": 0},
            {"sequence": 2, "event": "task-visible", "phase": "instant", "count": 1, "offsetMilliseconds": 1},
            {"sequence": 3, "event": "task-ready", "phase": "instant", "count": 1, "offsetMilliseconds": 2},
            {"sequence": 4, "event": "action-start", "phase": "started", "count": 1, "offsetMilliseconds": 3},
            {"sequence": 5, "event": "bettermail-commit", "phase": "instant", "count": 1, "offsetMilliseconds": 4},
            {"sequence": 6, "event": "rethread-complete", "phase": "instant", "count": 1, "offsetMilliseconds": 5},
            {"sequence": 7, "event": "group-visible", "phase": "instant", "count": 1, "offsetMilliseconds": 6},
            {"sequence": 8, "event": "visible-result", "phase": "finished", "count": 1, "offsetMilliseconds": 7, "durationMilliseconds": 4},
        ]
        artifact.update({
            "evidenceType": "timed-human-task",
            "status": "pass",
            "eventSummary": copy.deepcopy(events),
            "records": [{
                "trialId": "synthetic-first-pass",
                "taskId": "first-organization",
                "sourceNodeKeys": ["node-100-0000"],
                "destinationGroupKeys": ["group-flat-00"],
                "queryKey": None,
                "stratum": "warm",
                "status": "pass",
                "durationMilliseconds": 1_000,
                "eventSummary": copy.deepcopy(events),
                "targetOutcome": "organization",
                "mailCallCount": 1,
                "normalizedCommandCount": 1,
            }],
            "timing": [{
                "kind": "firstAction",
                "stratum": "warm",
                "sampleCount": 10,
                "validTrialCount": 10,
                "successCount": 10,
                "failureCount": 0,
                "invalidCount": 0,
                "cancelledCount": 0,
                "medianMilliseconds": 1_000,
                "p80Milliseconds": 1_000,
                "p90Milliseconds": 1_000,
                "thresholdMilliseconds": 30_000,
                "withinThresholdCount": 10,
                "withinThresholdRate": 1.0,
                "minimumWithinThresholdRate": 1.0,
                "status": "pass",
            }],
        })
        return artifact

    def test_overall_pass_requires_every_hard_gate(self) -> None:
        artifact = copy.deepcopy(self.status)
        artifact["status"] = "pass"
        artifact["gateStatus"] = {}
        artifact["unmetTargets"] = []

        errors = self.validate_status(artifact)

        self.assertTrue(any("missing hard gates" in error for error in errors))
        self.assertTrue(any("every hard gate" in error for error in errors))

    def test_deterministic_pass_requires_all_twelve_strata(self) -> None:
        artifact = copy.deepcopy(self.status)
        artifact["gateStatus"]["deterministicDropMatrix"].pop("strata")

        errors = self.validate_status(artifact)

        self.assertTrue(any("twelve frozen strata" in error for error in errors))

    def test_fixed_vocabulary_rejects_raw_observation_text(self) -> None:
        artifact = copy.deepcopy(self.status)
        artifact["records"][1]["observed"].append("raw subject: private")

        errors = self.validate_status(artifact)

        self.assertTrue(any("fixed-vocabulary" in error for error in errors))

    def test_metric_result_rejects_unknown_free_form_field(self) -> None:
        artifact = load(PENDING_METRICS_PATH)
        artifact["notes"] = "raw subject: private"

        errors = validate_metric_result(
            Path("synthetic-test-metrics.json"), artifact, self.metric_schema
        )

        self.assertTrue(any("unknown top-level fields" in error for error in errors))

    def test_timed_pass_requires_matching_passing_aggregate(self) -> None:
        artifact = load(PENDING_METRICS_PATH)
        artifact["evidenceType"] = "timed-human-task"
        artifact["status"] = "pass"
        artifact["records"] = [{
            "trialId": "synthetic-first-pass",
            "taskId": "first-organization",
            "sourceNodeKeys": ["node-100-0000"],
            "destinationGroupKeys": ["group-flat-00"],
            "queryKey": None,
            "stratum": "warm",
            "status": "pass",
            "durationMilliseconds": 1_000,
            "eventSummary": [],
            "targetOutcome": "organization",
            "mailCallCount": 0,
            "normalizedCommandCount": 1,
        }]

        errors = validate_metric_result(
            Path("synthetic-timed-pass.json"), artifact, self.metric_schema
        )

        self.assertTrue(any(
            "passing timed artifact lacks required aggregate timing evidence" in error
            for error in errors
        ))

    def test_pass_rejects_failed_record_even_with_passing_timing(self) -> None:
        artifact = self.passing_first_organization_artifact()
        artifact["records"][0]["status"] = "fail"
        artifact["records"][0]["coarseFailureReason"] = "action-failure"

        errors = validate_metric_result(
            Path("synthetic-fabricated-pass.json"), artifact, self.metric_schema
        )

        self.assertTrue(any(
            "passing artifact requires a passing aggregate trial record" in error
            for error in errors
        ))

    def test_pass_rejects_empty_event_summaries(self) -> None:
        artifact = self.passing_first_organization_artifact()
        artifact["eventSummary"] = []
        artifact["records"][0]["eventSummary"] = []

        errors = validate_metric_result(
            Path("synthetic-empty-events-pass.json"), artifact, self.metric_schema
        )

        self.assertTrue(any("nonempty record eventSummary" in error for error in errors))
        self.assertTrue(any("nonempty top-level eventSummary" in error for error in errors))

    def test_five_conversation_pass_requires_retrieval_visibility(self) -> None:
        artifact = self.passing_first_organization_artifact()
        record = artifact["records"][0]
        record.update({
            "taskId": "five-conversation-organization",
            "sourceNodeKeys": [f"node-100-{index:04d}" for index in range(5)],
            "destinationGroupKeys": [
                "group-flat-00", "group-flat-01", "group-nested-00",
                "group-nested-01", "group-flat-02",
            ],
            "queryKey": "synthetic-query-organized-0004",
        })
        artifact["timing"][0]["kind"] = "fiveConversation"
        artifact["timing"][0]["thresholdMilliseconds"] = 120_000

        errors = validate_metric_result(
            Path("synthetic-five-missing-retrieval.json"), artifact, self.metric_schema
        )

        self.assertTrue(any("retrieval-visible" in error for error in errors))

    def test_pass_rejects_out_of_order_readiness_events(self) -> None:
        artifact = self.passing_first_organization_artifact()
        events = artifact["eventSummary"]
        events[0], events[1] = events[1], events[0]
        for index, event in enumerate(events, start=1):
            event["sequence"] = index
        artifact["records"][0]["eventSummary"] = copy.deepcopy(events)

        errors = validate_metric_result(
            Path("synthetic-out-of-order-pass.json"), artifact, self.metric_schema
        )

        self.assertTrue(any("task-visible occurs before workspace-ready" in error for error in errors))
        self.assertTrue(any("lifecycle events are out of order" in error for error in errors))

    def test_pass_rejects_failed_terminal_event(self) -> None:
        artifact = self.passing_first_organization_artifact()
        artifact["eventSummary"][-1]["status"] = "failure"
        artifact["records"][0]["eventSummary"] = copy.deepcopy(artifact["eventSummary"])

        errors = validate_metric_result(
            Path("synthetic-failed-event-pass.json"), artifact, self.metric_schema
        )

        self.assertTrue(any("contains a failed lifecycle event" in error for error in errors))

    def test_live_pointer_pass_requires_drop_terminal_evidence(self) -> None:
        artifact = self.passing_first_organization_artifact()
        artifact["evidenceType"] = "live-pointer"
        artifact["records"][0].update({
            "taskId": "live-pointer",
            "sourceNodeKeys": [],
            "destinationGroupKeys": [],
            "queryKey": None,
            "targetOutcome": "pointer-drop",
        })
        artifact["timing"] = []

        errors = validate_metric_result(
            Path("synthetic-live-pointer-no-drop.json"), artifact, self.metric_schema
        )

        self.assertTrue(any("drop-outcome" in error for error in errors))

    def test_placement_pass_accepts_authoritative_outcome_after_commit_and_visibility(self) -> None:
        artifact = self.passing_first_organization_artifact()
        events = [
            {"sequence": 1, "event": "workspace-ready", "phase": "instant", "count": 1, "offsetMilliseconds": 0},
            {"sequence": 2, "event": "task-visible", "phase": "instant", "count": 1, "offsetMilliseconds": 1},
            {"sequence": 3, "event": "task-ready", "phase": "instant", "count": 1, "offsetMilliseconds": 2},
            {"sequence": 4, "event": "action-start", "phase": "instant", "count": 1, "offsetMilliseconds": 3},
            {"sequence": 5, "event": "drop-intent", "phase": "instant", "count": 1, "offsetMilliseconds": 4},
            {"sequence": 6, "event": "drop-highlight", "phase": "instant", "count": 1, "status": "success", "offsetMilliseconds": 5},
            {"sequence": 7, "event": "drop-release", "phase": "instant", "count": 1, "status": "success", "offsetMilliseconds": 6},
            {"sequence": 8, "event": "bettermail-commit", "phase": "instant", "count": 1, "status": "success", "offsetMilliseconds": 7},
            {"sequence": 9, "event": "rethread-complete", "phase": "instant", "count": 1, "status": "success", "offsetMilliseconds": 8},
            {"sequence": 10, "event": "group-visible", "phase": "instant", "count": 1, "status": "success", "offsetMilliseconds": 9},
            {"sequence": 11, "event": "visible-result", "phase": "instant", "count": 1, "status": "success", "offsetMilliseconds": 10},
            {"sequence": 12, "event": "drop-outcome", "phase": "instant", "count": 1, "status": "success", "offsetMilliseconds": 11},
        ]
        artifact.update({
            "evidenceType": "live-pointer",
            "eventSummary": copy.deepcopy(events),
            "timing": [],
        })
        artifact["records"][0].update({
            "taskId": "placement-set",
            "sourceNodeKeys": [f"node-500-{index:04d}" for index in range(20)],
            "destinationGroupKeys": ["group-flat-00"],
            "queryKey": None,
            "eventSummary": copy.deepcopy(events),
            "targetOutcome": "placement",
        })

        errors = validate_metric_result(
            Path("synthetic-placement-post-commit-outcome.json"), artifact, self.metric_schema
        )

        self.assertFalse(any("lifecycle events are out of order" in error for error in errors))
        self.assertFalse(any("drop outcome lacks a preceding release" in error for error in errors))

    def test_acceptance_status_rejects_sensitive_identifier_values(self) -> None:
        artifact = copy.deepcopy(self.status)
        artifact["runId"] = "synthetic-raw subject: private@example.com"

        errors = self.validate_status(artifact)

        self.assertTrue(any("runId is not a safe synthetic key" in error for error in errors))

        nested_artifact = copy.deepcopy(self.status)
        nested_artifact["gateStatus"]["productionEventBoundaries"]["installedRun"] = (
            "synthetic-raw subject: private@example.com"
        )

        nested_errors = self.validate_status(nested_artifact)

        self.assertTrue(any(
            "production event-boundary pass lacks installed rendered events" in error
            for error in nested_errors
        ))


if __name__ == "__main__":
    unittest.main()
