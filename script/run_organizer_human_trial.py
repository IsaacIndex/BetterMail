#!/usr/bin/env python3
"""Launch and preserve unaided BetterMail organizer timing trials safely.

This helper never sends keyboard, pointer, or accessibility input. It verifies
the installed signed bundle, launches one frozen benchmark phase, waits for the
human participant to quit the app, and copies the runtime report byte-for-byte
into a non-overwriting local capture directory.
"""

from __future__ import annotations

import argparse
import copy
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Iterable, Optional


APP_NAME = "BetterMail"
APP_BUNDLE_ID = "isaacwongnh.BetterMail"
EXTENSION_BUNDLE_ID = "isaacwongnh.BetterMail.MailHelperExtension"
TEAM_IDENTIFIER = "TN3L2WBKR5"
SIGNING_CERTIFICATE_SHA1 = "59D9099E689B4FCF247C0E2C021C3B62E80AE4B2"
FIXTURE_ID = "organizer-100-v1"
PROTOCOL_ID = "visual-email-organizer-v1"

APP_BUNDLE = Path.home() / "Applications" / "BetterMail.app"
APP_BINARY = APP_BUNDLE / "Contents" / "MacOS" / APP_NAME
EXTENSION_BUNDLE = (
    APP_BUNDLE / "Contents" / "PlugIns" / "MailHelperExtension.appex"
)
METRICS_ROOT = (
    Path.home()
    / "Library"
    / "Containers"
    / APP_BUNDLE_ID
    / "Data"
    / "Library"
    / "Application Support"
    / "BetterMail"
    / "OrganizerBenchmark"
    / FIXTURE_ID
)
CAPTURE_ROOT = Path("/tmp/bettermail-organizer-human-trials")
REPO_ROOT = Path(__file__).resolve().parents[1]
METRIC_SCHEMA_PATH = (
    REPO_ROOT / "docs" / "acceptance" / "visual-email-organizer" / "metric-schema-v1.json"
)
STATUS_SCHEMA_PATH = (
    REPO_ROOT
    / "docs"
    / "acceptance"
    / "visual-email-organizer"
    / "acceptance-status-schema-v1.json"
)
BASE_ACCEPTANCE_STATUS_PATH = (
    REPO_ROOT
    / "docs"
    / "acceptance"
    / "visual-email-organizer"
    / "results"
    / "acceptance-status-2026-08-28.json"
)
VALIDATOR_DIR = REPO_ROOT / "Tests" / "Fixtures" / "Organizer"

DATE_PATTERN = re.compile(r"^\d{8}$")
ORDINAL_PATTERN = re.compile(r"^\d{2}$")
MUTATION_EVENTS = {
    "action-start",
    "drop-intent",
    "drop-highlight",
    "drop-release",
    "drop-outcome",
    "group-committed",
    "bettermail-commit",
    "group-rethreaded",
    "rethread-complete",
    "group-visible",
    "visible-result",
    "suggestion-decision",
    "mail-authorization",
    "mail-result",
    "undo",
    "recovery",
}


class HarnessError(RuntimeError):
    """A fail-closed harness precondition or capture error."""


@dataclass(frozen=True)
class PhasePlan:
    name: str
    run_family: str
    task: str
    stratum: str
    reset: bool
    capture_stem: str
    expected_evidence_type: str
    prerequisite_phase: Optional[str] = None
    setup_only: bool = False

    def run_id(self, ordinal: str, capture_date: str) -> str:
        return f"synthetic-human-{self.run_family}-{ordinal}-{capture_date}"

    def capture_name(self, ordinal: str) -> str:
        return f"{self.capture_stem}-{ordinal}.json"


PHASES = {
    "first-warm": PhasePlan(
        "first-warm", "first-warm", "first-organization", "warm", True,
        "first-warm", "timed-human-task"
    ),
    "first-cold-setup": PhasePlan(
        "first-cold-setup", "first-cold", "diagnostic", "warm", True,
        "setup-first-cold", "accessibility-audit", setup_only=True
    ),
    "first-cold": PhasePlan(
        "first-cold", "first-cold", "first-organization", "cold-relaunch", False,
        "first-cold", "timed-human-task", prerequisite_phase="first-cold-setup"
    ),
    "five-warm": PhasePlan(
        "five-warm", "five-warm", "five-conversation-organization", "warm", True,
        "five-warm", "timed-human-task"
    ),
    "five-cold-setup": PhasePlan(
        "five-cold-setup", "five-cold", "diagnostic", "warm", True,
        "setup-five-cold", "accessibility-audit", setup_only=True
    ),
    "five-cold": PhasePlan(
        "five-cold", "five-cold", "five-conversation-organization", "cold-relaunch", False,
        "five-cold", "timed-human-task", prerequisite_phase="five-cold-setup"
    ),
    "retrieval-warm-source": PhasePlan(
        "retrieval-warm-source", "five-warm", "retrieval", "cold-relaunch", False,
        "retrieval-relaunch-warm-source", "timed-human-task",
        prerequisite_phase="five-warm"
    ),
    "retrieval-cold-source": PhasePlan(
        "retrieval-cold-source", "five-cold", "retrieval", "cold-relaunch", False,
        "retrieval-relaunch-cold-source", "timed-human-task",
        prerequisite_phase="five-cold"
    ),
}

PRIMARY_TIMING_KIND = {
    "first-organization": "firstAction",
    "five-conversation-organization": "fiveConversation",
    "retrieval": "retrieval",
}
TIMING_THRESHOLD = {
    "firstAction": 30_000,
    "fiveConversation": 120_000,
    "retrieval": 5_000,
}
TIMED_SLICE_ORDER = (
    ("first-organization", "warm"),
    ("first-organization", "cold-relaunch"),
    ("five-conversation-organization", "warm"),
    ("five-conversation-organization", "cold-relaunch"),
    ("retrieval", "post-commit"),
    ("retrieval", "post-relaunch"),
)
PASS_REQUIRED_EVENT_SEQUENCE_BY_TASK = {
    "first-organization": (
        "workspace-ready",
        "task-visible",
        "task-ready",
        "action-start",
        "bettermail-commit",
        "rethread-complete",
        "group-visible",
        "visible-result",
    ),
    "five-conversation-organization": (
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
    ),
    "retrieval": (
        "workspace-ready",
        "task-visible",
        "task-ready",
        "search-start",
        "retrieval-visible",
    ),
}
FAILED_EVENT_STATUSES = {"failure", "invalid", "cancelled"}


