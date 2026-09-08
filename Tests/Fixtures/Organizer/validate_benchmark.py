#!/usr/bin/env python3
"""Validate the frozen visual-email-organizer fixture and benchmark contract."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(SCRIPT_DIR))

from generate_fixtures import validate_fixture, validate_suggestions  # noqa: E402
from generate_suggestion_v2 import validate_files as validate_suggestion_v2_files  # noqa: E402


MANIFEST_PATH = REPO_ROOT / "docs/acceptance/visual-email-organizer/benchmark-manifest-v1.json"
METRIC_SCHEMA_PATH = REPO_ROOT / "docs/acceptance/visual-email-organizer/metric-schema-v1.json"
ACCEPTANCE_STATUS_SCHEMA_PATH = REPO_ROOT / "docs/acceptance/visual-email-organizer/acceptance-status-schema-v1.json"
RESULTS_DIR = REPO_ROOT / "docs/acceptance/visual-email-organizer/results"
SAFE_IDENTIFIER_PATTERN = re.compile(r"^[a-z0-9]+(?:[._-][a-z0-9]+)*$")


def is_safe_identifier(value: object, prefixes: tuple[str, ...]) -> bool:
    return (
        isinstance(value, str)
        and 1 <= len(value) <= 128
        and value.startswith(prefixes)
        and SAFE_IDENTIFIER_PATTERN.fullmatch(value) is not None
    )


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_manifest(manifest: dict) -> list[str]:
    errors: list[str] = []
    if manifest.get("schemaVersion") != "visual-email-organizer-benchmark-v1":
        errors.append("manifest schemaVersion is not visual-email-organizer-benchmark-v1")
    if manifest.get("protocolId") != "visual-email-organizer-v1":
        errors.append("manifest protocolId is not visual-email-organizer-v1")
    fixtures = {fixture["fixtureId"]: fixture for fixture in manifest.get("fixtures", [])}
    for fixture_id, expected_count in (("organizer-100-v1", 100), ("organizer-500-v1", 500)):
        if fixtures.get(fixture_id, {}).get("nodeCount") != expected_count:
            errors.append(f"manifest fixture {fixture_id} has the wrong nodeCount")

    matrix = manifest.get("dropMatrix", {})
    dimensions = matrix.get("dimensions", {})
    expected_strata = len(dimensions.get("nodeCount", [])) * len(dimensions.get("zoomBand", [])) * len(dimensions.get("targetShape", []))
    if expected_strata != 12 or matrix.get("strataCount") != 12:
        errors.append("drop matrix must have exactly 12 strata")
    if matrix.get("attemptsPerStratum") != 10 or matrix.get("totalAttempts") != 120:
        errors.append("drop matrix must have exactly 10 attempts per stratum and 120 total")
    if matrix.get("overallSuccessMinimum") != 0.95 or matrix.get("perStratumSuccessMinimum") != 0.90:
        errors.append("drop matrix success gates do not match the contract")

    live = manifest.get("livePointer", {})
    if live.get("minimumAttempts", 0) < 40:
        errors.append("live pointer contract has fewer than 40 attempts")
    required_coverage = live.get("requiredCoverage", {})
    for dimension, expected in {
        "selectionMode": {"single", "multi"},
        "zoomBand": {"low", "medium", "high"},
        "targetShape": {"flat", "nested"},
        "labelVariant": {"short", "long"},
    }.items():
        if set(required_coverage.get(dimension, [])) != expected:
            errors.append(f"live pointer coverage is incomplete for {dimension}")

    sets = manifest.get("placementSets", [])
    if len(sets) != 5:
        errors.append("exactly five placement sets are required")
    source_keys: set[str] = set()
    for placement_set in sets:
        nodes = placement_set.get("sourceNodeKeys", [])
        if placement_set.get("placementCount") != 20 or len(nodes) != 20:
            errors.append(f"{placement_set.get('setId', 'unknown set')} must contain 20 placements")
        if len(nodes) != len(set(nodes)):
            errors.append(f"{placement_set.get('setId', 'unknown set')} contains duplicate source nodes")
        source_keys.update(nodes)
    if len(source_keys) != 100:
        errors.append("five placement sets must cover 100 distinct source nodes")

    timed_tasks = manifest.get("timedTasks", {})
    for task_name in ("firstOrganization", "fiveConversationOrganization"):
        if timed_tasks.get(task_name, {}).get("trialCount") != 20:
            errors.append(f"{task_name} must contain 20 trials")
    if manifest.get("retrieval", {}).get("minimumPostCommitTrials") != 20 or manifest.get("retrieval", {}).get("minimumPostRelaunchTrials") != 20:
        errors.append("retrieval must contain 20 post-commit and 20 post-relaunch trials")

    suggestion = manifest.get("suggestionEvaluation", {})
    if suggestion.get("acceptanceCorpusId") != "organizer-suggestion-v2":
        errors.append("suggestion acceptance corpus must be organizer-suggestion-v2")
    if suggestion.get("acceptanceArtifactStatus") not in {"pending", "passed"}:
        errors.append("suggestion v2 artifact status must be pending or passed")
    artifacts = suggestion.get("acceptanceArtifacts", {})
    expected_artifact_contract = {
        "inputSchemaVersion": "organizer-suggestion-input-v2",
        "goldSchemaVersion": "organizer-suggestion-gold-v2",
        "predictionSchemaVersion": "organizer-suggestion-predictions-v2",
        "inputKeyPolicy": "random-before-adjudication-v1",
        "inputContentPolicy": "synthetic-production-relevant-v1",
        "unrelatedOutcomePolicy": "correct-rejection-v1",
        "predictionInputBinding": "sha256-of-exact-input-artifact-bytes",
    }
    for field, expected in expected_artifact_contract.items():
        if artifacts.get(field) != expected:
            errors.append(f"suggestion artifact contract has the wrong {field}")
    expected_files = {
        "inputFile": "Tests/Fixtures/Organizer/suggestion-input-v2.json",
        "goldFile": "Tests/Fixtures/Organizer/suggestion-gold-v2.json",
        "predictionFile": "Tests/Fixtures/Organizer/suggestion-predictions-v2.json",
        "preparationRecordFile": "docs/acceptance/visual-email-organizer/results/suggestion-corpus-v2-preparation.json",
        "evaluationResultFile": "docs/acceptance/visual-email-organizer/results/suggestion-evaluation-v2.json",
    }
    for field, expected in expected_files.items():
        if artifacts.get(field) != expected:
            errors.append(f"suggestion artifact contract has the wrong {field}")
    legacy = suggestion.get("legacyHarnessCorpus", {})
    if legacy.get("corpusId") != "organizer-suggestion-gold-v1" or legacy.get("acceptanceEligible") is not False:
        errors.append("legacy suggestion v1 corpus must remain explicitly acceptance-ineligible")
    if suggestion.get("minimumCandidates", 0) < 200 or suggestion.get("minimumAcceptedOverall", 0) < 100:
        errors.append("suggestion denominator gates are below the contract")
    if suggestion.get("minimumQualifyingDecisionCountPerSlice", 0) < 25:
        errors.append("suggestion slice gate is below 25 qualifying decisions")
    if set(suggestion.get("requiredRelations", [])) != {"attach", "append", "unrelated"}:
        errors.append("suggestion relation slices are incomplete")
    expected_denominators = {
        "relation.attach": "acceptedPlacements",
        "relation.append": "acceptedPlacements",
        "relation.unrelated": "nonAbstainedDecisions",
        "confidenceBand.low": "acceptedPlacements",
        "confidenceBand.medium": "acceptedPlacements",
        "confidenceBand.high": "acceptedPlacements",
        "confidenceBand.very-high": "acceptedPlacements",
        "provenance.heuristic": "acceptedPlacements",
        "provenance.foundation-model": "acceptedPlacements",
    }
    if suggestion.get("sliceDenominators") != expected_denominators:
        errors.append("suggestion slice denominators do not match the negative-control contract")
    if set(suggestion.get("acceptedEvidenceOrigins", [])) != {"productionProvider", "frozenProductionPredictions"}:
        errors.append("suggestion evidence origins are incomplete")
    required_pin = {
        "corpusId", "provider", "modelVersion", "promptOrPolicyVersion", "strictness",
        "appBuild", "evidenceOrigin", "inputArtifactSHA256", "goldArtifactSHA256",
    }
    if set(suggestion.get("resultMustPin", [])) != required_pin:
        errors.append("suggestion result pin requirements are incomplete")
    if suggestion.get("overallPrecisionMinimum") != 0.80 or suggestion.get("conservativePrecisionMinimum") != 0.85:
        errors.append("suggestion precision gates do not match the contract")
    if suggestion.get("overallNonAbstainedCoverageMinimum") != 0.50:
        errors.append("suggestion coverage gate does not match the contract")

    expected_evidence = {
        "automated-logic",
        "build",
        "installed-app-launch",
        "live-pointer",
        "accessibility-audit",
        "timed-human-task",
    }
    if set(manifest.get("evidenceTypes", [])) != expected_evidence:
        errors.append("manifest evidence types are incomplete")
    return errors


def validate_suggestion_acceptance(repo_root: Path, manifest: dict) -> list[str]:
    errors: list[str] = []
    suggestion = manifest.get("suggestionEvaluation", {})
    artifacts = suggestion.get("acceptanceArtifacts", {})
    status = suggestion.get("acceptanceArtifactStatus")

    def artifact_path(field: str) -> Path:
        value = artifacts.get(field)
        return repo_root / value if isinstance(value, str) else repo_root / f"missing-{field}"

    input_path = artifact_path("inputFile")
    gold_path = artifact_path("goldFile")
    prediction_path = artifact_path("predictionFile")
    preparation_path = artifact_path("preparationRecordFile")
    result_path = artifact_path("evaluationResultFile")

    errors.extend(
        f"suggestion v2: {error}"
        for error in validate_suggestion_v2_files(input_path, gold_path, preparation_path)
    )

    if status == "pending":
        existing_acceptance_outputs = [
            path.name for path in (prediction_path, result_path) if path.exists()
        ]
        if existing_acceptance_outputs:
            errors.append(
                "suggestion v2 remains pending although acceptance output exists: "
                + ", ".join(existing_acceptance_outputs)
            )
        return errors

    if status != "passed":
        return errors
    for path in (prediction_path, result_path):
        if not path.exists():
            errors.append(f"suggestion v2 passed status is missing {path}")
    if errors:
        return errors

    input_artifact = load(input_path)
    prediction_artifact = load(prediction_path)
    result = load(result_path)
    candidates = input_artifact.get("candidates", [])
    predictions = prediction_artifact.get("predictions", [])
    input_digest = sha256_file(input_path)
    gold_digest = sha256_file(gold_path)
    prediction_digest = sha256_file(prediction_path)
    result_digest = sha256_file(result_path)

    expected_prediction_fields = {
        "schemaVersion", "corpusID", "inputArtifactSHA256", "pins", "predictions"
    }
    if set(prediction_artifact) != expected_prediction_fields:
        errors.append("suggestion prediction artifact has an unexpected top-level field contract")
    if prediction_artifact.get("schemaVersion") != artifacts.get("predictionSchemaVersion"):
        errors.append("suggestion prediction schema version does not match the manifest")
    if prediction_artifact.get("corpusID") != suggestion.get("acceptanceCorpusId"):
        errors.append("suggestion prediction corpus does not match the manifest")
    if prediction_artifact.get("inputArtifactSHA256") != input_digest:
        errors.append("suggestion predictions are not bound to the exact input bytes")

    pins = prediction_artifact.get("pins", {})
    expected_pin_fields = {
        "corpusID", "provider", "modelVersion", "promptOrPolicyVersion",
        "strictness", "appBuild", "evidenceOrigin",
    }
    if set(pins) != expected_pin_fields:
        errors.append("suggestion prediction version pins are incomplete")
    if pins.get("corpusID") != suggestion.get("acceptanceCorpusId"):
        errors.append("suggestion prediction pin has the wrong corpus")
    if pins.get("strictness") != "conservative":
        errors.append("suggestion acceptance predictions must pin conservative strictness")
    if pins.get("evidenceOrigin") not in suggestion.get("acceptedEvidenceOrigins", []):
        errors.append("suggestion predictions do not have an acceptance-eligible evidence origin")
    for field in ("provider", "modelVersion", "promptOrPolicyVersion", "appBuild"):
        if not isinstance(pins.get(field), str) or not pins[field]:
            errors.append(f"suggestion prediction pin {field} is empty")

    expected_prediction_record_fields = {"candidateKey", "sourceKey", "decision"}
    optional_prediction_record_fields = {"proposedDestinationKey"}
    input_identities = {
        (candidate.get("candidateKey"), candidate.get("sourceKey")) for candidate in candidates
    }
    prediction_identities: set[tuple[object, object]] = set()
    for index, prediction in enumerate(predictions):
        fields = set(prediction)
        if not expected_prediction_record_fields.issubset(fields) or not fields.issubset(
            expected_prediction_record_fields | optional_prediction_record_fields
        ):
            errors.append(f"suggestion prediction {index} has an invalid field contract")
        identity = (prediction.get("candidateKey"), prediction.get("sourceKey"))
        if identity in prediction_identities:
            errors.append(f"suggestion prediction {index} duplicates an effective source")
        prediction_identities.add(identity)
        decision = prediction.get("decision")
        destination = prediction.get("proposedDestinationKey")
        if decision == "accepted" and not isinstance(destination, str):
            errors.append(f"suggestion prediction {index} accepts without a destination")
        elif decision in {"rejected", "abstained"} and destination is not None:
            errors.append(f"suggestion prediction {index} has a destination for {decision}")
        elif decision not in {"accepted", "rejected", "abstained"}:
            errors.append(f"suggestion prediction {index} has an unknown decision")
    if prediction_identities != input_identities or len(predictions) != len(candidates):
        errors.append("suggestion predictions are not an exact one-to-one input match")

    if result.get("schemaVersion") != "organizer-suggestion-evaluation-v1":
        errors.append("suggestion evaluation has the wrong schema version")
    if result.get("status") != "pass" or result.get("issueCodes") != []:
        errors.append("suggestion evaluation is not a clean pass")
    if result.get("pins") != pins:
        errors.append("suggestion evaluation pins differ from the prediction artifact")
    corpus_quality = result.get("corpusQuality", {})
    if corpus_quality.get("corpusID") != suggestion.get("acceptanceCorpusId"):
        errors.append("suggestion evaluation corpus quality has the wrong corpus")
    if corpus_quality.get("inputArtifactSHA256") != input_digest:
        errors.append("suggestion evaluation has the wrong input digest")
    if corpus_quality.get("goldArtifactSHA256") != gold_digest:
        errors.append("suggestion evaluation has the wrong gold digest")
    if corpus_quality.get("hasProductionRelevantInputs") is not True:
        errors.append("suggestion evaluation did not validate production-relevant input")
    if corpus_quality.get("keysAreOpaqueAndLabelIndependent") is not True:
        errors.append("suggestion evaluation did not validate opaque label-independent keys")

    candidate_count = result.get("candidateCount", 0)
    accepted_count = result.get("acceptedCount", 0)
    precision = result.get("precision")
    coverage = result.get("coverage")
    if candidate_count != len(candidates) or candidate_count < suggestion.get("minimumCandidates", 0):
        errors.append("suggestion evaluation candidate denominator is insufficient")
    if result.get("rawPredictionCount") != len(predictions):
        errors.append("suggestion evaluation raw prediction count is incorrect")
    if accepted_count < suggestion.get("minimumAcceptedOverall", 0):
        errors.append("suggestion evaluation accepted denominator is insufficient")
    required_precision = max(
        suggestion.get("overallPrecisionMinimum", 0),
        suggestion.get("conservativePrecisionMinimum", 0),
    )
    if not isinstance(precision, (int, float)) or precision < required_precision:
        errors.append("suggestion evaluation conservative precision is below the gate")
    if not isinstance(coverage, (int, float)) or coverage < suggestion.get(
        "overallNonAbstainedCoverageMinimum", 0
    ):
        errors.append("suggestion evaluation coverage is below the gate")
    for field in (
        "duplicateGoldSourceCount", "duplicatePredictionSourceCount",
        "conflictingSourceCount", "unmatchedPredictionCount",
    ):
        if result.get(field) != 0:
            errors.append(f"suggestion evaluation {field} must be zero")

    expected_slices = {
        ("relation", "attach"),
        ("relation", "append"),
        ("relation", "unrelated"),
        *(('confidenceBand', value) for value in suggestion.get("requiredConfidenceBands", [])),
        *(('provenance', value) for value in suggestion.get("requiredProvenance", [])),
    }
    slices = result.get("slices", [])
    actual_slices = {(entry.get("dimension"), entry.get("value")) for entry in slices}
    if actual_slices != expected_slices or len(slices) != len(expected_slices):
        errors.append("suggestion evaluation slices are incomplete")
    denominator_contract = suggestion.get("sliceDenominators", {})
    for entry in slices:
        key = f"{entry.get('dimension')}.{entry.get('value')}"
        if entry.get("denominator") != denominator_contract.get(key):
            errors.append(f"suggestion evaluation slice {key} has the wrong denominator")
        if entry.get("qualifyingDecisionCount", 0) < suggestion.get(
            "minimumQualifyingDecisionCountPerSlice", 0
        ):
            errors.append(f"suggestion evaluation slice {key} has an insufficient denominator")

    pinned_digests = {
        "inputArtifactSHA256": input_digest,
        "goldArtifactSHA256": gold_digest,
        "predictionArtifactSHA256": prediction_digest,
        "evaluationResultSHA256": result_digest,
    }
    for field, expected in pinned_digests.items():
        if artifacts.get(field) != expected:
            errors.append(f"suggestion manifest does not pin the exact {field}")
    return errors


def normalized_field_name(value: str) -> str:
    return "".join(character.lower() for character in value if character.isalnum())


def nested_field_names(value: object, location: str = "$") -> list[tuple[str, str]]:
    fields: list[tuple[str, str]] = []
    if isinstance(value, dict):
        for key, child in value.items():
            child_location = f"{location}.{key}"
            fields.append((str(key), child_location))
            fields.extend(nested_field_names(child, child_location))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            fields.extend(nested_field_names(child, f"{location}[{index}]"))
    return fields


def validate_result_privacy(path: Path, artifact: dict, metric_schema: dict) -> list[str]:
    forbidden = {
        normalized_field_name(field)
        for field in metric_schema.get("privacyForbiddenFields", [])
    }
    return [
        f"{path.name}: privacy-forbidden field {field!r} at {location}"
        for field, location in nested_field_names(artifact)
        if normalized_field_name(field) in forbidden
    ]


RESULT_SCHEMA_VERSIONS = {
    "visual-email-organizer-metrics-v1",
    "visual-email-organizer-acceptance-status-v1",
    "organizer-suggestion-corpus-preparation-v1",
    "organizer-suggestion-evaluation-v1",
}

TASK_IDS = {
    "diagnostic",
    "live-pointer",
    "placement-set",
    "first-organization",
    "five-conversation-organization",
    "retrieval",
}

TIMED_TASK_IDS = {
    "first-organization",
    "five-conversation-organization",
    "retrieval",
}

EVENT_KINDS = {
    "workspace-ready", "task-visible", "task-ready", "search-start",
    "action-start", "selection", "drop-intent", "drop-highlight",
    "drop-release", "drop-outcome", "group-committed", "bettermail-commit",
    "group-rethreaded", "rethread-complete", "group-visible", "visible-result",
    "suggestion-decision", "mail-authorization", "mail-result", "undo",
    "recovery", "retrieval-visible", "cancelled", "failure",
}

COARSE_FAILURE_REASONS = {
    "instrumentation-before-task-ready", "cancelled", "action-failure",
    "wrong-completion", "app-termination", "missing-rethread",
    "missing-visible-confirmation", "missing-retrieval", "unresolved-outcome",
    "invalid-target",
}

TARGET_OUTCOME_BY_TASK = {
    "diagnostic": "accessibility",
    "live-pointer": "pointer-drop",
    "placement-set": "placement",
    "first-organization": "organization",
    "five-conversation-organization": "organization",
    "retrieval": "retrieval",
}

PASS_REQUIRED_EVENT_SEQUENCE_BY_TASK = {
    "diagnostic": [
        "workspace-ready", "task-visible", "task-ready", "selection",
    ],
    "live-pointer": [
        "workspace-ready", "task-visible", "task-ready", "action-start",
        "drop-intent", "drop-highlight", "drop-release", "drop-outcome",
    ],
    "placement-set": [
        "workspace-ready", "task-visible", "task-ready", "action-start",
        "drop-intent", "drop-highlight", "drop-release", "bettermail-commit",
        "rethread-complete", "group-visible", "visible-result",
    ],
    "first-organization": [
        "workspace-ready", "task-visible", "task-ready", "action-start",
        "bettermail-commit", "rethread-complete", "group-visible",
        "visible-result",
    ],
    "five-conversation-organization": [
        "workspace-ready", "task-visible", "task-ready", "action-start",
        "bettermail-commit", "rethread-complete", "group-visible",
        "visible-result", "search-start", "retrieval-visible",
    ],
    "retrieval": [
        "workspace-ready", "task-visible", "task-ready", "search-start",
        "retrieval-visible",
    ],
}


def unexpected_fields(value: dict, allowed: set[str]) -> list[str]:
    return sorted(set(value) - allowed) if isinstance(value, dict) else []


def frozen_task_contract(task_id: str) -> tuple[list[str], list[str], object] | None:
    if task_id == "diagnostic":
        return [], [], None
    if task_id == "first-organization":
        return ["node-100-0000"], ["group-flat-00"], None
    if task_id == "five-conversation-organization":
        return (
            [f"node-100-{index:04d}" for index in range(5)],
            ["group-flat-00", "group-flat-01", "group-nested-00", "group-nested-01", "group-flat-02"],
            "synthetic-query-organized-0004",
        )
    if task_id == "retrieval":
        return ["node-100-0004"], ["group-flat-02"], "synthetic-query-organized-0004"
    return None


def valid_placement_contract(record: dict) -> bool:
    sources = record.get("sourceNodeKeys")
    destinations = record.get("destinationGroupKeys")
    if not isinstance(sources, list) or not isinstance(destinations, list):
        return False
    frozen = [
        ([f"node-500-{index:04d}" for index in range(start, start + 20)], destination)
        for start, destination in (
            (0, "group-flat-00"),
            (20, "group-flat-01"),
            (40, "group-nested-00"),
            (60, "group-nested-01"),
            (80, "group-flat-02"),
        )
    ]
    return any(sources == expected and destinations == [destination] for expected, destination in frozen)


def validate_trial_contract(prefix: str, index: int, record: dict, evidence_type: str) -> list[str]:
    errors: list[str] = []
    task_id = record.get("taskId")
    if task_id not in TASK_IDS:
        return [f"{prefix} record {index} has invalid taskId"]
    expected_evidence = (
        {"timed-human-task"} if task_id in TIMED_TASK_IDS
        else {"live-pointer"} if task_id in {"live-pointer", "placement-set"}
        else {"automated-logic", "build", "installed-app-launch", "accessibility-audit"}
    )
    if evidence_type not in expected_evidence:
        errors.append(f"{prefix} record {index} evidenceType does not match taskId")
    if not is_safe_identifier(record.get("trialId"), ("synthetic-",)):
        errors.append(f"{prefix} record {index} trialId is not a synthetic key")
    if record.get("stratum") not in {
        "warm", "cold-relaunch", "aggregate", "post-commit", "post-relaunch"
    }:
        errors.append(f"{prefix} record {index} has an invalid stratum")
    if not isinstance(record.get("mailCallCount"), int) or record.get("mailCallCount", -1) < 0:
        errors.append(f"{prefix} record {index} has an invalid mailCallCount")
    if not isinstance(record.get("normalizedCommandCount"), int) or record.get("normalizedCommandCount", -1) < 0:
        errors.append(f"{prefix} record {index} has an invalid normalizedCommandCount")
    if record.get("targetOutcome") != TARGET_OUTCOME_BY_TASK[task_id]:
        errors.append(f"{prefix} record {index} targetOutcome does not match taskId")
    contract = frozen_task_contract(task_id)
    if contract is not None:
        sources, destinations, query = contract
        if record.get("sourceNodeKeys") != sources:
            errors.append(f"{prefix} record {index} sourceNodeKeys do not match the frozen task")
        if record.get("destinationGroupKeys") != destinations:
            errors.append(f"{prefix} record {index} destinationGroupKeys do not match the frozen task")
        if record.get("queryKey") != query:
            errors.append(f"{prefix} record {index} queryKey does not match the frozen task")
    elif task_id == "placement-set" and not valid_placement_contract(record):
        errors.append(f"{prefix} record {index} does not pin one frozen placement set")
    elif task_id == "live-pointer" and (
        record.get("sourceNodeKeys") != []
        or record.get("destinationGroupKeys") != []
        or record.get("queryKey") is not None
    ):
        errors.append(f"{prefix} live-pointer record {index} must not invent a fixed placement")
    return errors


def validate_event_summary(prefix: str, events: object, require_runtime_fields: bool) -> list[str]:
    errors: list[str] = []
    if not isinstance(events, list):
        return [f"{prefix} eventSummary must be an array"]
    allowed = {
        "sequence", "event", "phase", "stratum", "count", "status",
        "offsetMilliseconds", "durationMilliseconds",
    }
    required = {"sequence", "event", "count"}
    if require_runtime_fields:
        required |= {"phase", "offsetMilliseconds"}
    last_offset = -1
    event_counts: dict[str, int] = {}
    for index, event in enumerate(events):
        if not isinstance(event, dict):
            errors.append(f"{prefix} event {index} must be an object")
            continue
        unknown = unexpected_fields(event, allowed)
        if unknown:
            errors.append(f"{prefix} event {index} has unknown fields: {', '.join(unknown)}")
        missing = sorted(required - set(event))
        if missing:
            errors.append(f"{prefix} event {index} missing fields: {', '.join(missing)}")
        if event.get("sequence") != index + 1:
            errors.append(f"{prefix} event sequence must be contiguous from one")
        kind = event.get("event")
        if kind not in EVENT_KINDS:
            errors.append(f"{prefix} event {index} has an unknown event kind")
            continue
        if not isinstance(event.get("count"), int) or event.get("count", 0) <= 0:
            errors.append(f"{prefix} event {index} count must be positive")
        if "status" in event and event.get("status") not in {"success", "failure", "invalid", "cancelled"}:
            errors.append(f"{prefix} event {index} has an invalid outcome")
        if require_runtime_fields:
            if event.get("phase") not in {"instant", "started", "finished"}:
                errors.append(f"{prefix} event {index} has an invalid phase")
            offset = event.get("offsetMilliseconds")
            if not isinstance(offset, int) or offset < 0 or offset < last_offset:
                errors.append(f"{prefix} event offsets must be nonnegative and monotonic")
            elif isinstance(offset, int):
                last_offset = offset
            duration = event.get("durationMilliseconds")
            if duration is not None and (not isinstance(duration, int) or duration < 0):
                errors.append(f"{prefix} event {index} has an invalid duration")

        count = event_counts.get
        if kind in {"workspace-ready", "task-visible", "task-ready", "search-start"} \
                and count(kind, 0) > 0:
            errors.append(f"{prefix} {kind} must occur exactly once")
        if kind == "task-visible" and count("workspace-ready", 0) != 1:
            errors.append(f"{prefix} task-visible occurs before workspace-ready")
        if kind == "task-ready" and (
            count("workspace-ready", 0) != 1 or count("task-visible", 0) != 1
        ):
            errors.append(f"{prefix} task-ready occurs before workspace and task visibility")
        if kind in {"action-start", "search-start"} and count("task-ready", 0) != 1:
            errors.append(f"{prefix} {kind} occurs before task-ready")
        if kind == "drop-intent" and count("action-start", 0) <= count("drop-intent", 0):
            errors.append(f"{prefix} drop intent lacks a preceding action")
        if kind == "drop-highlight" and count("drop-intent", 0) == 0:
            errors.append(f"{prefix} drop highlight lacks a preceding intent")
        if kind == "drop-release" and count("drop-intent", 0) <= count("drop-release", 0):
            errors.append(f"{prefix} drop release lacks a preceding intent")
        if kind == "drop-outcome" and count("drop-release", 0) <= count("drop-outcome", 0):
            errors.append(f"{prefix} drop outcome lacks a preceding release")
        if kind == "bettermail-commit" and count("action-start", 0) <= count("bettermail-commit", 0):
            errors.append(f"{prefix} BetterMail commit lacks a preceding action")
        if kind == "rethread-complete" and count("bettermail-commit", 0) <= count("rethread-complete", 0):
            errors.append(f"{prefix} rethread completion lacks a preceding commit")
        if kind == "visible-result" and count("rethread-complete", 0) <= count("visible-result", 0):
            errors.append(f"{prefix} visible result lacks a preceding rethread completion")
        if kind == "group-visible" and count("rethread-complete", 0) <= count("group-visible", 0):
            errors.append(f"{prefix} group visibility lacks a preceding rethread completion")
        if kind == "retrieval-visible" and count("search-start", 0) != 1:
            errors.append(f"{prefix} retrieval visibility lacks a preceding search start")
        event_counts[kind] = event_counts.get(kind, 0) + 1
    return errors


def validate_metric_result(path: Path, artifact: dict, metric_schema: dict) -> list[str]:
    errors: list[str] = []
    prefix = f"{path.name}:"
    allowed_top = {
        "schemaVersion", "runId", "fixtureId", "protocolId", "appBuild",
        "evidenceType", "generatedAt", "status", "records", "eventSummary",
        "timing", "drops", "wrongPlacements", "suggestions",
    }
    unknown_top = unexpected_fields(artifact, allowed_top)
    if unknown_top:
        errors.append(f"{prefix} unknown top-level fields: {', '.join(unknown_top)}")
    required = allowed_top
    missing = sorted(required - set(artifact))
    if missing:
        errors.append(f"{prefix} missing required run fields: {', '.join(missing)}")

    statuses = set(metric_schema.get("statusValues", []))
    evidence_types = set(metric_schema.get("evidenceTypes", []))
    if artifact.get("status") not in statuses:
        errors.append(f"{prefix} invalid status")
    evidence_type = artifact.get("evidenceType")
    if evidence_type not in evidence_types:
        errors.append(f"{prefix} invalid evidenceType")
    if not is_safe_identifier(artifact.get("runId"), ("synthetic-",)):
        errors.append(f"{prefix} runId is not a synthetic key")
    if not is_safe_identifier(artifact.get("fixtureId"), ("fixture-", "organizer-")):
        errors.append(f"{prefix} fixtureId is invalid")
    if not is_safe_identifier(
        artifact.get("protocolId"), ("protocol-", "visual-email-organizer-")
    ):
        errors.append(f"{prefix} protocolId is invalid")
    if not is_safe_identifier(artifact.get("appBuild"), ("build-", "synthetic-")):
        errors.append(f"{prefix} appBuild is invalid")

    records = artifact.get("records")
    if not isinstance(records, list):
        errors.append(f"{prefix} records must be an array")
        return errors
    if artifact.get("status") == "pending" and any(
        isinstance(record, dict) and record.get("status") == "pass"
        for record in records
    ):
        errors.append(f"{prefix} pending artifact must not contain passing trial records")

    required_trial_fields = {
        "trialId",
        "taskId",
        "sourceNodeKeys",
        "destinationGroupKeys",
        "stratum",
        "status",
        "eventSummary",
        "targetOutcome",
        "mailCallCount",
        "normalizedCommandCount",
    }
    allowed_trial_fields = required_trial_fields | {
        "queryKey", "durationMilliseconds", "coarseFailureReason",
    }
    if artifact.get("status") != "pending" and len(records) != 1:
        errors.append(f"{prefix} a non-pending run must contain exactly one aggregate trial record")
    elif len(records) > 1:
        errors.append(f"{prefix} one run must contain exactly one aggregate trial record")
    for index, record in enumerate(records):
        if not isinstance(record, dict):
            errors.append(f"{prefix} record {index} must be an object")
            continue
        missing_trial = sorted(required_trial_fields - set(record))
        if missing_trial:
            errors.append(
                f"{prefix} record {index} missing fields: {', '.join(missing_trial)}"
            )
        unknown_trial = unexpected_fields(record, allowed_trial_fields)
        if unknown_trial:
            errors.append(f"{prefix} record {index} has unknown fields: {', '.join(unknown_trial)}")
        errors.extend(validate_trial_contract(prefix, index, record, evidence_type))
        if not isinstance(record.get("sourceNodeKeys"), list):
            errors.append(f"{prefix} record {index} sourceNodeKeys must be an array")
        if not isinstance(record.get("destinationGroupKeys"), list):
            errors.append(f"{prefix} record {index} destinationGroupKeys must be an array")
        if (
            "queryKey" in record
            and record.get("queryKey") is not None
            and not isinstance(record.get("queryKey"), str)
        ):
            errors.append(f"{prefix} record {index} queryKey must be a string or null")
        if record.get("status") not in statuses:
            errors.append(f"{prefix} record {index} has invalid status")
        if record.get("status") in {"fail", "invalid"} and record.get("coarseFailureReason") not in COARSE_FAILURE_REASONS:
            errors.append(f"{prefix} failed record {index} lacks a coarse failure reason")
        if record.get("status") == "pass" and record.get("taskId") in TIMED_TASK_IDS:
            duration = record.get("durationMilliseconds")
            if not isinstance(duration, int) or duration < 0:
                errors.append(f"{prefix} passing timed record {index} lacks a duration")
        errors.extend(validate_event_summary(
            f"{prefix} record {index}", record.get("eventSummary"), True
        ))

    errors.extend(validate_event_summary(f"{prefix} top-level", artifact.get("eventSummary"), True))
    if artifact.get("status") == "pass":
        passing_record = records[0] if len(records) == 1 and isinstance(records[0], dict) else {}
        if passing_record.get("status") != "pass":
            errors.append(f"{prefix} passing artifact requires a passing aggregate trial record")
        record_events = passing_record.get("eventSummary")
        top_level_events = artifact.get("eventSummary")
        if not isinstance(record_events, list) or not record_events:
            errors.append(f"{prefix} passing artifact requires a nonempty record eventSummary")
        if not isinstance(top_level_events, list) or not top_level_events:
            errors.append(f"{prefix} passing artifact requires a nonempty top-level eventSummary")
        if isinstance(record_events, list) and isinstance(top_level_events, list):
            if record_events != top_level_events:
                errors.append(f"{prefix} passing artifact eventSummary copies do not match")
            required_event_sequence = PASS_REQUIRED_EVENT_SEQUENCE_BY_TASK.get(
                passing_record.get("taskId"), []
            )
            required_event_kinds = set(required_event_sequence)
            if passing_record.get("taskId") == "placement-set":
                # A placement outcome is authoritative only after the async
                # mutation returns. Rendering may close before or after that
                # return, so enforce both valid branches independently:
                # release -> outcome and commit -> rethread -> visible.
                required_event_kinds.add("drop-outcome")
            observed_events = [
                event for event in record_events if isinstance(event, dict)
            ]
            observed_event_kinds = {event.get("event") for event in observed_events}
            missing_event_kinds = sorted(
                required_event_kinds - observed_event_kinds
            )
            if missing_event_kinds:
                errors.append(
                    f"{prefix} passing artifact is missing required lifecycle events: "
                    + ", ".join(missing_event_kinds)
                )
            sequence_cursor = 0
            for required_event in required_event_sequence:
                while (
                    sequence_cursor < len(observed_events)
                    and observed_events[sequence_cursor].get("event") != required_event
                ):
                    sequence_cursor += 1
                if sequence_cursor == len(observed_events):
                    if required_event not in missing_event_kinds:
                        errors.append(
                            f"{prefix} passing artifact lifecycle events are out of order"
                        )
                    break
                sequence_cursor += 1
            if any(
                event.get("event") in {"cancelled", "failure"}
                or event.get("status") in {"failure", "invalid", "cancelled"}
                for event in observed_events
            ):
                errors.append(f"{prefix} passing artifact contains a failed lifecycle event")
    collection_fields = {
        "timing": {
            "kind", "stratum", "sampleCount", "validTrialCount", "successCount",
            "failureCount", "invalidCount", "cancelledCount", "medianMilliseconds",
            "p80Milliseconds", "p90Milliseconds", "thresholdMilliseconds",
            "withinThresholdCount", "withinThresholdRate", "minimumWithinThresholdRate", "status",
        },
        "drops": {
            "source", "stratum", "attemptCount", "successCount",
            "invalidTargetMutationCount", "successRate", "minimumSuccessRate", "status",
        },
        "wrongPlacements": {
            "stratum", "setCount", "totalAttemptCount", "totalWrongPlacementCount",
            "maximumWrongPlacementCountPerSet", "minimumSetCount",
            "maximumWrongPlacementCountPerSetThreshold", "sets", "status",
        },
        "suggestions": {
            "strictness", "candidateCount", "acceptedCount", "correctAcceptedCount",
            "nonAbstainedCount", "precision", "coverage", "minimumCandidateCount",
            "minimumAcceptedCount", "minimumDecisionCountPerSlice", "minimumPrecision",
            "minimumCoverage", "slices", "status",
        },
    }
    for field, allowed_fields in collection_fields.items():
        entries = artifact.get(field)
        if not isinstance(entries, list):
            errors.append(f"{prefix} {field} must be an array")
            continue
        for index, entry in enumerate(entries):
            if not isinstance(entry, dict):
                errors.append(f"{prefix} {field} entry {index} must be an object")
                continue
            unknown = unexpected_fields(entry, allowed_fields)
            if unknown:
                errors.append(f"{prefix} {field} entry {index} has unknown fields: {', '.join(unknown)}")
            if entry.get("status") not in statuses:
                errors.append(f"{prefix} {field} entry {index} has invalid status")
            if field == "timing" and entry.get("status") == "pass":
                kind = entry.get("kind")
                minimum = 20 if kind == "retrieval" else 10
                limit = {"firstAction": 30_000, "fiveConversation": 120_000, "retrieval": 5_000}.get(kind)
                if entry.get("validTrialCount", 0) < minimum:
                    errors.append(f"{prefix} passing timing entry {index} lacks its denominator")
                if not isinstance(entry.get("p80Milliseconds"), int) or limit is None or entry["p80Milliseconds"] > limit:
                    errors.append(f"{prefix} passing timing entry {index} exceeds its P80 limit")
                if not isinstance(entry.get("medianMilliseconds"), int) or not isinstance(entry.get("p90Milliseconds"), int):
                    errors.append(f"{prefix} passing timing entry {index} lacks median or P90")
                if kind == "retrieval" and entry.get("withinThresholdRate", 0) < 0.95:
                    errors.append(f"{prefix} passing retrieval entry {index} is below 95 percent")
            if field == "wrongPlacements" and entry.get("status") == "pass":
                sets = entry.get("sets")
                if not isinstance(sets, list) or len(sets) != 5:
                    errors.append(f"{prefix} passing placement summary {index} lacks five sets")
                elif any(
                    not isinstance(item, dict)
                    or set(item) != {"setId", "attemptCount", "wrongPlacementCount"}
                    or item.get("attemptCount") != 20
                    or item.get("wrongPlacementCount", 99) > 1
                    for item in sets
                ):
                    errors.append(f"{prefix} passing placement summary {index} has an invalid set")
            if field == "wrongPlacements":
                sets = entry.get("sets")
                if not isinstance(sets, list) or any(
                    not isinstance(item, dict)
                    or set(item) != {"setId", "attemptCount", "wrongPlacementCount"}
                    or not is_safe_identifier(item.get("setId"), ("placement-set-",))
                    or not isinstance(item.get("attemptCount"), int)
                    or not isinstance(item.get("wrongPlacementCount"), int)
                    for item in sets
                ):
                    errors.append(f"{prefix} placement summary {index} has an unsafe nested set contract")
            if field == "suggestions":
                slices = entry.get("slices")
                allowed_slice_fields = {
                    "slice", "candidateCount", "acceptedCount", "correctAcceptedCount",
                    "nonAbstainedCount", "denominator", "qualifyingDecisionCount",
                    "minimumQualifyingDecisionCount",
                }
                if not isinstance(slices, list) or any(
                    not isinstance(item, dict) or set(item) != allowed_slice_fields
                    for item in slices
                ):
                    errors.append(f"{prefix} suggestion summary {index} has an unsafe nested slice contract")
    if artifact.get("status") == "pass" and evidence_type == "timed-human-task":
        primary_kind_by_task = {
            "first-organization": "firstAction",
            "five-conversation-organization": "fiveConversation",
            "retrieval": "retrieval",
        }
        passing_record = records[0] if len(records) == 1 and isinstance(records[0], dict) else {}
        required_kind = primary_kind_by_task.get(passing_record.get("taskId"))
        required_stratum = passing_record.get("stratum")
        timing_entries = artifact.get("timing") if isinstance(artifact.get("timing"), list) else []
        if required_kind is None or not any(
            isinstance(entry, dict)
            and entry.get("kind") == required_kind
            and entry.get("stratum") == required_stratum
            and entry.get("status") == "pass"
            for entry in timing_entries
        ):
            errors.append(
                f"{prefix} passing timed artifact lacks required aggregate timing evidence"
            )
    return errors


def validate_acceptance_status(
    path: Path,
    artifact: dict,
    metric_schema: dict,
    status_schema: dict,
) -> list[str]:
    errors: list[str] = []
    prefix = f"{path.name}:"
    statuses = set(metric_schema.get("statusValues", []))
    evidence_types = set(metric_schema.get("evidenceTypes", []))
    allowed_top = set(status_schema.get("requiredFields", [])) | {"invalidTrialReasonCode"}
    unknown_top = unexpected_fields(artifact, allowed_top)
    if unknown_top:
        errors.append(f"{prefix} unknown top-level fields: {', '.join(unknown_top)}")
    missing = sorted((set(status_schema.get("requiredFields", [])) | {"invalidTrialReasonCode"}) - set(artifact))
    if missing:
        errors.append(f"{prefix} missing status-summary fields: {', '.join(missing)}")
    if artifact.get("artifactKind") != "acceptance-status":
        errors.append(f"{prefix} artifactKind must be acceptance-status")
    if artifact.get("status") not in statuses:
        errors.append(f"{prefix} invalid status")
    if not is_safe_identifier(artifact.get("runId"), ("synthetic-",)):
        errors.append(f"{prefix} runId is not a safe synthetic key")
    if not is_safe_identifier(artifact.get("fixtureId"), ("fixture-", "organizer-")):
        errors.append(f"{prefix} fixtureId is invalid")
    if not is_safe_identifier(
        artifact.get("protocolId"), ("protocol-", "visual-email-organizer-")
    ):
        errors.append(f"{prefix} protocolId is invalid")
    if not is_safe_identifier(artifact.get("appBuild"), ("build-", "synthetic-")):
        errors.append(f"{prefix} appBuild is invalid")

    records = artifact.get("records")
    if not isinstance(records, list):
        errors.append(f"{prefix} records must be an array")
    else:
        allowed_record_fields = {
            "trialId", "appBuild", "evidenceType", "taskId", "sourceNodeKeys",
            "destinationGroupKeys", "queryKey", "stratum", "status",
            "durationMilliseconds", "coarseFailureReason", "targetOutcome",
            "mailCallCount", "normalizedCommandCount", "eventSummary", "observed",
            "diagnosticOnly",
        }
        for index, record in enumerate(records):
            if not isinstance(record, dict):
                errors.append(f"{prefix} record {index} must be an object")
                continue
            unknown_record = unexpected_fields(record, allowed_record_fields)
            if unknown_record:
                errors.append(f"{prefix} record {index} has unknown fields: {', '.join(unknown_record)}")
            if record.get("evidenceType") not in evidence_types:
                errors.append(f"{prefix} record {index} must declare one evidenceType")
            if not is_safe_identifier(record.get("appBuild"), ("build-", "synthetic-")):
                errors.append(f"{prefix} record {index} must declare a safe appBuild")
            errors.extend(validate_trial_contract(
                prefix, index, record, record.get("evidenceType")
            ))
            if record.get("status") not in statuses:
                errors.append(f"{prefix} record {index} has invalid status")
            if record.get("status") in {"fail", "invalid"} and record.get("coarseFailureReason") not in COARSE_FAILURE_REASONS:
                errors.append(f"{prefix} failed record {index} lacks a coarse failure reason")
            if "eventSummary" in record:
                errors.extend(validate_event_summary(
                    f"{prefix} record {index}", record.get("eventSummary"), False
                ))
            observed = record.get("observed")
            observed_vocabulary = {
                "ready-banner", "persisted-group", "stable-opaque-group-identifier",
                "history-count", "expanded-rail", "collapsed-rail",
                "graph-controls-unobstructed", "mode-migration",
                "rail-canvas-selection-synchronization", "frozen-query-search",
                "single-selection", "multi-selection", "live-lasso",
                "native-pointer-drag-and-drop", "empty-canvas-pointer-group-creation",
                "cold-relaunch-persistence", "suggestion-review-mutation",
                "suggestion-surface-and-effect-labels-read-only", "benchmark-mail-lock",
                "authorized-mail-mutation", "live-undo-and-recovery",
                "focused-keyboard-navigation", "narrow-width-layout",
                "installed-spritekit-button-role-and-screen-frame",
                "VoiceOver-session-operation", "opaque-stable-identifiers",
                "labels-hints-stable-identifiers-and-secondary-actions",
                "no-bottom-overlay-obstruction",
            }
            if observed is not None and (
                not isinstance(observed, list)
                or not all(value in observed_vocabulary for value in observed)
            ):
                errors.append(f"{prefix} record {index} observed must be fixed-vocabulary strings")
            diagnostic = record.get("diagnosticOnly")
            if diagnostic is not None:
                if not isinstance(diagnostic, dict) or set(diagnostic) != {
                    "agentAssisted", "humanTimingEligible", "retrievalDurationMilliseconds"
                }:
                    errors.append(f"{prefix} record {index} has an invalid diagnosticOnly contract")
                elif (
                    diagnostic.get("agentAssisted") is not True
                    or diagnostic.get("humanTimingEligible") is not False
                    or not isinstance(diagnostic.get("retrievalDurationMilliseconds"), int)
                    or diagnostic.get("retrievalDurationMilliseconds", -1) < 0
                ):
                    errors.append(f"{prefix} record {index} has invalid diagnostic-only values")

    gates = artifact.get("gateStatus")
    if not isinstance(gates, dict):
        errors.append(f"{prefix} gateStatus must be an object")
        return errors

    hard_gates = set(status_schema.get("hardGates", []))
    missing_gates = sorted(hard_gates - set(gates))
    unknown_gates = sorted(set(gates) - hard_gates)
    if missing_gates:
        errors.append(f"{prefix} missing hard gates: {', '.join(missing_gates)}")
    if unknown_gates:
        errors.append(f"{prefix} unknown gates: {', '.join(unknown_gates)}")
    allowed_gate_fields = {
        "signingAndInstall": {
            "status", "certificateSHA1", "certificateDisplayUID", "expectedTeamIdentifier",
            "appTeamIdentifier", "extensionTeamIdentifier", "appSignature", "extensionSignature",
            "appLeafCertificateSHA1", "extensionLeafCertificateSHA1", "appCertificateChainTrust",
            "extensionCertificateChainTrust", "appDeepStrictVerification",
            "extensionDeepStrictVerification", "bundleIdentifiersPreserved", "entitlementsPreserved",
            "appBundleIdentifier", "extensionBundleIdentifier",
            "installedEntitlementsMatchBuildProduct", "projectSigningFilesPreserved", "adHocFallbackUsed",
        },
        "keychainPromptRecurrence": {
            "status", "normalInstalledLaunchCount", "graphSpatialPromptObservedCount",
            "securityAgentObservedCount", "verificationMethods",
        },
        "productionEventBoundaries": {
            "status", "installedRun", "groupVisibleCount", "visibleResultCount",
        },
        "deterministicDropMatrix": {"status", "attemptCount", "failedAttemptCount", "strata"},
        "installedPointerDrops": {"status", "attemptCount", "failedAttemptCount", "coverage", "reasonCode"},
        "installedPlacementSets": {
            "status", "setCount", "adjudicatedPlacementCount", "wrongBetterMailPlacementCount",
            "wrongAppleMailRouteCount", "maximumWrongPlacementCountPerSet", "sets",
        },
        "suggestionQuality": {
            "status", "candidateCount", "acceptedCount", "correctAcceptedCount",
            "falsePositiveCount", "falseNegativeCount", "precision", "coverage", "sourceArtifact",
        },
        "unauthorizedMailInvariant": {"status", "externalMailCallCount"},
        "timedHumanTasks": {
            "status", "validFirstOrganizationTrials", "validFiveConversationTrials",
            "validPostCommitRetrievalTrials", "validPostRelaunchRetrievalTrials", "strata",
        },
        "installedAccessibilityAudit": {"status", "covered", "pending"},
    }
    for gate_name, gate in gates.items():
        if not isinstance(gate, dict):
            errors.append(f"{prefix} gate {gate_name} must be an object")
            continue
        unknown = unexpected_fields(gate, allowed_gate_fields.get(gate_name, set()))
        if unknown:
            errors.append(f"{prefix} gate {gate_name} has unknown fields: {', '.join(unknown)}")
        if gate.get("status") not in statuses:
            errors.append(f"{prefix} gate {gate_name} has invalid status")

    keychain = gates.get("keychainPromptRecurrence", {})
    allowed_verification_methods = {
        "unlocked-window-audit", "installed-process-survival",
        "securityagent-process-check", "unified-log-check",
    }
    methods = keychain.get("verificationMethods")
    if methods is not None and (
        not isinstance(methods, list)
        or not set(methods).issubset(allowed_verification_methods)
    ):
        errors.append(f"{prefix} keychain verificationMethods are not fixed-vocabulary values")

    pointer_gate = gates.get("installedPointerDrops", {})
    if pointer_gate.get("reasonCode") not in {None, "native-drag-lifecycle-not-delivered"}:
        errors.append(f"{prefix} live-pointer reasonCode is not a fixed-vocabulary value")
    pointer_coverage = pointer_gate.get("coverage")
    if pointer_coverage is not None and not isinstance(pointer_coverage, dict):
        errors.append(f"{prefix} live-pointer coverage must be an object")

    placement_gate = gates.get("installedPlacementSets", {})
    placement_entries = placement_gate.get("sets")
    if placement_entries is not None and (
        not isinstance(placement_entries, list)
        or any(
            not isinstance(entry, dict)
            or set(entry) != {"setId", "placementCount", "wrongPlacementCount"}
            for entry in placement_entries
        )
    ):
        errors.append(f"{prefix} placement sets have an unsafe nested field contract")

    timed_gate = gates.get("timedHumanTasks", {})
    timed_entries = timed_gate.get("strata")
    timed_fields = {
        "taskId", "stratum", "validTrialCount", "successCount",
        "medianMilliseconds", "p80Milliseconds", "p90Milliseconds",
        "thresholdMilliseconds", "withinThresholdCount", "withinThresholdRate",
    }
    if timed_entries is not None and (
        not isinstance(timed_entries, list)
        or any(not isinstance(entry, dict) or set(entry) != timed_fields for entry in timed_entries)
    ):
        errors.append(f"{prefix} timed strata have an unsafe nested field contract")

    accessibility_vocabulary = {
        "mode-migration", "rail-canvas-selection-synchronization", "frozen-query-search",
        "single-selection", "multi-selection", "live-lasso", "native-pointer-drag-and-drop",
        "empty-canvas-pointer-group-creation", "suggestion-review-mutation",
        "authorized-mail-mutation", "live-undo-and-recovery", "focused-keyboard-navigation",
        "narrow-width-layout", "installed-spritekit-button-role-and-screen-frame",
        "VoiceOver-session-operation", "cold-relaunch-persistence",
        "accessible-group-action", "group-creation",
        "suggestion-surface-and-effect-labels-read-only", "benchmark-mail-lock",
        "history-surface", "rail-collapse-and-restore", "opaque-stable-identifiers",
        "labels-hints-stable-identifiers-and-secondary-actions", "no-bottom-overlay-obstruction",
    }
    accessibility_gate = gates.get("installedAccessibilityAudit", {})
    for field in ("covered", "pending"):
        values = accessibility_gate.get(field)
        if not isinstance(values, list) or not set(values).issubset(accessibility_vocabulary):
            errors.append(f"{prefix} accessibility {field} is not a fixed-vocabulary list")

    signing = gates.get("signingAndInstall", {})
    if signing.get("status") == "pass":
        expected_signing = {
            "certificateSHA1": "59D9099E689B4FCF247C0E2C021C3B62E80AE4B2",
            "certificateDisplayUID": "MSTX4LWLXN",
            "expectedTeamIdentifier": "TN3L2WBKR5",
            "appTeamIdentifier": "TN3L2WBKR5",
            "extensionTeamIdentifier": "TN3L2WBKR5",
            "appSignature": "cms",
            "extensionSignature": "cms",
            "appLeafCertificateSHA1": "59D9099E689B4FCF247C0E2C021C3B62E80AE4B2",
            "extensionLeafCertificateSHA1": "59D9099E689B4FCF247C0E2C021C3B62E80AE4B2",
            "appCertificateChainTrust": "pass",
            "extensionCertificateChainTrust": "pass",
            "appDeepStrictVerification": "pass",
            "extensionDeepStrictVerification": "pass",
            "appBundleIdentifier": "isaacwongnh.BetterMail",
            "extensionBundleIdentifier": "isaacwongnh.BetterMail.MailHelperExtension",
            "bundleIdentifiersPreserved": True,
            "entitlementsPreserved": True,
            "installedEntitlementsMatchBuildProduct": True,
            "projectSigningFilesPreserved": True,
            "adHocFallbackUsed": False,
        }
        for field, expected in expected_signing.items():
            if signing.get(field) != expected:
                errors.append(f"{prefix} signing pass has wrong {field}")

    if keychain.get("status") == "pass" and (
        keychain.get("normalInstalledLaunchCount", 0) < 2
        or keychain.get("graphSpatialPromptObservedCount") != 0
        or keychain.get("securityAgentObservedCount") != 0
        or set(keychain.get("verificationMethods", [])) != allowed_verification_methods
    ):
        errors.append(f"{prefix} keychain recurrence pass lacks two clean launches")

    production = gates.get("productionEventBoundaries", {})
    if production.get("status") == "pass" and (
        not is_safe_identifier(production.get("installedRun"), ("synthetic-",))
        or production.get("groupVisibleCount", 0) <= 0
        or production.get("visibleResultCount", 0) <= 0
    ):
        errors.append(f"{prefix} production event-boundary pass lacks installed rendered events")

    deterministic = gates.get("deterministicDropMatrix", {})
    if deterministic.get("status") == "pass":
        strata = deterministic.get("strata")
        expected_strata = {
            (node_count, zoom, shape)
            for node_count in (100, 500)
            for zoom in ("low", "medium", "high")
            for shape in ("flat", "nested")
        }
        actual_strata = set()
        strata_valid = isinstance(strata, list) and len(strata) == 12
        if strata_valid:
            for index, entry in enumerate(strata):
                allowed = {
                    "nodeCount", "zoomBand", "targetShape", "attemptCount",
                    "failedAttemptCount", "longLabelAttemptCount", "shortLabelAttemptCount",
                    "invalidTargetMutationCount",
                }
                if not isinstance(entry, dict) or set(entry) != allowed:
                    strata_valid = False
                    continue
                actual_strata.add((entry.get("nodeCount"), entry.get("zoomBand"), entry.get("targetShape")))
                if (
                    entry.get("attemptCount") != 10
                    or entry.get("failedAttemptCount", 10) > 1
                    or entry.get("longLabelAttemptCount") != 5
                    or entry.get("shortLabelAttemptCount") != 5
                    or entry.get("invalidTargetMutationCount") != 0
                ):
                    strata_valid = False
        if (
            deterministic.get("attemptCount") != 120
            or deterministic.get("failedAttemptCount", 120) > 6
            or not strata_valid
            or actual_strata != expected_strata
        ):
            errors.append(f"{prefix} deterministic drop pass lacks all twelve frozen strata")

    pointer = pointer_gate
    if pointer.get("status") == "pass":
        attempts = pointer.get("attemptCount", 0)
        failures = pointer.get("failedAttemptCount", attempts)
        if attempts < 40 or attempts <= 0 or (attempts - failures) / attempts < 0.95:
            errors.append(f"{prefix} live-pointer pass is below 40 attempts or 95 percent")
        expected_coverage = {
            "selectionMode": ["single", "multi"],
            "zoomBand": ["low", "medium", "high"],
            "targetShape": ["flat", "nested"],
            "labelVariant": ["short", "long"],
        }
        if pointer.get("coverage") != expected_coverage:
            errors.append(f"{prefix} live-pointer pass lacks every required coverage dimension")

    placements = placement_gate
    if placements.get("status") == "pass":
        sets = placements.get("sets")
        expected_ids = {f"placement-set-{index:02d}" for index in range(1, 6)}
        sets_valid = isinstance(sets, list) and len(sets) == 5
        if sets_valid:
            sets_valid = (
                {entry.get("setId") for entry in sets if isinstance(entry, dict)} == expected_ids
                and all(
                    isinstance(entry, dict)
                    and set(entry) == {"setId", "placementCount", "wrongPlacementCount"}
                    and entry.get("placementCount") == 20
                    and entry.get("wrongPlacementCount", 99) <= 1
                    for entry in sets
                )
            )
        if (
            placements.get("setCount") != 5
            or placements.get("adjudicatedPlacementCount") != 100
            or placements.get("maximumWrongPlacementCountPerSet", 99) > 1
            or placements.get("wrongAppleMailRouteCount") != 0
            or not sets_valid
        ):
            errors.append(f"{prefix} placement-set pass lacks five exact adjudicated 20-item sets")

    suggestion = gates.get("suggestionQuality", {})
    if suggestion.get("status") == "pass" and (
        suggestion.get("candidateCount", 0) < 200
        or suggestion.get("acceptedCount", 0) < 100
        or suggestion.get("correctAcceptedCount", 0) > suggestion.get("acceptedCount", 0)
        or suggestion.get("falsePositiveCount") != 0
        or suggestion.get("precision", 0) < 0.85
        or suggestion.get("coverage", 0) < 0.50
        or suggestion.get("sourceArtifact") != "suggestion-evaluation-v2.json"
    ):
        errors.append(f"{prefix} suggestion-quality pass lacks its frozen quality evidence")

    unauthorized = gates.get("unauthorizedMailInvariant", {})
    if unauthorized.get("status") == "pass" and unauthorized.get("externalMailCallCount") != 0:
        errors.append(f"{prefix} unauthorized-Mail pass has external calls")

    timed = timed_gate
    if timed.get("status") == "pass":
        expected_slices = {
            ("first-organization", "warm"): (10, 30_000, None),
            ("first-organization", "cold-relaunch"): (10, 30_000, None),
            ("five-conversation-organization", "warm"): (10, 120_000, None),
            ("five-conversation-organization", "cold-relaunch"): (10, 120_000, None),
            ("retrieval", "post-commit"): (20, 5_000, 0.95),
            ("retrieval", "post-relaunch"): (20, 5_000, 0.95),
        }
        strata = timed.get("strata")
        actual_slices = {}
        strata_valid = isinstance(strata, list) and len(strata) == len(expected_slices)
        if strata_valid:
            for entry in strata:
                allowed = {
                    "taskId", "stratum", "validTrialCount", "successCount",
                    "medianMilliseconds", "p80Milliseconds", "p90Milliseconds",
                    "thresholdMilliseconds", "withinThresholdCount", "withinThresholdRate",
                }
                if not isinstance(entry, dict) or set(entry) != allowed:
                    strata_valid = False
                    continue
                actual_slices[(entry.get("taskId"), entry.get("stratum"))] = entry
            if set(actual_slices) != set(expected_slices):
                strata_valid = False
            for key, (minimum, limit, rate) in expected_slices.items():
                entry = actual_slices.get(key, {})
                if (
                    entry.get("validTrialCount", 0) < minimum
                    or not isinstance(entry.get("medianMilliseconds"), int)
                    or not isinstance(entry.get("p80Milliseconds"), int)
                    or not isinstance(entry.get("p90Milliseconds"), int)
                    or entry.get("p80Milliseconds", limit + 1) > limit
                    or entry.get("thresholdMilliseconds") != limit
                    or (rate is not None and entry.get("withinThresholdRate", 0) < rate)
                ):
                    strata_valid = False
        if (
            timed.get("validFirstOrganizationTrials", 0) < 20
            or timed.get("validFiveConversationTrials", 0) < 20
            or timed.get("validPostCommitRetrievalTrials", 0) < 20
            or timed.get("validPostRelaunchRetrievalTrials", 0) < 20
            or not strata_valid
        ):
            errors.append(f"{prefix} timed-human pass lacks frozen warm/cold timing and retrieval strata")

    accessibility = accessibility_gate
    if accessibility.get("status") == "pass":
        required_accessibility = {
            "mode-migration", "rail-canvas-selection-synchronization", "frozen-query-search",
            "single-selection", "multi-selection", "live-lasso", "native-pointer-drag-and-drop",
            "empty-canvas-pointer-group-creation", "cold-relaunch-persistence",
            "suggestion-review-mutation", "suggestion-surface-and-effect-labels-read-only",
            "authorized-mail-mutation", "live-undo-and-recovery", "focused-keyboard-navigation",
            "narrow-width-layout", "installed-spritekit-button-role-and-screen-frame",
            "VoiceOver-session-operation", "opaque-stable-identifiers", "no-bottom-overlay-obstruction",
        }
        if accessibility.get("pending") or not required_accessibility.issubset(set(accessibility.get("covered", []))):
            errors.append(f"{prefix} accessibility pass lacks the complete named installed audit")

    unmet = artifact.get("unmetTargets")
    if not isinstance(unmet, list):
        errors.append(f"{prefix} unmetTargets must be an array")
    elif artifact.get("status") == "pass" and unmet:
        errors.append(f"{prefix} overall pass cannot retain unmet targets")
    allowed_unmet_targets = {
        "installed-pointer-drops-40-attempts",
        "installed-placement-sets-five-by-twenty",
        "timed-human-first-organization-warm-and-cold",
        "timed-human-five-conversation-warm-and-cold",
        "timed-human-retrieval-post-commit-and-post-relaunch",
        "complete-installed-interaction-and-VoiceOver-audit",
        "all-hard-gates-complete",
    }
    if isinstance(unmet, list) and not set(unmet).issubset(allowed_unmet_targets):
        errors.append(f"{prefix} unmetTargets contains a non-vocabulary value")
    if artifact.get("status") == "pass" and any(
        not isinstance(gates.get(gate), dict) or gates[gate].get("status") != "pass"
        for gate in hard_gates
    ):
        errors.append(f"{prefix} overall pass requires every hard gate to pass")
    if not isinstance(artifact.get("invalidTrials"), list):
        errors.append(f"{prefix} invalidTrials must be an array")
    if artifact.get("invalidTrialReasonCode") not in {
        "no-human-benchmark-trial-started", "invalid-trials-disclosed"
    }:
        errors.append(f"{prefix} invalidTrialReasonCode is not a fixed vocabulary value")
    privacy = artifact.get("privacy")
    expected_privacy = {
        "aggregateOnly": True,
        "rawMailDataIncluded": False,
        "exactRoutesIncluded": False,
        "rawIdentifiersIncluded": False,
        "credentialsIncluded": False,
        "providerPromptsIncluded": False,
    }
    if privacy != expected_privacy:
        errors.append(f"{prefix} privacy declaration is incomplete")
    return errors


def validate_result_artifacts(repo_root: Path) -> list[str]:
    errors: list[str] = []
    schema_path = repo_root / METRIC_SCHEMA_PATH.relative_to(REPO_ROOT)
    status_schema_path = repo_root / ACCEPTANCE_STATUS_SCHEMA_PATH.relative_to(REPO_ROOT)
    results_dir = repo_root / RESULTS_DIR.relative_to(REPO_ROOT)
    if not schema_path.exists():
        return [f"missing {schema_path}"]
    if not results_dir.exists():
        return [f"missing {results_dir}"]
    if not status_schema_path.exists():
        return [f"missing {status_schema_path}"]
    metric_schema = load(schema_path)
    status_schema = load(status_schema_path)
    if status_schema.get("schemaVersion") != "visual-email-organizer-acceptance-status-v1":
        errors.append("acceptance status schema has the wrong schemaVersion")
    expected_hard_gates = {
        "signingAndInstall", "keychainPromptRecurrence", "productionEventBoundaries",
        "deterministicDropMatrix", "installedPointerDrops", "installedPlacementSets",
        "suggestionQuality", "unauthorizedMailInvariant", "timedHumanTasks",
        "installedAccessibilityAudit",
    }
    if set(status_schema.get("hardGates", [])) != expected_hard_gates:
        errors.append("acceptance status schema hard-gate list is incomplete")
    for path in sorted(results_dir.glob("*.json")):
        try:
            artifact = load(path)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            errors.append(f"{path.name}: unreadable JSON: {error}")
            continue
        if not isinstance(artifact, dict):
            errors.append(f"{path.name}: top-level result must be an object")
            continue
        errors.extend(validate_result_privacy(path, artifact, metric_schema))
        schema_version = artifact.get("schemaVersion")
        if schema_version not in RESULT_SCHEMA_VERSIONS:
            errors.append(f"{path.name}: unknown result schemaVersion")
        elif schema_version == "visual-email-organizer-metrics-v1":
            errors.extend(validate_metric_result(path, artifact, metric_schema))
        elif schema_version == "visual-email-organizer-acceptance-status-v1":
            errors.extend(
                validate_acceptance_status(path, artifact, metric_schema, status_schema)
            )
        elif schema_version == "organizer-suggestion-corpus-preparation-v1":
            expected_fields = {
                "schemaVersion", "corpusID", "createdAt", "generatorPath", "candidateCount",
                "inputArtifactSHA256", "goldArtifactSHA256", "keyBits", "keyGenerator",
                "keysAssignedBeforeAdjudication", "rawKeyMaterialRetained", "workflow",
            }
            if set(artifact) != expected_fields:
                errors.append(f"{path.name}: preparation result has an unexpected field contract")
            expected_workflow = [
                "Construct synthetic source and target scenarios without gold fields.",
                "Assign unique candidate, source, and destination keys from the system CSPRNG.",
                "Freeze the provider-facing input records.",
                "Adjudicate relation, confidence, provenance, expected decision, and destination separately.",
                "Bind this record to the exact input and gold artifact SHA-256 digests.",
            ]
            if artifact.get("workflow") != expected_workflow:
                errors.append(f"{path.name}: preparation workflow is not the frozen synthetic vocabulary")
        elif schema_version == "organizer-suggestion-evaluation-v1":
            expected_fields = {
                "schemaVersion", "status", "issueCodes", "pins", "corpusQuality",
                "candidateCount", "rawPredictionCount", "acceptedCount", "correctAcceptedCount",
                "nonAbstainedCount", "abstainedCount", "truePositiveCount", "falsePositiveCount",
                "trueNegativeCount", "falseNegativeCount", "precision", "coverage",
                "minimumCandidateCount", "minimumAcceptedCount", "minimumDecisionCountPerSlice",
                "minimumPrecision", "minimumCoverage", "slices", "duplicateGoldSourceCount",
                "duplicatePredictionSourceCount", "conflictingSourceCount", "unmatchedPredictionCount",
            }
            if set(artifact) != expected_fields:
                errors.append(f"{path.name}: suggestion evaluation has an unexpected field contract")
    return errors


def validate(repo_root: Path) -> list[str]:
    errors: list[str] = []
    fixtures_dir = repo_root / "Tests/Fixtures/Organizer"
    manifest_path = repo_root / MANIFEST_PATH.relative_to(REPO_ROOT)
    for size in (100, 500):
        path = fixtures_dir / f"organizer-{size:03d}-v1.json"
        if not path.exists():
            errors.append(f"missing {path}")
        else:
            errors.extend(f"{path.name}: {error}" for error in validate_fixture(load(path), size))
    suggestion_path = fixtures_dir / "suggestion-gold-v1.json"
    if not suggestion_path.exists():
        errors.append(f"missing {suggestion_path}")
    else:
        errors.extend(f"{suggestion_path.name}: {error}" for error in validate_suggestions(load(suggestion_path)))
    if not manifest_path.exists():
        errors.append(f"missing {manifest_path}")
    else:
        manifest = load(manifest_path)
        errors.extend(f"benchmark-manifest-v1.json: {error}" for error in validate_manifest(manifest))
        errors.extend(validate_suggestion_acceptance(repo_root, manifest))
    errors.extend(validate_result_artifacts(repo_root))
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=REPO_ROOT, help="repository root")
    args = parser.parse_args()
    repo_root = args.repo.resolve()
    errors = validate(repo_root)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    manifest = load(repo_root / MANIFEST_PATH.relative_to(REPO_ROOT))
    status = manifest.get("suggestionEvaluation", {}).get(
        "acceptanceArtifactStatus", "unknown"
    )
    print(f"Organizer benchmark contract and fixtures valid; suggestion v2 status={status}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
