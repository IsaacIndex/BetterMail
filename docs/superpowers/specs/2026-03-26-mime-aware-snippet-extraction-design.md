# MIME-Aware Snippet Extraction

## Problem

When Mail.app's `content of m` AppleScript property returns empty (common with corporate email systems like Proofpoint/Exchange), `bodySnippetFromSource` falls back to naively splitting the raw email source on the first `\n\n`. For multipart MIME emails, this lands in MIME boundary markers and base64-encoded header blobs rather than the actual message body. The snippet — and any Apple Intelligence summary derived from it — becomes useless.

## Solution

Replace the naive `\n\n` fallback in `bodySnippetFromSource` with a MIME boundary walker that finds and decodes the `text/plain` part from multipart email sources.

## Scope

All changes are confined to the private `HeaderDecoder` struct in `MailAppleScriptClient.swift`. No changes to public/internal APIs, data models, views, or storage. All new methods are `private` to match existing `HeaderDecoder` conventions.

## Design

### Call chain (unchanged externally)

```
bodySnippet(fromBody:fallbackSource:)
  → body is empty
  → bodySnippetFromSource(source:)
      → extractPlainTextFromMIME(source:)   // NEW — replaces naive \n\n split
      → cleanedSnippetLines → truncate
```

If `extractPlainTextFromMIME` returns `nil`, the existing naive `\n\n` logic is preserved as a final fallback for non-multipart emails.

### New methods on `HeaderDecoder`

#### `extractPlainTextFromMIME(_ source: String) -> String?`

Entry point. Parses top-level `Content-Type` header for boundary parameter. If no boundary found (not multipart), returns `nil`. Otherwise locates the body after the header block's `\n\n` separator and delegates to `extractTextFromParts`.

#### `extractTextFromParts(_ body: String, boundary: String, depth: Int) -> String?`

Iterates MIME parts between boundary markers. Maximum recursion depth of 10 — returns `nil` when exceeded.

**Boundary handling:**
- Parts are delimited by `--boundary`
- The closing delimiter `--boundary--` terminates parsing; everything after it (the epilogue) is discarded
- The preamble (text before the first `--boundary`) is discarded

For each part:

1. Parse the part's headers using the existing `headers(from:)` method (which already handles folded continuation lines)
2. If `Content-Type: text/plain` — decode the body per transfer encoding and charset, return it
3. If `Content-Type: multipart/*` — extract nested boundary and recurse with `depth + 1`
4. Skip all other parts (images, attachments)

For `multipart/alternative`, prefers `text/plain` over `text/html`. If only HTML is found, strip `<style>...</style>` and `<script>...</script>` blocks first, then strip remaining tags using the existing `cleanSnippetLine` regex as a last-resort fallback.

#### `decodeTransferEncoding(_ text: String, encoding: String) -> String`

Encoding comparison is **case-insensitive** (real emails use `Base64`, `QUOTED-PRINTABLE`, etc.).

Handles three cases:

- `quoted-printable`: Decode `=XX` hex sequences and `=\n` soft line breaks. Note: `\r\n` is already normalized to `\n` by existing code, so only `=\n` needs handling.
- `base64`: Decode via `Data(base64Encoded:)` → UTF-8 string
- `7bit`/`8bit`/none: passthrough

#### `extractBoundary(from contentType: String) -> String?`

Extracts the `boundary=` value from a `Content-Type` header string. Handles both quoted (`boundary="value"`) and unquoted (`boundary=value`) forms.

### Charset handling

Check for `charset=` in `Content-Type`. Supported encodings:

- `utf-8` (default)
- `us-ascii` → `.ascii`
- `iso-8859-1` → `.isoLatin1`
- `windows-1252` → `.windowsCP1252`

All other charsets fall back to UTF-8. If charset decoding fails (e.g., invalid byte sequences), fall back to UTF-8 lossy decoding (`String(data:encoding:)` with `.utf8`) rather than returning `nil`.

### Size guard

Skip MIME parsing for sources larger than 512 KB. The `text/plain` part we're looking for typically appears early in the source, and parsing multi-MB attachment-heavy emails is wasteful. For oversized sources, fall through to the existing naive `\n\n` logic.

### Example walk for the HKJC email

```
multipart/mixed (boundary=_007_...)
  → multipart/related (boundary=_006_...)
    → multipart/alternative (boundary=_000_...)
      → text/plain; charset=utf-8; quoted-printable  ← FOUND, decode and return
      → text/html (skipped)
```

Result: `"Dear IBM team, Would you please help further update these SAT test rules?..."`

### Logging

Add `Log.appleScript.debug` statements when:
- MIME parsing is attempted
- A `text/plain` part is found (or not found)
- Falling back to naive `\n\n` logic

## Testing

New test file: `BetterMail/Tests/MIMESnippetExtractionTests.swift`

Unit tests covering:

1. **Multipart/alternative with text/plain** — extracts plain text correctly
2. **Nested multipart** (mixed → related → alternative) — walks recursively to text/plain
3. **Quoted-printable decoding** — including multi-byte UTF-8 sequences like `=E2=80=93` (em dash)
4. **Base64-encoded text/plain** — decodes correctly
5. **Non-multipart email** — returns nil, falls through to existing naive logic
6. **HTML-only multipart** — strips style/script blocks then tags as fallback
7. **Missing/empty body** — returns nil
8. **Recursion depth limit** — deeply nested multipart returns nil at depth 10
9. **Closing delimiter** — content after `--boundary--` is ignored
10. **Case-insensitive transfer encoding** — `Base64` and `QUOTED-PRINTABLE` work

## Files changed

| File | Change |
|------|--------|
| `Sources/DataSource/MailAppleScriptClient.swift` | Add MIME parsing methods to `HeaderDecoder`; modify `bodySnippetFromSource` |
| `Tests/MIMESnippetExtractionTests.swift` | Unit tests for MIME snippet extraction |