@dataclass(frozen=True)
class TimingObservation:
    task_id: str
    stratum: str
    status: str
    duration_milliseconds: Optional[int]


@dataclass(frozen=True)
class AdjudicatedCapture:
    plan: PhasePlan
    ordinal: str
    path: Path
    artifact: dict
    sanitized_record: dict
    primary_observation: TimingObservation
    post_commit_observation: Optional[TimingObservation] = None


def validate_capture_date(value: str) -> str:
    if DATE_PATTERN.fullmatch(value) is None:
        raise HarnessError("capture date must use YYYYMMDD")
    try:
        parsed = datetime.strptime(value, "%Y%m%d")
    except ValueError as error:
        raise HarnessError("capture date is not a real calendar date") from error
    if parsed.strftime("%Y%m%d") != value:
        raise HarnessError("capture date must use canonical YYYYMMDD")
    return value


def validate_ordinal(value: str) -> str:
    if ORDINAL_PATTERN.fullmatch(value) is None or value == "00":
        raise HarnessError("ordinal must be 01 through 99")
    return value


def command_for_phase(
    plan: PhasePlan,
    ordinal: str,
    capture_date: str,
    app_binary: Path = APP_BINARY,
) -> list[str]:
    command = [
        str(app_binary),
        "--organizer-benchmark-fixture",
        "100",
        "--organizer-benchmark-run",
        plan.run_id(ordinal, capture_date),
        "--organizer-benchmark-task",
        plan.task,
        "--organizer-benchmark-stratum",
        plan.stratum,
    ]
    if plan.reset:
        command.append("--organizer-benchmark-reset")
    return command


def capture_path_for(
    plan: PhasePlan,
    ordinal: str,
    capture_date: str,
    capture_root: Path = CAPTURE_ROOT,
) -> Path:
    return capture_root / capture_date / plan.capture_name(ordinal)


def runtime_report_path(
    plan: PhasePlan,
    ordinal: str,
    capture_date: str,
    metrics_root: Path = METRICS_ROOT,
) -> Path:
    return (
        metrics_root
        / plan.run_id(ordinal, capture_date)
        / "OrganizerMetrics.json"
    )


def copy_bytes_exclusive(source: Path, destination: Path) -> bytes:
    if not source.is_file():
        raise HarnessError(f"runtime report does not exist: {source}")
    raw = source.read_bytes()
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        with destination.open("xb") as output:
            output.write(raw)
    except FileExistsError as error:
        raise HarnessError(f"capture already exists; refusing to overwrite: {destination}") from error
    if destination.read_bytes() != raw:
        raise HarnessError(f"capture bytes differ from runtime report: {destination}")
    return raw


def file_sha256(path: Path) -> str:
    if not path.is_file():
        raise HarnessError(f"expected file does not exist: {path}")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_fresh_runtime_report(
    source: Path,
    previous_sha256: Optional[str],
) -> None:
    if not source.is_file():
        raise HarnessError(f"runtime report does not exist after app exit: {source}")
    if previous_sha256 is not None and file_sha256(source) == previous_sha256:
        raise HarnessError(
            "continuation launch did not rewrite OrganizerMetrics.json; refusing to capture stale evidence"
        )


def _event_names(record: dict) -> list[str]:
    events = record.get("eventSummary")
    if not isinstance(events, list):
        return []
    return [
        event.get("event")
        for event in events
        if isinstance(event, dict) and isinstance(event.get("event"), str)
    ]


def _successful_event(record: dict, event_name: str) -> bool:
    events = record.get("eventSummary")
    if not isinstance(events, list):
        return False
    return any(
        isinstance(event, dict)
        and event.get("event") == event_name
        and event.get("status") == "success"
        for event in events
    )


def successful_lifecycle_errors(record: dict, task_id: str) -> list[str]:
    required = PASS_REQUIRED_EVENT_SEQUENCE_BY_TASK.get(task_id)
    if required is None:
        return [f"no successful lifecycle contract exists for {task_id}"]
    events = record.get("eventSummary")
    if not isinstance(events, list):
        return ["record eventSummary must be an array"]
    observed = [event for event in events if isinstance(event, dict)]
    observed_names = [event.get("event") for event in observed]
    errors: list[str] = []

    cursor = 0
    for required_event in required:
        while cursor < len(observed_names) and observed_names[cursor] != required_event:
            cursor += 1
        if cursor == len(observed_names):
            errors.append(
                "successful lifecycle is missing or misorders " + required_event
            )
            break
        cursor += 1

    if any(
        event.get("event") in {"failure", "cancelled"}
        or event.get("status") in FAILED_EVENT_STATUSES
        for event in observed
    ):
        errors.append("successful lifecycle contains a failed or cancelled event")
    if not _successful_event(record, required[-1]):
        errors.append(f"successful lifecycle lacks successful {required[-1]}")
    return errors


def is_pre_task_ready_invalid(record: object) -> bool:
    if not isinstance(record, dict):
        return False
    event_names = _event_names(record)
    return (
        "task-ready" not in event_names
        and record.get("status") in {"pending", "invalid"}
        and record.get("mailCallCount") == 0
        and record.get("normalizedCommandCount") == 0
        and not (set(event_names) & MUTATION_EVENTS)
    )


