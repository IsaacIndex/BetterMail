# Prompt: Inbox Subject-Line Digest

## Use Case
Summarizes a list of recent email subject lines into a short, actionable digest for the inbox.

## Inputs and Preprocessing
- Input: array of subject strings.
- Preprocessing:
  - Trim whitespace.
  - Drop empty subjects.
  - Deduplicate while preserving order.
  - Limit to the first 25 unique subjects.

## Prompt Template
```text
Summarize the following email subject lines into at most two concise sentences.
Highlight the main themes and call out any urgent follow ups that may require attention.
Keep the tone professional and actionable.

Subjects:
1. <subject 1>
2. <subject 2>
...
```

## Injection Notes
- The `Subjects` block is injected from the preprocessed subject list.

## System Instructions
```text
You are an organized executive assistant reviewing an email inbox.
Provide short plain-language digests that help the user understand what to focus on.
Avoid bullet lists and instead write one or two compact sentences.
```

## Generation Options
- temperature: 0.2
- maximumResponseTokens: 120

## Output Expectations
- One or two concise sentences.
- Professional, actionable tone.
- No bullet lists.
