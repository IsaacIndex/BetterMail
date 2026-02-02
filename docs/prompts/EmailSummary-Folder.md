# Prompt: Folder Summary

## Use Case
Summarizes a collection of message summaries into a short, actionable folder overview.

## Inputs and Preprocessing
- Inputs: folder title and an array of message summaries.
- Preprocessing:
  - Trim summary strings.
  - Drop empty summaries.
  - Limit to the first 20 summaries.
  - If title is empty, use "Folder".

## Prompt Template
```text
Transform the following email summaries into a concise folder overview.
Use only the provided text; do not add new facts or assumptions.
Highlight the main themes, decisions, or urgent follow ups.
Keep the tone professional and actionable, in two or three sentences.

Folder title: <title>

Email summaries:
1. <summary 1>
2. <summary 2>
...
```

## System Instructions
```text
You are an organized executive assistant reviewing an email inbox.
Transform the provided email summaries into short plain-language digests that help the user understand what to focus on.
Do not add any facts not present in the input.
Avoid bullet lists and instead write one or two compact sentences.
```

## Generation Options
- temperature: 0.2
- maximumResponseTokens: 160

## Output Expectations
- Two to three concise sentences.
- Professional, actionable tone.
- No bullet lists.

## Injection Notes
- `<title>` is injected from the folder title (or `Folder`).
- The `Email summaries` block is injected from the preprocessed summaries list.