def context_errors(
    artifact: object,
    plan: PhasePlan,
    ordinal: str,
    capture_date: str,
) -> list[str]:
    errors: list[str] = []
    if not isinstance(artifact, dict):
        return ["report root must be an object"]

    expected_run_id = plan.run_id(ordinal, capture_date)
    expected_top = {
        "runId": expected_run_id,
        "fixtureId": FIXTURE_ID,
        "protocolId": PROTOCOL_ID,
        "evidenceType": plan.expected_evidence_type,
    }
    for field, expected in expected_top.items():
        if artifact.get(field) != expected:
            errors.append(f"{field} must be {expected}")

    records = artifact.get("records")
    if not isinstance(records, list) or len(records) != 1 or not isinstance(records[0], dict):
        return errors + ["report must contain exactly one aggregate trial record"]
    record = records[0]
    expected_record = {
        "trialId": expected_run_id,
        "taskId": plan.task,
        "stratum": plan.stratum,
    }
    for field, expected in expected_record.items():
        if record.get(field) != expected:
            errors.append(f"record {field} must be {expected}")

    if artifact.get("status") != record.get("status"):
        errors.append("top-level and record status must match")
    if artifact.get("eventSummary") != record.get("eventSummary"):
        errors.append("top-level and record eventSummary must match")

    if record.get("mailCallCount") != 0:
        errors.append("record mailCallCount must remain zero")
    event_names = _event_names(record)
    if "mail-authorization" in event_names or "mail-result" in event_names:
        errors.append("synthetic trial must not contain external Mail events")
    task_ready_count = event_names.count("task-ready")
    if task_ready_count != 1:
        if (
            task_ready_count == 0
            and not plan.setup_only
            and is_pre_task_ready_invalid(record)
        ):
            return errors
        errors.append("report must contain exactly one task-ready event")

    if plan.setup_only:
        if record.get("normalizedCommandCount") != 0:
            errors.append("cold setup must not contain normalized commands")
        observed_mutations = sorted(set(event_names) & MUTATION_EVENTS)
        if observed_mutations:
            errors.append(
                "cold setup contains mutation events: " + ", ".join(observed_mutations)
            )
        return errors

    terminal = (
        "visible-result"
        if plan.task == "first-organization"
        else "retrieval-visible"
    )
    if _successful_event(record, terminal):
        if record.get("status") not in {"pass", "insufficient-evidence"}:
            errors.append(
                "successful terminal lifecycle requires pass or insufficient-evidence status"
            )
        errors.extend(successful_lifecycle_errors(record, plan.task))
    elif record.get("status") in {"pass", "insufficient-evidence"}:
        errors.append(
            f"completed status lacks successful {terminal}; report is internally inconsistent"
        )
    elif record.get("status") == "invalid":
        errors.append("post-task-ready invalid trial must be reported as a failure")
    return errors


def schema_errors(artifact: dict, path: Path) -> list[str]:
    if str(VALIDATOR_DIR) not in sys.path:
        sys.path.insert(0, str(VALIDATOR_DIR))
    from validate_benchmark import validate_metric_result  # type: ignore

    metric_schema = json.loads(METRIC_SCHEMA_PATH.read_text(encoding="utf-8"))
    return validate_metric_result(path, artifact, metric_schema)


def decode_and_validate(
    raw: bytes,
    source_path: Path,
    plan: PhasePlan,
    ordinal: str,
    capture_date: str,
    include_schema: bool = True,
) -> tuple[Optional[dict], list[str]]:
    try:
        artifact = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        return None, [f"report is not valid UTF-8 JSON: {error}"]
    errors = context_errors(artifact, plan, ordinal, capture_date)
    if include_schema and isinstance(artifact, dict):
        errors = schema_errors(artifact, source_path) + errors
    return artifact if isinstance(artifact, dict) else None, errors


def _run_checked(command: list[str], description: str) -> str:
    result = subprocess.run(command, capture_output=True, text=True)
    output = (result.stdout or "") + (result.stderr or "")
    if result.returncode != 0:
        detail = output.strip() or f"exit {result.returncode}"
        raise HarnessError(f"{description} failed: {detail}")
    return output


def _bundle_identifier(bundle: Path) -> str:
    return _run_checked(
        ["plutil", "-extract", "CFBundleIdentifier", "raw", str(bundle / "Contents" / "Info.plist")],
        f"read bundle identifier for {bundle.name}",
    ).strip()


def validate_signature_details(
    details: str,
    bundle_name: str,
    expected_bundle_id: str,
) -> None:
    if "Signature=adhoc" in details:
        raise HarnessError(f"{bundle_name} is ad-hoc signed")
    if f"TeamIdentifier={TEAM_IDENTIFIER}" not in details:
        raise HarnessError(
            f"{bundle_name} does not report TeamIdentifier={TEAM_IDENTIFIER}"
        )
    signed_identifier = next(
        (
            line.partition("=")[2].strip()
            for line in details.splitlines()
            if line.startswith("Identifier=")
        ),
        None,
    )
    if signed_identifier != expected_bundle_id:
        raise HarnessError(
            f"{bundle_name} signed Identifier is {signed_identifier}, expected {expected_bundle_id}"
        )


def verify_signed_bundle(bundle: Path, expected_bundle_id: str) -> None:
    if not bundle.is_dir():
        raise HarnessError(f"installed bundle is missing: {bundle}")
    _run_checked(
        ["codesign", "--verify", "--deep", "--strict", "--verbose=4", str(bundle)],
        f"deep strict verification for {bundle.name}",
    )
    details = _run_checked(
        ["codesign", "-dvvv", str(bundle)],
        f"signature inspection for {bundle.name}",
    )
    validate_signature_details(details, bundle.name, expected_bundle_id)
    actual_bundle_id = _bundle_identifier(bundle)
    if actual_bundle_id != expected_bundle_id:
        raise HarnessError(
            f"{bundle.name} bundle ID is {actual_bundle_id}, expected {expected_bundle_id}"
        )

    with tempfile.TemporaryDirectory(prefix="bettermail-human-trial-signature.") as temp_dir:
        prefix = Path(temp_dir) / "codesign"
        _run_checked(
            ["codesign", "-d", f"--extract-certificates={prefix}", str(bundle)],
            f"certificate extraction for {bundle.name}",
        )
        leaf = Path(f"{prefix}0")
        intermediate = Path(f"{prefix}1")
        if not leaf.is_file() or not intermediate.is_file():
            raise HarnessError(f"{bundle.name} has an incomplete signing certificate chain")
        _run_checked(
            [
                "security", "verify-cert", "-c", str(leaf), "-c", str(intermediate),
                "-p", "codeSign", "-N", "-L",
            ],
            f"certificate trust verification for {bundle.name}",
        )
        fingerprint = _run_checked(
            [
                "openssl", "x509", "-inform", "DER", "-in", str(leaf),
                "-noout", "-fingerprint", "-sha1",
            ],
            f"leaf certificate fingerprint for {bundle.name}",
        )
        actual_sha1 = fingerprint.partition("=")[2].replace(":", "").strip().upper()
        if actual_sha1 != SIGNING_CERTIFICATE_SHA1:
            raise HarnessError(
                f"{bundle.name} uses certificate {actual_sha1}, expected {SIGNING_CERTIFICATE_SHA1}"
            )


