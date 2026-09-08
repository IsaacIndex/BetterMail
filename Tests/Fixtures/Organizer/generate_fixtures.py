#!/usr/bin/env python3
"""Generate and validate deterministic, anonymized organizer acceptance fixtures.

The generated data intentionally contains synthetic fixture keys and labels only.
It must never be populated from an Apple Mail export or a provider prompt.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
FIXTURE_VERSION = "organizer-fixture-v1"
SUGGESTION_VERSION = "organizer-suggestions-v1"
FORBIDDEN_FIELD_FRAGMENTS = (
    "subject",
    "sender",
    "body",
    "snippet",
    "account",
    "mailbox",
    "route",
    "messageid",
    "threadid",
    "authorization",
    "token",
    "prompt",
)


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def group_records(size: int) -> list[dict[str, Any]]:
    groups: list[dict[str, Any]] = []
    for index in range(4):
        groups.append(
            {
                "groupKey": f"group-flat-{index:02d}",
                "displayLabel": f"Confirmed Group {index + 1:02d}",
                "parentGroupKey": None,
                "targetShape": "flat",
                "acceptsDrop": True,
                "longLabel": index % 2 == 0,
            }
        )
    for index in range(4):
        parent = f"group-flat-{index:02d}"
        groups.append(
            {
                "groupKey": f"group-nested-{index:02d}",
                "displayLabel": f"Nested Group {index + 1:02d}",
                "parentGroupKey": parent,
                "targetShape": "nested",
                "acceptsDrop": True,
                "longLabel": index % 2 == 1,
            }
        )
    groups.append(
        {
            "groupKey": "group-suggested-00",
            "displayLabel": "Potential Group 01",
            "parentGroupKey": None,
            "targetShape": "ghost",
            "acceptsDrop": False,
            "longLabel": False,
        }
    )
    groups.append(
        {
            "groupKey": "group-remainder-00",
            "displayLabel": "More conversations",
            "parentGroupKey": None,
            "targetShape": "virtual-remainder",
            "acceptsDrop": False,
            "longLabel": False,
        }
    )
    return groups


def fixture(size: int) -> dict[str, Any]:
    groups = group_records(size)
    nodes: list[dict[str, Any]] = []
    columns = 10 if size == 100 else 25
    for index in range(size):
        x = (index % columns) * 92 + 48
        y = (index // columns) * 58 + 48
        nodes.append(
            {
                "fixtureNodeKey": f"node-{size:03d}-{index:04d}",
                "effectiveConversationKey": f"conversation-{size:03d}-{index:04d}",
                "displayLabel": f"Synthetic conversation {index + 1:04d}",
                "currentGroupKey": None,
                "messageCount": 1 + (index % 5),
                "eligibleForPlacement": True,
                "position": {"x": x, "y": y},
                "longLabel": index % 2 == 0,
            }
        )

    return {
        "schemaVersion": FIXTURE_VERSION,
        "fixtureId": f"organizer-{size:03d}-v1",
        "fixtureKind": "synthetic-organizer-canvas",
        "description": f"Deterministic synthetic organizer canvas with {size} conversation nodes.",
        "nodeCount": size,
        "scopeKey": f"scope-{size:03d}-v1",
        "nodes": nodes,
        "groups": groups,
        "invalidTargets": [
            "group-suggested-00",
            "group-remainder-00",
            "canvas-outside-targets",
        ],
        "zoomBands": {
            "low": 0.75,
            "medium": 1.0,
            "high": 1.75,
        },
        "labelVariants": {
            "short": "Synthetic conversation 0001",
            "long": "Synthetic conversation 0001 — deterministic long display label for pointer targeting",
        },
    }


def suggestion_corpus() -> dict[str, Any]:
    relations = ("attach", "append", "unrelated")
    confidence_bands = ("low", "medium", "high", "very-high")
    provenances = ("heuristic", "foundation-model")
    candidates: list[dict[str, Any]] = []
    index = 0
    # 3 relations x 4 confidence bands x 2 provenance values x 10 candidates = 240.
    # The alternating label gives every relation, confidence band, and provenance
    # a balanced 50/50 accepted/rejected split.
    for relation in relations:
        for confidence_band in confidence_bands:
            for provenance in provenances:
                for local_index in range(10):
                    accepted = local_index % 2 == 0
                    candidates.append(
                        {
                            "candidateKey": f"candidate-{index:04d}",
                            "sourceKey": f"source-{index:04d}",
                            "relation": relation,
                            "confidenceBand": confidence_band,
                            "provenance": provenance,
                            "goldLabel": "accepted" if accepted else "rejected",
                            "proposedGroupKey": f"group-gold-{(index % 12):02d}",
                            "currentGroupState": "unorganized" if relation == "attach" else "confirmed",
                            "memberCount": 2 + (index % 4),
                        }
                    )
                    index += 1
    return {
        "schemaVersion": SUGGESTION_VERSION,
        "corpusId": "organizer-suggestion-gold-v1",
        "description": "Synthetic frozen gold labels for suggestion precision evaluation.",
        "candidateCount": len(candidates),
        "labelCounts": {"accepted": 120, "rejected": 120},
        "declaredSlices": ["relation"],
        "requiredRelationSlices": list(relations),
        "candidates": candidates,
    }


def _walk_keys(value: Any, path: str = "root") -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    if isinstance(value, dict):
        for key, child in value.items():
            found.append((f"{path}.{key}", key.lower()))
            found.extend(_walk_keys(child, f"{path}.{key}"))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            found.extend(_walk_keys(child, f"{path}[{index}]"))
    return found


def validate_fixture(data: dict[str, Any], expected_size: int) -> list[str]:
    errors: list[str] = []
    if data.get("schemaVersion") != FIXTURE_VERSION:
        errors.append("fixture schemaVersion is not organizer-fixture-v1")
    if data.get("nodeCount") != expected_size:
        errors.append(f"expected nodeCount {expected_size}")
    if len(data.get("nodes", [])) != expected_size:
        errors.append(f"expected exactly {expected_size} nodes")
    node_keys = [node.get("fixtureNodeKey") for node in data.get("nodes", [])]
    if len(node_keys) != len(set(node_keys)):
        errors.append("fixtureNodeKey values are not unique")
    conversation_keys = [node.get("effectiveConversationKey") for node in data.get("nodes", [])]
    if len(conversation_keys) != len(set(conversation_keys)):
        errors.append("effectiveConversationKey values are not unique")
    groups = data.get("groups", [])
    group_keys = [group.get("groupKey") for group in groups]
    if len(group_keys) != len(set(group_keys)):
        errors.append("groupKey values are not unique")
    accepted_groups = [group for group in groups if group.get("acceptsDrop")]
    if not any(group.get("targetShape") == "flat" for group in accepted_groups):
        errors.append("fixture has no flat drop target")
    if not any(group.get("targetShape") == "nested" for group in accepted_groups):
        errors.append("fixture has no nested drop target")
    for path, key in _walk_keys(data):
        if any(fragment in key for fragment in FORBIDDEN_FIELD_FRAGMENTS):
            errors.append(f"forbidden sensitive field at {path}")
    return errors


def validate_suggestions(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    candidates = data.get("candidates", [])
    if data.get("schemaVersion") != SUGGESTION_VERSION:
        errors.append("suggestion schemaVersion is not organizer-suggestions-v1")
    if len(candidates) < 200:
        errors.append("suggestion corpus has fewer than 200 candidates")
    source_keys = [candidate.get("sourceKey") for candidate in candidates]
    if len(source_keys) != len(set(source_keys)):
        errors.append("suggestion sourceKey values are not deduplicated")
    labels = {label: sum(candidate.get("goldLabel") == label for candidate in candidates) for label in ("accepted", "rejected")}
    if labels["accepted"] != labels["rejected"]:
        errors.append("suggestion labels are not balanced")
    if labels["accepted"] < 100:
        errors.append("suggestion corpus has fewer than 100 accepted labels")
    for relation in data.get("requiredRelationSlices", []):
        accepted = sum(
            candidate.get("relation") == relation and candidate.get("goldLabel") == "accepted"
            for candidate in candidates
        )
        if accepted < 25:
            errors.append(f"relation slice {relation} has fewer than 25 accepted labels")
    for path, key in _walk_keys(data):
        if any(fragment in key for fragment in FORBIDDEN_FIELD_FRAGMENTS):
            errors.append(f"forbidden sensitive field at {path}")
    return errors


def validate(output_dir: Path) -> list[str]:
    errors: list[str] = []
    for size in (100, 500):
        path = output_dir / f"organizer-{size:03d}-v1.json"
        if not path.exists():
            errors.append(f"missing fixture: {path.name}")
            continue
        errors.extend(f"{path.name}: {error}" for error in validate_fixture(json.loads(path.read_text()), size))
    suggestion_path = output_dir / "suggestion-gold-v1.json"
    if not suggestion_path.exists():
        errors.append("missing fixture: suggestion-gold-v1.json")
    else:
        errors.extend(
            f"{suggestion_path.name}: {error}"
            for error in validate_suggestions(json.loads(suggestion_path.read_text()))
        )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT, help="fixture output directory")
    parser.add_argument("--check", action="store_true", help="validate existing generated fixtures")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    if not args.check:
        write_json(args.output / "organizer-100-v1.json", fixture(100))
        write_json(args.output / "organizer-500-v1.json", fixture(500))
        write_json(args.output / "suggestion-gold-v1.json", suggestion_corpus())
    errors = validate(args.output)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print("Organizer fixtures valid: organizer-100-v1, organizer-500-v1, suggestion-gold-v1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
