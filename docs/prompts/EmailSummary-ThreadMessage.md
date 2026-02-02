# Prompt: Thread Message Summary

## Use Case
Summarizes a single email message, focusing on what it adds or changes relative to prior messages in the thread.

## Inputs and Preprocessing
- Inputs: subject, body, prior message summaries.
- Preprocessing:
  - Trim subject and body.
  - If subject is empty, use "No subject".
  - If body is empty, use "No body content available.".
  - Prior messages: include up to 10 entries.
  - If no prior messages, use "None".

## Prompt Template
```text
Transform this email into one or two concise sentences.
Use only the provided text; do not add new facts or assumptions.
Focus on what is new compared to the prior messages listed.
Keep the tone professional and actionable.

Email subject:
<subject>

Email body excerpt:
<body>

Prior messages in this thread:
1. <subject> — <snippet>
2. <subject> — <snippet>
...
```

## System Instructions
```text
You are an organized executive assistant reviewing an email.
Transform the provided email content into a concise summary of what this message adds or changes relative to the prior context.
Do not introduce any details that are not present in the input.
Avoid bullet lists; use one or two short sentences.
```

## Generation Options
- temperature: 0.2
- maximumResponseTokens: 140

## Output Expectations
- One or two concise sentences.
- Professional, actionable tone.
- Focuses on new information vs. prior context.
- No bullet lists.

## Injection Notes
- `<subject>` is injected from the cleaned subject string (or `No subject`).
- `<body>` is injected from the cleaned body excerpt (or `No body content available.`).
- `Prior messages in this thread` is injected from up to 10 prior entries (or `None`).