def verify_installed_signing() -> str:
    verify_signed_bundle(EXTENSION_BUNDLE, EXTENSION_BUNDLE_ID)
    verify_signed_bundle(APP_BUNDLE, APP_BUNDLE_ID)
    if not APP_BINARY.is_file():
        raise HarnessError(f"installed executable is missing: {APP_BINARY}")
    return hashlib.sha256(APP_BINARY.read_bytes()).hexdigest()


def ensure_app_not_running() -> None:
    result = subprocess.run(
        ["pgrep", "-x", APP_NAME], capture_output=True, text=True
    )
    if result.returncode == 0:
        process_ids = " ".join(result.stdout.split())
        raise HarnessError(
            f"{APP_NAME} is already running (PID {process_ids}); quit it before this phase"
        )
    if result.returncode != 1:
        raise HarnessError(f"could not determine whether {APP_NAME} is running")


def preflight_installed_trial() -> str:
    """Verify trial readiness without launching the app or creating evidence."""
    ensure_app_not_running()
    executable_sha256 = verify_installed_signing()
    print("Installed app and extension are ready for an unaided trial.")
    print(f"Team Identifier: {TEAM_IDENTIFIER}")
    print(f"Signing certificate SHA-1: {SIGNING_CERTIFICATE_SHA1}")
    print(f"Installed app executable SHA-256: {executable_sha256}")
    print("No app launch, capture, session manifest, or Mail mutation occurred.")
    return executable_sha256


def session_manifest(executable_sha256: str, capture_date: str) -> dict:
    return {
        "schemaVersion": "bettermail-organizer-human-session-v1",
        "captureDate": capture_date,
        "appExecutableSHA256": executable_sha256,
        "teamIdentifier": TEAM_IDENTIFIER,
        "signingCertificateSHA1": SIGNING_CERTIFICATE_SHA1,
        "appBundleIdentifier": APP_BUNDLE_ID,
        "extensionBundleIdentifier": EXTENSION_BUNDLE_ID,
        "fixtureId": FIXTURE_ID,
        "protocolId": PROTOCOL_ID,
        "unaidedHumanActionAttestation": True,
    }


def validate_session_manifest(path: Path, capture_date: str) -> list[str]:
    try:
        actual = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return ["capture session is missing session-manifest.json"]
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        return [f"session manifest is unreadable: {error}"]
    if not isinstance(actual, dict):
        return ["session manifest root must be an object"]

    expected = session_manifest("0" * 64, capture_date)
    errors: list[str] = []
    if set(actual) != set(expected):
        errors.append("session manifest fields do not match the closed contract")
    for field, expected_value in expected.items():
        if field == "appExecutableSHA256":
            digest = actual.get(field)
            if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
                errors.append("session manifest appExecutableSHA256 is invalid")
        elif actual.get(field) != expected_value:
            errors.append(f"session manifest {field} must be {expected_value}")
    return errors


