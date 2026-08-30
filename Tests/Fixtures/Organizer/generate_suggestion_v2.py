#!/usr/bin/env python3
"""Create or validate the split v2 organizer suggestion acceptance corpus.

This is a one-shot corpus preparation tool. It assigns cryptographically random
opaque candidate/source/destination keys before the separate gold adjudication
step and refuses to overwrite frozen artifacts unless ``--force`` is explicit.
Provider-facing input contains only synthetic source/target evidence and routing
keys; relation, confidence, provenance, and expected outcomes live only in gold.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import secrets
from typing import Any


SCRIPT_PATH = Path(__file__).resolve()
FIXTURE_ROOT = SCRIPT_PATH.parent
REPO_ROOT = SCRIPT_PATH.parents[3]
CORPUS_ID = "organizer-suggestion-v2"
INPUT_SCHEMA = "organizer-suggestion-input-v2"
GOLD_SCHEMA = "organizer-suggestion-gold-v2"
PREPARATION_SCHEMA = "organizer-suggestion-corpus-preparation-v1"
RELATIONS = ("attach", "append", "unrelated")
CONFIDENCE_BANDS = ("low", "medium", "high", "very-high")
PROVENANCES = ("heuristic", "foundation-model")
RECORDS_PER_CELL = 9
HEX_DIGITS = frozenset("0123456789abcdef")


def encoded_json(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def opaque_key(prefix: str, used: set[str]) -> str:
    while True:
        value = f"{prefix}-{secrets.token_hex(32)}"
        if value not in used:
            used.add(value)
            return value


def scenario_evidence(relation: str, index: int) -> dict[str, Any]:
    serial = f"{index + 1:03d}"
    if relation == "attach":
        topic = f"Project Cedar {serial}"
        action = f"launch readiness review LR-{serial}"
        return {
            "sourceTitle": f"{topic}: {action} follow-up",
            "sourceSummary": f"Follow-up decisions for the same {action} in {topic}.",
            "sourceContent": (
                f"Please confirm the open decision and attendee action for {action}. "
                f"This continues the {topic} review scheduled for synthetic week {serial}."
            ),
            "targetTitle": f"{topic}: {action}",
            "targetSummary": f"Original invitation and decision thread for {action} in {topic}.",
            "targetContent": (
                f"Agenda, attendees, and decisions for {action}. "
                f"Track the same {topic} launch review through synthetic week {serial}."
            ),
            "targetIsFolderProfile": False,
        }
    if relation == "append":
        topic = f"Program Harbor {serial}"
        action = f"supplier approval SA-{serial}"
        return {
            "sourceTitle": f"{topic}: {action}",
            "sourceSummary": f"New supplier approval action within the broader {topic} program.",
            "sourceContent": (
                f"Review the evidence and approve {action} for {topic}. "
                "This is a distinct action from the program roadmap and budget reviews."
            ),
            "targetTitle": f"{topic} confirmed workspace",
            "targetSummary": f"Confirmed folder profile for the broader {topic} program.",
            "targetContent": (
                f"The {topic} workspace contains roadmap, budget, launch, and supplier workstreams. "
                "Each workstream remains a distinct conversation under the same named program."
            ),
            "targetIsFolderProfile": True,
        }

    source_topic = f"Initiative Indigo {serial}"
    target_topic = f"Program Quartz {serial}"
    return {
        "sourceTitle": f"{source_topic}: incident review IR-{serial}",
        "sourceSummary": f"Incident review for the unrelated {source_topic} service.",
        "sourceContent": (
            f"Resolve incident IR-{serial} for {source_topic}; owners and deliverables are unique "
            "to the Indigo service."
        ),
        "targetTitle": f"{target_topic}: annual planning AP-{serial}",
        "targetSummary": f"Annual planning for the separate {target_topic} portfolio.",
        "targetContent": (
            f"Prepare portfolio goals and budget AP-{serial} for {target_topic}. "
            "This work has no shared project, event, owner, incident, or deliverable."
        ),
        "targetIsFolderProfile": index % 2 == 0,
    }


def adjudicate(
    keyed_scenario: dict[str, Any],
    relation: str,
    confidence_band: str,
    provenance: str,
) -> dict[str, Any]:
    accepted = relation in {"attach", "append"}
    gold: dict[str, Any] = {
        "candidateKey": keyed_scenario["candidateKey"],
        "sourceKey": keyed_scenario["sourceKey"],
        "relation": relation,
        "confidenceBand": confidence_band,
        "provenance": provenance,
        "expectedLabel": "accepted" if accepted else "rejected",
    }
    if accepted:
        gold["expectedDestinationKey"] = keyed_scenario["targetKey"]
    return gold


def build_artifacts() -> tuple[dict[str, Any], dict[str, Any]]:
    used_keys: set[str] = set()
    candidates: list[dict[str, Any]] = []
    keyed_scenarios: list[tuple[dict[str, Any], str, str, str]] = []
    scenario_index = 0

    # Key assignment is deliberately complete before any gold record is made.
    for relation in RELATIONS:
        for confidence_band in CONFIDENCE_BANDS:
            for provenance in PROVENANCES:
                for _ in range(RECORDS_PER_CELL):
                    candidate = {
                        "candidateKey": opaque_key("candidate", used_keys),
                        "sourceKey": opaque_key("source", used_keys),
                        "targetKey": opaque_key("destination", used_keys),
                        **scenario_evidence(relation, scenario_index),
                    }
                    candidates.append(candidate)
                    keyed_scenarios.append((candidate, relation, confidence_band, provenance))
                    scenario_index += 1

    records = [
        adjudicate(candidate, relation, confidence_band, provenance)
        for candidate, relation, confidence_band, provenance in keyed_scenarios
    ]
    return (
        {
            "schemaVersion": INPUT_SCHEMA,
            "corpusID": CORPUS_ID,
            "keyPolicy": "random-before-adjudication-v1",
            "contentPolicy": "synthetic-production-relevant-v1",
            "candidates": candidates,
        },
        {
            "schemaVersion": GOLD_SCHEMA,
            "corpusID": CORPUS_ID,
            "unrelatedOutcomePolicy": "correct-rejection-v1",
            "records": records,
        },
    )


def is_opaque_key(value: Any, prefix: str) -> bool:
    if not isinstance(value, str) or not value.startswith(f"{prefix}-"):
        return False
    suffix = value[len(prefix) + 1 :]
    return len(suffix) == 64 and all(character in HEX_DIGITS for character in suffix)


def validate_artifacts(input_data: bytes, gold_data: bytes) -> list[str]:
    errors: list[str] = []
    try:
        input_artifact = json.loads(input_data)
    except json.JSONDecodeError as error:
        return [f"input artifact is malformed: {error}"]
    try:
        gold_artifact = json.loads(gold_data)
    except json.JSONDecodeError as error:
        return [f"gold artifact is malformed: {error}"]

    expected_input_fields = {
        "schemaVersion", "corpusID", "keyPolicy", "contentPolicy", "candidates"
    }
    expected_gold_fields = {
        "schemaVersion", "corpusID", "unrelatedOutcomePolicy", "records"
    }
    if set(input_artifact) != expected_input_fields:
        errors.append("provider input has an unexpected top-level field contract")
    if set(gold_artifact) != expected_gold_fields:
        errors.append("gold has an unexpected top-level field contract")
    if input_artifact.get("schemaVersion") != INPUT_SCHEMA:
        errors.append("provider input schema version is incorrect")
    if gold_artifact.get("schemaVersion") != GOLD_SCHEMA:
        errors.append("gold schema version is incorrect")
    if input_artifact.get("corpusID") != CORPUS_ID or gold_artifact.get("corpusID") != CORPUS_ID:
        errors.append("corpus identifiers do not match v2")

    candidates = input_artifact.get("candidates", [])
    records = gold_artifact.get("records", [])
    expected_count = len(RELATIONS) * len(CONFIDENCE_BANDS) * len(PROVENANCES) * RECORDS_PER_CELL
    if len(candidates) != expected_count or len(records) != expected_count:
        errors.append(f"v2 must contain exactly {expected_count} input and gold records")

    forbidden_input_fields = {
        "relation", "confidenceBand", "provenance", "expectedLabel",
        "expectedDestinationKey", "goldLabel",
    }
    required_evidence_fields = {
        "sourceTitle", "sourceSummary", "sourceContent",
        "targetTitle", "targetSummary", "targetContent",
    }
    input_identities: set[tuple[str, str]] = set()
    all_keys: set[str] = set()
    target_by_identity: dict[tuple[str, str], str] = {}
    for index, candidate in enumerate(candidates):
        if forbidden_input_fields.intersection(candidate):
            errors.append(f"provider input record {index} leaks evaluator-only fields")
        if not all(isinstance(candidate.get(field), str) and candidate[field].strip()
                   for field in required_evidence_fields):
            errors.append(f"provider input record {index} lacks production-relevant synthetic evidence")
        for field, prefix in (
            ("candidateKey", "candidate"),
            ("sourceKey", "source"),
            ("targetKey", "destination"),
        ):
            value = candidate.get(field)
            if not is_opaque_key(value, prefix):
                errors.append(f"provider input record {index} has an invalid {field}")
            elif value in all_keys:
                errors.append(f"provider input record {index} reuses an opaque key")
            else:
                all_keys.add(value)
        identity = (candidate.get("candidateKey"), candidate.get("sourceKey"))
        if identity in input_identities:
            errors.append(f"provider input record {index} duplicates its identity")
        input_identities.add(identity)
        target_by_identity[identity] = candidate.get("targetKey")

    gold_identities: set[tuple[str, str]] = set()
    relation_counts = {value: 0 for value in RELATIONS}
    confidence_accepted = {value: 0 for value in CONFIDENCE_BANDS}
    provenance_accepted = {value: 0 for value in PROVENANCES}
    accepted_count = 0
    for index, record in enumerate(records):
        identity = (record.get("candidateKey"), record.get("sourceKey"))
        gold_identities.add(identity)
        relation = record.get("relation")
        label = record.get("expectedLabel")
        if relation not in relation_counts:
            errors.append(f"gold record {index} has an invalid relation")
            continue
        relation_counts[relation] += 1
        if relation == "unrelated" and label != "rejected":
            errors.append(f"unrelated gold record {index} must be rejected")
        if label == "accepted":
            accepted_count += 1
            confidence_accepted[record.get("confidenceBand")] = (
                confidence_accepted.get(record.get("confidenceBand"), 0) + 1
            )
            provenance_accepted[record.get("provenance")] = (
                provenance_accepted.get(record.get("provenance"), 0) + 1
            )
            if record.get("expectedDestinationKey") != target_by_identity.get(identity):
                errors.append(f"accepted gold record {index} does not bind its provider destination")
        elif "expectedDestinationKey" in record:
            errors.append(f"rejected gold record {index} must not contain a destination")

    if input_identities != gold_identities:
        errors.append("provider input and gold identities are not an exact one-to-one match")
    if accepted_count < 100:
        errors.append("gold has fewer than 100 accepted placements")
    if any(value < 25 for value in confidence_accepted.values()):
        errors.append("a confidence-band slice has fewer than 25 accepted placements")
    if any(value < 25 for value in provenance_accepted.values()):
        errors.append("a provenance slice has fewer than 25 accepted placements")
    if relation_counts["unrelated"] < 25:
        errors.append("the unrelated rejection-control slice has fewer than 25 decisions")
    return errors


def validate_preparation_record(
    data: bytes,
    input_digest: str,
    gold_digest: str,
    candidate_count: int,
) -> list[str]:
    try:
        record = json.loads(data)
    except json.JSONDecodeError as error:
        return [f"preparation record is malformed: {error}"]
    errors: list[str] = []
    expected = {
        "schemaVersion": PREPARATION_SCHEMA,
        "corpusID": CORPUS_ID,
        "candidateCount": candidate_count,
        "inputArtifactSHA256": input_digest,
        "goldArtifactSHA256": gold_digest,
        "keyBits": 256,
        "keyGenerator": "python-secrets-system-csprng",
        "keysAssignedBeforeAdjudication": True,
        "rawKeyMaterialRetained": False,
    }
    for field, value in expected.items():
        if record.get(field) != value:
            errors.append(f"preparation record has an incorrect {field}")
    return errors


def generate(input_path: Path, gold_path: Path, preparation_path: Path, force: bool) -> None:
    existing = [path for path in (input_path, gold_path, preparation_path) if path.exists()]
    if existing and not force:
        names = ", ".join(str(path) for path in existing)
        raise FileExistsError(f"refusing to overwrite frozen artifact(s): {names}")

    input_artifact, gold_artifact = build_artifacts()
    input_data = encoded_json(input_artifact)
    gold_data = encoded_json(gold_artifact)
    errors = validate_artifacts(input_data, gold_data)
    if errors:
        raise ValueError("generated artifacts failed validation: " + "; ".join(errors))

    preparation = {
        "schemaVersion": PREPARATION_SCHEMA,
        "corpusID": CORPUS_ID,
        "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "generatorPath": "Tests/Fixtures/Organizer/generate_suggestion_v2.py",
        "candidateCount": len(input_artifact["candidates"]),
        "inputArtifactSHA256": sha256_hex(input_data),
        "goldArtifactSHA256": sha256_hex(gold_data),
        "keyBits": 256,
        "keyGenerator": "python-secrets-system-csprng",
        "keysAssignedBeforeAdjudication": True,
        "rawKeyMaterialRetained": False,
        "workflow": [
            "Construct synthetic source and target scenarios without gold fields.",
            "Assign unique candidate, source, and destination keys from the system CSPRNG.",
            "Freeze the provider-facing input records.",
            "Adjudicate relation, confidence, provenance, expected decision, and destination separately.",
            "Bind this record to the exact input and gold artifact SHA-256 digests.",
        ],
    }

    for path in (input_path, gold_path, preparation_path):
        path.parent.mkdir(parents=True, exist_ok=True)
    input_path.write_bytes(input_data)
    gold_path.write_bytes(gold_data)
    preparation_path.write_bytes(encoded_json(preparation))


def validate_files(input_path: Path, gold_path: Path, preparation_path: Path) -> list[str]:
    missing = [path for path in (input_path, gold_path, preparation_path) if not path.exists()]
    if missing:
        return [f"missing frozen artifact: {path}" for path in missing]
    input_data = input_path.read_bytes()
    gold_data = gold_path.read_bytes()
    errors = validate_artifacts(input_data, gold_data)
    errors.extend(
        validate_preparation_record(
            preparation_path.read_bytes(),
            sha256_hex(input_data),
            sha256_hex(gold_data),
            len(json.loads(input_data).get("candidates", [])),
        )
    )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="validate without writing")
    parser.add_argument("--force", action="store_true", help="explicitly replace frozen v2 files")
    parser.add_argument(
        "--input",
        type=Path,
        default=FIXTURE_ROOT / "suggestion-input-v2.json",
    )
    parser.add_argument(
        "--gold",
        type=Path,
        default=FIXTURE_ROOT / "suggestion-gold-v2.json",
    )
    parser.add_argument(
        "--preparation-record",
        type=Path,
        default=REPO_ROOT
        / "docs/acceptance/visual-email-organizer/results/suggestion-corpus-v2-preparation.json",
    )
    args = parser.parse_args()

    if not args.check:
        try:
            generate(args.input, args.gold, args.preparation_record, args.force)
        except (FileExistsError, ValueError) as error:
            print(f"ERROR: {error}")
            return 1
    errors = validate_files(args.input, args.gold, args.preparation_record)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    input_data = args.input.read_bytes()
    gold_data = args.gold.read_bytes()
    print(
        "Suggestion v2 split corpus valid: "
        f"{len(json.loads(input_data)['candidates'])} candidates, "
        f"input sha256={sha256_hex(input_data)}, gold sha256={sha256_hex(gold_data)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
