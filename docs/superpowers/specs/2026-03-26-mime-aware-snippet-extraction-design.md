# MIME-Aware Snippet Extraction

## Problem

When Mail.app's `content of m` AppleScript property returns empty (common with corporate email systems like Proofpoint/Exchange), `bodySnippetFromSource` falls back to naively splitting the raw email source on the first `\n\n`. For multipart MIME emails, this lands in MIME boundary markers and base64-encoded header blobs rather than the actual message body. The snippet — and any Apple Intelligence summary derived from it — becomes useless.

## Solution

Replace the naive `\n\n` fallback in `bodySnippetFromSource` with a MIME boundary walker that finds and decodes the `text/plain` part from multipart email sources.

## Scope

All changes are confined to the private `HeaderDecoder` struct in `MailAppleScriptClient.swift`. No changes to public/internal APIs, data models, views, or storage.

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

Entry point. Parses top-level `Content-Type` header for boundary parameter. If no boundary found (not multipart), returns `nil`. Otherwise splits the source body on `--boundary` and delegates to `extractTextFromParts`.

#### `extractTextFromParts(_ body: String, boundary: String) -> String?`

Iterates MIME parts between boundary markers. For each part:

1. Parse the part's headers (`Content-Type`, `Content-Transfer-Encoding`)
2. If `Content-Type: text/plain` — decode the body per transfer encoding and return it
3. If `Content-Type: multipart/*` — extract nested boundary and recurse
4. Skip all other parts (HTML preferred only as last resort, images, attachments)

For `multipart/alternative`, prefers `text/plain` over `text/html`. If only HTML is found, strips tags using the existing `cleanSnippetLine` regex as a last-resort fallback.

#### `decodeTransferEncoding(_ text: String, encoding: String) -> String`

Handles three cases:

- `quoted-printable`: Decode `=XX` hex sequences and `=\n` soft line breaks
- `base64`: Decode via `Data(base64Encoded:)` → UTF-8 string
- `7bit`/`8bit`/none: passthrough

#### `extractBoundary(from contentType: String) -> String?`

Extracts the `boundary=` value from a `Content-Type` header string. Handles both quoted (`boundary="value"`) and unquoted (`boundary=value`) forms.

### Charset handling

Check for `charset=` in `Content-Type`. Default to UTF-8. For `iso-8859-1` or `windows-1252`, use the corresponding `String.Encoding`. Other charsets fall back to UTF-8.

### Example walk for the HKJC email

```
multipart/mixed (boundary=_007_...)
  → multipart/related (boundary=_006_...)
    → multipart/alternative (boundary=_000_...)
      → text/plain; charset=utf-8; quoted-printable  ← FOUND, decode and return
      → text/html (skipped)
```

Result: `"Dear IBM team, Would you please help further update these SAT test rules?..."`

## Testing

New unit tests covering:

1. **Multipart/alternative with text/plain** — extracts plain text correctly
2. **Nested multipart** (mixed → related → alternative) — walks recursively to text/plain
3. **Quoted-printable decoding** — including multi-byte UTF-8 sequences like `=E2=80=93` (em dash)
4. **Base64-encoded text/plain** — decodes correctly
5. **Non-multipart email** — returns nil, falls through to existing naive logic
6. **HTML-only multipart** — strips tags as fallback
7. **Missing/empty body** — returns nil

## Files changed

| File | Change |
|------|--------|
| `Sources/DataSource/MailAppleScriptClient.swift` | Add MIME parsing methods to `HeaderDecoder`; modify `bodySnippetFromSource` |
| `Tests/` (new test file) | Unit tests for MIME snippet extraction |