def ensure_session_manifest(
    executable_sha256: str,
    capture_date: str,
    capture_root: Path = CAPTURE_ROOT,
) -> Path:
    session_dir = capture_root / capture_date
    session_dir.mkdir(parents=True, exist_ok=True)
    path = session_dir / "session-manifest.json"
    expected = session_manifest(executable_sha256, capture_date)
    if path.exists():
        try:
            actual = json.loads(path.read_text(encoding="utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise HarnessError(f"session manifest is unreadable: {path}") from error
        if actual != expected:
            raise HarnessError(
                "installed app identity differs from this capture session; start a new capture date"
            )
        return path
    encoded = (json.dumps(expected, indent=2, sort_keys=True) + "\n").encode("utf-8")
    try:
        with path.open("xb") as output:
            output.write(encoded)
    except FileExistsError as error:
        raise HarnessError(f"session manifest appeared concurrently: {path}") from error
    return path


def prerequisite_capture(
    plan: PhasePlan,
    ordinal: str,
    capture_date: str,
    capture_root: Path = CAPTURE_ROOT,
) -> Optional[Path]:
    if plan.prerequisite_phase is None:
        return None
    prerequisite_plan = PHASES[plan.prerequisite_phase]
    return capture_path_for(prerequisite_plan, ordinal, capture_date, capture_root)


def verify_prerequisite(
    plan: PhasePlan,
    ordinal: str,
    capture_date: str,
    capture_root: Path = CAPTURE_ROOT,
) -> None:
    path = prerequisite_capture(plan, ordinal, capture_date, capture_root)
    if path is None:
        return
    if not path.is_file():
        raise HarnessError(f"required prior capture is missing: {path}")
    prerequisite_plan = PHASES[plan.prerequisite_phase or ""]
    artifact, errors = decode_and_validate(
        path.read_bytes(), path, prerequisite_plan, ordinal, capture_date
    )
    if errors:
        raise HarnessError(
            f"required prior capture is invalid: {path}\n- " + "\n- ".join(errors)
        )
    if plan.task == "retrieval":
        assert artifact is not None
        source_record = artifact["records"][0]
        lifecycle_errors = successful_lifecycle_errors(
            source_record,
            prerequisite_plan.task,
        )
        if (
            source_record.get("status") not in {"pass", "insufficient-evidence"}
            or lifecycle_errors
        ):
            detail = "; ".join(lifecycle_errors)
            raise HarnessError(
                "retrieval source did not complete five-conversation organization: "
                + str(path)
                + (f" ({detail})" if detail else "")
            )
        try:
            source_capture = adjudicate_capture(
                prerequisite_plan, ordinal, path, artifact
            )
        except HarnessError as error:
            raise HarnessError(
                "retrieval source did not complete five-conversation organization: "
                + str(path)
                + f" ({error})"
            ) from error
        if source_capture.primary_observation.status != "pass":
            raise HarnessError(
                "retrieval source did not complete five-conversation organization: "
                + str(path)
            )


def participant_instructions(plan: PhasePlan) -> str:
    common = (
        "VoiceOver must remain off. Do not use scripted, agent, or accessibility automation. "
        "Confirm the Ready banner says Apple Mail locked and External Mail calls: 0."
    )
    if plan.setup_only:
        return common + " Wait for Ready, then quit without organizing anything."
    if plan.task == "first-organization":
        return common + " Move Synthetic conversation 0001 to Confirmed Group 01, wait for the visible result, then quit."
    if plan.task == "five-conversation-organization":
        return common + (
            " Move conversations 0001, 0002, 0003, 0004, and 0005 to "
            "Confirmed Group 01, Confirmed Group 02, Nested Group 01, "
            "Nested Group 02, and Confirmed Group 03 respectively. Then enter "
            "synthetic-query-organized-0004, wait for conversation 0005 to be "
            "selectable, and quit."
        )
    return common + (
        " Enter synthetic-query-organized-0004, wait for Synthetic conversation "
        "0005 to be selectable, then quit."
    )


def run_phase(
    phase_name: str,
    ordinal: str,
    capture_date: str,
    attest_unaided: bool,
    dry_run: bool = False,
    capture_root: Path = CAPTURE_ROOT,
    metrics_root: Path = METRICS_ROOT,
) -> Path:
    if not attest_unaided:
        raise HarnessError(
            "--attest-unaided is required; only unaided human UI actions are eligible"
        )
    if phase_name not in PHASES:
        raise HarnessError(f"unknown phase: {phase_name}")
    ordinal = validate_ordinal(ordinal)
    capture_date = validate_capture_date(capture_date)
    plan = PHASES[phase_name]
    destination = capture_path_for(plan, ordinal, capture_date, capture_root)
    source = runtime_report_path(plan, ordinal, capture_date, metrics_root)
    if destination.exists():
        raise HarnessError(f"capture already exists; refusing to overwrite: {destination}")

    command = command_for_phase(plan, ordinal, capture_date)
    if dry_run:
        print("Dry run only; no app launch, signature check, or capture occurred.")
        print("Command:", subprocess.list2cmdline(command))
        print("Runtime report:", source)
        print("Capture:", destination)
        return destination

    verify_prerequisite(plan, ordinal, capture_date, capture_root)
    if plan.reset and source.exists():
        raise HarnessError(
            f"fresh run ID already has runtime state; use a new ordinal: {source.parent.name}"
        )
    if not plan.reset and not source.exists():
        raise HarnessError(f"continuation runtime state is missing: {source}")

    previous_report_sha256 = file_sha256(source) if not plan.reset else None

    ensure_app_not_running()
    executable_sha256 = verify_installed_signing()
    manifest_path = ensure_session_manifest(executable_sha256, capture_date, capture_root)
    print(f"Verified signed app and extension; session manifest: {manifest_path}")
    print(participant_instructions(plan))
    print("The helper is waiting for BetterMail to exit and will not send UI input.")
    process = subprocess.run(command)

    require_fresh_runtime_report(source, previous_report_sha256)
    raw = copy_bytes_exclusive(source, destination)
    artifact, errors = decode_and_validate(
        raw, destination, plan, ordinal, capture_date
    )
    if artifact is not None:
        records = artifact.get("records")
        record = records[0] if isinstance(records, list) and records else None
        if is_pre_task_ready_invalid(record):
            errors.append(
                "trial is invalid before task-ready; retain it and use a replacement ordinal"
            )
    if process.returncode != 0:
        errors.insert(0, f"BetterMail exited with status {process.returncode}")
    if errors:
        raise HarnessError(
            f"raw capture was preserved at {destination}, but it needs adjudication:\n- "
            + "\n- ".join(errors)
        )
    assert artifact is not None
    print(f"Captured byte-for-byte: {destination}")
    print(f"Runtime status: {artifact.get('status')}")
    return destination


def _capture_phase_from_name(filename: str) -> tuple[Optional[PhasePlan], Optional[str]]:
    for plan in PHASES.values():
        match = re.fullmatch(re.escape(plan.capture_stem) + r"-(\d{2})\.json", filename)
        if match:
            return plan, match.group(1)
    return None, None


def _timing_entry(artifact: dict, kind: str, stratum: str) -> Optional[dict]:
    entries = artifact.get("timing")
    if not isinstance(entries, list):
        raise HarnessError("raw report timing must be an array")
    matches = [
        entry
        for entry in entries
        if isinstance(entry, dict)
        and entry.get("kind") == kind
        and entry.get("stratum") == stratum
    ]
    if len(matches) != 1:
        raise HarnessError(
            f"raw report must contain exactly one {kind}/{stratum} timing entry"
        )
    return matches[0]


def observation_from_timing_entry(
    entry: dict,
    task_id: str,
    output_stratum: str,
) -> Optional[TimingObservation]:
    sample_count = entry.get("sampleCount")
    valid_count = entry.get("validTrialCount")
    invalid_count = entry.get("invalidCount")
    if sample_count == 0:
        return None
    if sample_count != 1:
        raise HarnessError("one raw capture must contain exactly one timing sample")
    if invalid_count == 1 and valid_count == 0:
        return TimingObservation(task_id, output_stratum, "invalid", None)
    if valid_count != 1 or invalid_count != 0:
        raise HarnessError("raw timing sample has inconsistent valid/invalid counts")

    percentiles = [
        entry.get("medianMilliseconds"),
        entry.get("p80Milliseconds"),
        entry.get("p90Milliseconds"),
    ]
    if not all(isinstance(value, int) and value >= 0 for value in percentiles):
        raise HarnessError("valid raw timing sample lacks integer percentiles")
    if len(set(percentiles)) != 1:
        raise HarnessError("single raw timing sample has inconsistent percentiles")
    duration = percentiles[0]
    success_count = entry.get("successCount")
    failed_count = entry.get("failureCount", 0) + entry.get("cancelledCount", 0)
    if success_count == 1 and failed_count == 0:
        status = "pass"
    elif success_count == 0 and failed_count == 1:
        status = "fail"
        duration = max(duration, TIMING_THRESHOLD[entry["kind"]] + 1)
    else:
        raise HarnessError("raw timing sample has inconsistent outcome counts")
    return TimingObservation(task_id, output_stratum, status, duration)


def _failure_reason(record: dict, event_names: list[str]) -> str:
    allowed = {
        "instrumentation-before-task-ready",
        "cancelled",
        "action-failure",
        "wrong-completion",
        "app-termination",
        "missing-rethread",
        "missing-visible-confirmation",
        "missing-retrieval",
        "unresolved-outcome",
        "invalid-target",
    }
    raw_reason = record.get("coarseFailureReason")
    if raw_reason in allowed:
        return raw_reason
    if "cancelled" in event_names:
        return "cancelled"
    if "failure" in event_names:
        return "action-failure"
    return "app-termination"


def adjudicate_capture(
    plan: PhasePlan,
    ordinal: str,
    path: Path,
    artifact: dict,
) -> AdjudicatedCapture:
    records = artifact.get("records")
    if not isinstance(records, list) or len(records) != 1 or not isinstance(records[0], dict):
        raise HarnessError(f"{path.name} does not contain one raw trial record")
    record = records[0]
    event_names = _event_names(record)
    raw_stratum = plan.stratum
    output_stratum = "post-relaunch" if plan.task == "retrieval" else raw_stratum
    primary_kind = PRIMARY_TIMING_KIND[plan.task]
    timing_entry = _timing_entry(artifact, primary_kind, raw_stratum)
    recorded_observation = observation_from_timing_entry(
        timing_entry, plan.task, output_stratum
    )

    if is_pre_task_ready_invalid(record):
        primary = TimingObservation(plan.task, output_stratum, "invalid", None)
        reason = "instrumentation-before-task-ready"
    else:
        terminal = (
            "visible-result"
            if plan.task == "first-organization"
            else "retrieval-visible"
        )
        raw_status = record.get("status")
        if raw_status == "invalid":
            raise HarnessError(
                f"{path.name} reports invalid after task-ready; frozen protocol requires failure"
            )
        if raw_status == "fail" or not _successful_event(record, terminal):
            if recorded_observation is not None and recorded_observation.status == "pass":
                raise HarnessError(
                    f"{path.name} has a passing timing sample without a successful terminal lifecycle"
                )
            duration = (
                recorded_observation.duration_milliseconds
                if recorded_observation is not None
                else TIMING_THRESHOLD[primary_kind] + 1
            )
            primary = TimingObservation(plan.task, output_stratum, "fail", duration)
            reason = _failure_reason(record, event_names)
        else:
            if recorded_observation is None or recorded_observation.status != "pass":
                raise HarnessError(
                    f"{path.name} successful lifecycle lacks one successful timing sample"
                )
            primary = recorded_observation
            reason = None

    trial_id = record.get("trialId")
    if plan.task == "retrieval":
        trial_id = f"{trial_id}-retrieval-relaunch"
    sanitized_record = {
        "trialId": trial_id,
        "appBuild": artifact.get("appBuild"),
        "evidenceType": "timed-human-task",
        "taskId": plan.task,
        "sourceNodeKeys": copy.deepcopy(record.get("sourceNodeKeys")),
        "destinationGroupKeys": copy.deepcopy(record.get("destinationGroupKeys")),
        "queryKey": record.get("queryKey"),
        "stratum": output_stratum,
        "status": primary.status,
        "targetOutcome": record.get("targetOutcome"),
        "mailCallCount": record.get("mailCallCount"),
        "normalizedCommandCount": record.get("normalizedCommandCount"),
        "eventSummary": copy.deepcopy(record.get("eventSummary")),
    }
    if primary.duration_milliseconds is not None:
        sanitized_record["durationMilliseconds"] = primary.duration_milliseconds
    if reason is not None:
        sanitized_record["coarseFailureReason"] = reason

    post_commit: Optional[TimingObservation] = None
    if plan.task == "five-conversation-organization":
        retrieval_entry = _timing_entry(artifact, "retrieval", raw_stratum)
        raw_retrieval = observation_from_timing_entry(
            retrieval_entry, "retrieval", "post-commit"
        )
        if primary.status == "invalid":
            post_commit = TimingObservation(
                "retrieval", "post-commit", "invalid", None
            )
        elif raw_retrieval is not None:
            if raw_retrieval.status == "invalid":
                raise HarnessError(
                    f"{path.name} has an invalid retrieval sample after task-ready"
                )
            post_commit = raw_retrieval

    return AdjudicatedCapture(
        plan=plan,
        ordinal=ordinal,
        path=path,
        artifact=artifact,
        sanitized_record=sanitized_record,
        primary_observation=primary,
        post_commit_observation=post_commit,
    )


def collect_adjudicated_captures(
    capture_date: str,
    capture_root: Path = CAPTURE_ROOT,
) -> list[AdjudicatedCapture]:
    capture_date = validate_capture_date(capture_date)
    session_dir = capture_root / capture_date
    manifest_errors = validate_session_manifest(
        session_dir / "session-manifest.json", capture_date
    )
    if manifest_errors:
        raise HarnessError("invalid capture session:\n- " + "\n- ".join(manifest_errors))

    decoded: list[tuple[PhasePlan, str, Path, dict]] = []
    for path in sorted(session_dir.glob("*.json")):
        if path.name == "session-manifest.json":
            continue
        plan, ordinal = _capture_phase_from_name(path.name)
        if plan is None or ordinal is None:
            raise HarnessError(f"unknown capture filename: {path.name}")
        artifact, errors = decode_and_validate(
            path.read_bytes(), path, plan, ordinal, capture_date
        )
        if errors or artifact is None:
            raise HarnessError(
                f"invalid raw capture {path.name}:\n- "
                + "\n- ".join(errors or ["unreadable artifact"])
            )
        decoded.append((plan, ordinal, path, artifact))

    for plan, ordinal, path, _ in decoded:
        if plan.prerequisite_phase is None:
            continue
        try:
            verify_prerequisite(plan, ordinal, capture_date, capture_root)
        except HarnessError as error:
            raise HarnessError(f"{path.name}: {error}") from error

    timed = [
        adjudicate_capture(plan, ordinal, path, artifact)
        for plan, ordinal, path, artifact in decoded
        if not plan.setup_only
    ]
    app_builds = {
        artifact.get("appBuild")
        for _, _, _, artifact in decoded
        if isinstance(artifact.get("appBuild"), str)
    }
    if len(app_builds) > 1:
        raise HarnessError(
            "capture session mixes appBuild values, including setup evidence: "
            + ", ".join(sorted(app_builds))
        )
    trial_ids = [capture.sanitized_record["trialId"] for capture in timed]
    if len(trial_ids) != len(set(trial_ids)):
        raise HarnessError("sanitized timed captures contain duplicate trial IDs")
    return timed


def nearest_rank(values: list[int], percentile: float) -> Optional[int]:
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(percentile * len(ordered)))
    return ordered[min(rank, len(ordered)) - 1]


def summarize_timing_slice(
    task_id: str,
    stratum: str,
    observations: list[TimingObservation],
) -> dict:
    valid = [observation for observation in observations if observation.status != "invalid"]
    durations = [
        observation.duration_milliseconds
        for observation in valid
        if isinstance(observation.duration_milliseconds, int)
    ]
    if len(durations) != len(valid):
        raise HarnessError(f"{task_id}/{stratum} has a valid trial without a duration")
    kind = PRIMARY_TIMING_KIND[task_id]
    threshold = TIMING_THRESHOLD[kind]
    within_count = sum(duration <= threshold for duration in durations)
    return {
        "taskId": task_id,
        "stratum": stratum,
        "validTrialCount": len(valid),
        "successCount": sum(observation.status == "pass" for observation in valid),
        "medianMilliseconds": nearest_rank(durations, 0.50),
        "p80Milliseconds": nearest_rank(durations, 0.80),
        "p90Milliseconds": nearest_rank(durations, 0.90),
        "thresholdMilliseconds": threshold,
        "withinThresholdCount": within_count,
        "withinThresholdRate": within_count / len(valid) if valid else 0,
    }


def build_timed_gate(
    captures: list[AdjudicatedCapture],
) -> tuple[dict, list[str]]:
    observations: dict[tuple[str, str], list[TimingObservation]] = {
        key: [] for key in TIMED_SLICE_ORDER
    }
    issues: list[str] = []
    for capture in captures:
        primary = capture.primary_observation
        observations[(primary.task_id, primary.stratum)].append(primary)
        if capture.plan.task == "five-conversation-organization":
            if capture.post_commit_observation is None:
                issues.append(
                    f"{capture.path.name} is missing its post-commit retrieval sample"
                )
            else:
                observations[("retrieval", "post-commit")].append(
                    capture.post_commit_observation
                )

    strata = [
        summarize_timing_slice(task_id, stratum, observations[(task_id, stratum)])
        for task_id, stratum in TIMED_SLICE_ORDER
    ]
    by_key = {(entry["taskId"], entry["stratum"]): entry for entry in strata}
    required = {
        ("first-organization", "warm"): 10,
        ("first-organization", "cold-relaunch"): 10,
        ("five-conversation-organization", "warm"): 10,
        ("five-conversation-organization", "cold-relaunch"): 10,
        ("retrieval", "post-commit"): 20,
        ("retrieval", "post-relaunch"): 20,
    }
    complete = True
    for key, minimum in required.items():
        count = by_key[key]["validTrialCount"]
        if count < minimum:
            complete = False
            issues.append(
                f"{key[0]}/{key[1]} has {count} valid trials; at least {minimum} required"
            )

    if complete:
        passed = all(
            (
                entry["withinThresholdRate"] >= 0.95
                if entry["taskId"] == "retrieval"
                else entry["p80Milliseconds"] <= entry["thresholdMilliseconds"]
            )
            for entry in strata
        )
        status = "pass" if passed else "fail"
    else:
        status = "pending"

    gate = {
        "status": status,
        "validFirstOrganizationTrials": sum(
            by_key[("first-organization", stratum)]["validTrialCount"]
            for stratum in ("warm", "cold-relaunch")
        ),
        "validFiveConversationTrials": sum(
            by_key[("five-conversation-organization", stratum)]["validTrialCount"]
            for stratum in ("warm", "cold-relaunch")
        ),
        "validPostCommitRetrievalTrials": by_key[("retrieval", "post-commit")]["validTrialCount"],
        "validPostRelaunchRetrievalTrials": by_key[("retrieval", "post-relaunch")]["validTrialCount"],
        "strata": strata,
    }
    return gate, issues


def propose_acceptance_status(
    base: dict,
    captures: list[AdjudicatedCapture],
    capture_date: str,
) -> tuple[dict, list[str]]:
    if base.get("fixtureId") != FIXTURE_ID:
        raise HarnessError(
            f"base acceptance status fixtureId must be {FIXTURE_ID}"
        )
    if base.get("protocolId") != PROTOCOL_ID:
        raise HarnessError(
            f"base acceptance status protocolId must be {PROTOCOL_ID}"
        )
    proposed = copy.deepcopy(base)
    existing_timed = [
        record
        for record in proposed.get("records", [])
        if isinstance(record, dict) and record.get("evidenceType") == "timed-human-task"
    ]
    if existing_timed:
        raise HarnessError("base acceptance status already contains timed-human records")
    app_builds = {
        capture.artifact.get("appBuild")
        for capture in captures
        if isinstance(capture.artifact.get("appBuild"), str)
    }
    if len(app_builds) > 1:
        raise HarnessError("cannot propose acceptance status from mixed app builds")
    if app_builds and proposed.get("appBuild") not in app_builds:
        raise HarnessError(
            f"capture appBuild does not match base acceptance status {proposed.get('appBuild')}"
        )

    timed_gate, issues = build_timed_gate(captures)
    proposed["records"] = proposed.get("records", []) + [
        copy.deepcopy(capture.sanitized_record) for capture in captures
    ]
    proposed["gateStatus"]["timedHumanTasks"] = timed_gate
    invalid_ids = sorted(
        capture.sanitized_record["trialId"]
        for capture in captures
        if capture.primary_observation.status == "invalid"
    )
    proposed["invalidTrials"] = sorted(
        set(proposed.get("invalidTrials", [])) | set(invalid_ids)
    )
    proposed["invalidTrialReasonCode"] = "invalid-trials-disclosed"
    proposed["generatedAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )
    proposed["runId"] = f"synthetic-installed-audit-{capture_date}"

    timed_targets = {
        "timed-human-first-organization-warm-and-cold",
        "timed-human-five-conversation-warm-and-cold",
        "timed-human-retrieval-post-commit-and-post-relaunch",
    }
    unmet = set(proposed.get("unmetTargets", []))
    if timed_gate["status"] == "pass":
        unmet -= timed_targets
    else:
        unmet |= timed_targets
    proposed["unmetTargets"] = [
        value
        for value in base.get("unmetTargets", [])
        if value in unmet
    ] + sorted(unmet - set(base.get("unmetTargets", [])))

    gate_statuses = [
        gate.get("status")
        for gate in proposed.get("gateStatus", {}).values()
        if isinstance(gate, dict)
    ]
    if "fail" in gate_statuses:
        proposed["status"] = "fail"
    elif gate_statuses and all(status == "pass" for status in gate_statuses) and not unmet:
        proposed["status"] = "pass"
    else:
        proposed["status"] = "insufficient-evidence"
    return proposed, issues


def validate_proposed_acceptance_status(path: Path, artifact: dict) -> list[str]:
    if str(VALIDATOR_DIR) not in sys.path:
        sys.path.insert(0, str(VALIDATOR_DIR))
    from validate_benchmark import (  # type: ignore
        validate_acceptance_status,
        validate_result_privacy,
    )

    metric_schema = json.loads(METRIC_SCHEMA_PATH.read_text(encoding="utf-8"))
    status_schema = json.loads(STATUS_SCHEMA_PATH.read_text(encoding="utf-8"))
    return validate_result_privacy(path, artifact, metric_schema) + validate_acceptance_status(
        path, artifact, metric_schema, status_schema
    )


def write_json_exclusive(path: Path, artifact: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(artifact, indent=2, sort_keys=False) + "\n").encode("utf-8")
    try:
        with path.open("xb") as output:
            output.write(encoded)
    except FileExistsError as error:
        raise HarnessError(f"aggregate output already exists: {path}") from error


def aggregate_human_session(
    capture_date: str,
    capture_root: Path = CAPTURE_ROOT,
    output: Optional[Path] = None,
    base_path: Path = BASE_ACCEPTANCE_STATUS_PATH,
) -> tuple[Path, dict, list[str]]:
    capture_date = validate_capture_date(capture_date)
    captures = collect_adjudicated_captures(capture_date, capture_root)
    try:
        base = json.loads(base_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise HarnessError(f"base acceptance status is unreadable: {base_path}") from error
    proposed, issues = propose_acceptance_status(base, captures, capture_date)
    output_path = output or (
        capture_root
        / capture_date
        / "aggregate"
        / (
            "acceptance-status-proposed-"
            + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            + ".json"
        )
    )
    validation_errors = validate_proposed_acceptance_status(output_path, proposed)
    if validation_errors:
        raise HarnessError(
            "proposed acceptance status failed validation:\n- "
            + "\n- ".join(validation_errors)
        )
    write_json_exclusive(output_path, proposed)
    return output_path, proposed["gateStatus"]["timedHumanTasks"], issues


def audit_session(
    capture_date: str,
    capture_root: Path = CAPTURE_ROOT,
) -> int:
    capture_date = validate_capture_date(capture_date)
    session_dir = capture_root / capture_date
    if not session_dir.is_dir():
        raise HarnessError(f"capture session does not exist: {session_dir}")
    audit_errors = validate_session_manifest(
        session_dir / "session-manifest.json", capture_date
    )

    counts = {
        name: {"captured": 0, "denominator": 0, "clean": 0}
        for name, plan in PHASES.items()
        if not plan.setup_only
    }
    app_builds: set[str] = set()
    captured_phases: list[tuple[PhasePlan, str, Path]] = []
    for path in sorted(session_dir.glob("*.json")):
        if path.name == "session-manifest.json":
            continue
        plan, ordinal = _capture_phase_from_name(path.name)
        if plan is None or ordinal is None:
            audit_errors.append(f"unknown capture filename: {path.name}")
            continue
        captured_phases.append((plan, ordinal, path))
        artifact, errors = decode_and_validate(
            path.read_bytes(), path, plan, ordinal, capture_date
        )
        if not plan.setup_only:
            counts[plan.name]["captured"] += 1
        if artifact is not None:
            app_build = artifact.get("appBuild")
            if isinstance(app_build, str):
                app_builds.add(app_build)
            records = artifact.get("records")
            record = records[0] if isinstance(records, list) and records and isinstance(records[0], dict) else {}
            if not plan.setup_only and _event_names(record).count("task-ready") == 1:
                counts[plan.name]["denominator"] += 1
        if errors:
            audit_errors.extend(f"{path.name}: {error}" for error in errors)
        elif not plan.setup_only:
            counts[plan.name]["clean"] += 1

    for plan, ordinal, path in captured_phases:
        if plan.prerequisite_phase is None:
            continue
        try:
            verify_prerequisite(plan, ordinal, capture_date, capture_root)
        except HarnessError as error:
            audit_errors.append(f"{path.name}: {error}")

    if len(app_builds) != 1:
        audit_errors.append(
            "captured reports must use exactly one appBuild; observed "
            + (", ".join(sorted(app_builds)) or "none")
        )

    print("phase                         captured  denominator  contract-clean")
    for name in counts:
        values = counts[name]
        print(
            f"{name:<29} {values['captured']:>8} {values['denominator']:>12} {values['clean']:>15}"
        )
        if values["denominator"] < 10:
            audit_errors.append(
                f"{name} has {values['denominator']} denominator trials; 10 are required"
            )

    if audit_errors:
        print("\nCapture audit is not ready for aggregate adjudication:", file=sys.stderr)
        for error in audit_errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("Capture audit passed. Aggregate result generation and benchmark validation remain separate.")
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser(
        "preflight",
        help="verify the stopped installed bundle without launch or capture",
    )
    run_parser = subparsers.add_parser("run", help="launch and capture one human phase")
    run_parser.add_argument("phase", choices=tuple(PHASES))
    run_parser.add_argument("ordinal", help="two-digit trial ordinal, 01 through 99")
    run_parser.add_argument("capture_date", help="session date in YYYYMMDD")
    run_parser.add_argument(
        "--attest-unaided",
        action="store_true",
        help="attest that only unaided human UI actions will be used",
    )
    run_parser.add_argument("--dry-run", action="store_true")
    audit_parser = subparsers.add_parser("audit", help="audit local capture completeness")
    audit_parser.add_argument("capture_date", help="session date in YYYYMMDD")
    aggregate_parser = subparsers.add_parser(
        "aggregate-human",
        help="create a validated sanitized acceptance-status proposal",
    )
    aggregate_parser.add_argument("capture_date", help="session date in YYYYMMDD")
    aggregate_parser.add_argument(
        "--output",
        type=Path,
        help="exclusive output path; defaults to the dated local aggregate directory",
    )
    return parser


def main(argv: Optional[Iterable[str]] = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "preflight":
            preflight_installed_trial()
            return 0
        if args.command == "run":
            run_phase(
                args.phase,
                args.ordinal,
                args.capture_date,
                args.attest_unaided,
                args.dry_run,
            )
            return 0
        if args.command == "audit":
            return audit_session(args.capture_date)
        output_path, gate, issues = aggregate_human_session(
            args.capture_date,
            output=args.output,
        )
        print(f"Validated sanitized proposal: {output_path}")
        print(f"Timed-human gate status: {gate['status']}")
        for issue in issues:
            print(f"- {issue}")
        return 0 if gate["status"] in {"pass", "fail"} and not issues else 1
    except HarnessError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
