# Suggestion Corpus Integrity Erratum

- Status: resolved for v2 acceptance; v1 remains ineligible
- Date: 2026-08-24 HKT
- Affected artifact: `Tests/Fixtures/Organizer/suggestion-gold-v1.json`
- Affected gate: task 7.5 suggestion precision and coverage

The v1 suggestion corpus remains frozen for reproducibility, but it is not
eligible evidence for suggestion-quality acceptance.

## Findings

1. `generate_fixtures.py` assigns labels from the local sequential index while
   `candidateKey` and `sourceKey` expose that index. A predictor can recover the
   label from key parity without evaluating email evidence.
2. The corpus contains categorical metadata and adjudication labels, but no
   separate production-relevant synthetic source/target evidence. It therefore
   cannot be submitted to `GraphRelationshipProviding`, whose request requires
   source and target titles, summaries, and representative content.
3. The original metrics recorder accepts aggregate candidate/accepted/correct
   counts supplied by its caller. Those counts do not prove a prediction-to-gold
   join, version pins, effective-source deduplication, or conflict handling.
4. The original manifest required the `unrelated` relation in the balanced
   corpus and also required at least 25 accepted placements in every reported
   relation slice. That denominator rewards false positives because a correct
   unrelated decision produces no placement.

## Enforced correction

`OrganizerSuggestionArtifactEvaluator` and `OrganizerSuggestionEvaluator` now
provide the code-level acceptance boundary:

- three exact-field v2 schemas keep provider input, evaluator-only gold, and
  predictions structurally separate;
- provider-facing input has no gold label, expected action/destination, or
  evaluation slice fields and must contain non-empty production-relevant
  synthetic source/target evidence;
- candidate/source/destination keys must use opaque 256-bit values under the
  declared pre-adjudication key policy;
- the prediction file binds the SHA-256 digest of the exact provider-facing
  input bytes, while the aggregate report carries computed input and gold
  digests;
- predictions are generated first and joined to gold records afterward by the
  effective synthetic source key;
- duplicate sources remain in the denominator and are either deterministically
  identical or reported as explicit conflicts;
- reports include TP/FP/TN/FN/abstention, precision, coverage, and relation,
  confidence-band, and provenance slices;
- attach, append, confidence-band, and provenance slices require accepted
  placement denominators; `unrelated` is a rejection-control slice and requires
  non-abstained decisions instead;
- every unrelated gold record must be rejected, and an accepted unrelated
  prediction is scored as a false positive;
- corpus/provider/model/policy/strictness/app-build pins and input/gold SHA-256
  digests are required;
- unreadable/malformed artifacts, deterministic provider doubles,
  aggregate-only counts, missing pins,
  non-production inputs, label-dependent keys, unmatched predictions, and
  conflicts return `insufficientEvidence`, never `pass`; and
- the sequential-key label channel used by v1 is detected explicitly.

The old aggregate recorder remains available for arithmetic diagnostics, but
its suggestion status is now always `insufficientEvidence`.

The declaration that random keys were assigned before adjudication must still
be supported by the corpus-preparation record. The evaluator verifies the
declared policy, exact byte binding, shape, and observable key properties; it
does not pretend to infer the human preparation sequence from prediction
quality.

## Resolution and current evidence

Task 7.5 is complete through the separately frozen v2 evidence; v1 was not
modified or promoted. The acceptance manifest pins the exact-byte SHA-256
digests for `suggestion-input-v2.json`, `suggestion-gold-v2.json`,
`suggestion-predictions-v2.json`, and the sanitized aggregate evaluation. The
corpus-preparation record declares 256-bit CSPRNG keys assigned before
adjudication, while the prediction artifact binds the exact provider-input
bytes and contains no evaluator-only gold fields.

The pinned production-provider evaluation covers 216 candidates, accepts 140,
records zero false positives, reports precision `1.0` and coverage `1.0`, and
passes every required relation, confidence, and provenance denominator. The
manifest therefore records `acceptanceArtifactStatus: "passed"`, and task 7.5
is checked. This resolution does not rehabilitate the sequential-key v1 corpus;
v1 remains a frozen, acceptance-ineligible regression fixture.
