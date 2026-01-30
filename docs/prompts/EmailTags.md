# Prompt: Email Tags

## Use Case
Generates three short tags for an email so it can be scanned quickly in the UI.

## Inputs and Preprocessing
- Inputs: subject, sender, snippet.
- Preprocessing:
  - Trim subject, sender, and snippet.
  - If subject is empty, use "No subject".
  - If sender is empty, use "Unknown sender".
  - If snippet is empty, use "No snippet".
  - If all fields are empty after trimming, skip generation and surface `EmailTagError.noContent`.

## Prompt Template
```text
Generate tags for this email.

Subject: <subject>
From: <sender>
Snippet: <snippet>
```

## System Instructions
```text
You are labeling an email for quick scanning.

Provide exactly three short tags (1-2 words each).
Return only a comma-separated list of tags.
Do not include any extra text, numbering, or commentary.
```

## Generation Options
- temperature: 0.2
- maximumResponseTokens: 64

## Output Expectations
- Exactly three tags.
- Each tag is 1-2 words.
- Comma-separated list only, no extra text.

## Injection Notes
- `<subject>` is injected from the cleaned subject (or `No subject`).
- `<sender>` is injected from the cleaned sender (or `Unknown sender`).
- `<snippet>` is injected from the cleaned snippet (or `No snippet`).
