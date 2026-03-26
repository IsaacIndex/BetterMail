# MIME-Aware Snippet Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix garbage snippets for multipart MIME emails by adding a MIME boundary walker to `HeaderDecoder` that finds and decodes the `text/plain` part.

**Architecture:** All changes are confined to `HeaderDecoder` in `MailAppleScriptClient.swift`. The existing `bodySnippetFromSource` gains a MIME-aware path that tries `extractPlainTextFromMIME` before falling back to the naive `\n\n` split. Tests exercise `HeaderDecoder` directly by changing its access level from `private` to `internal`.

**Tech Stack:** Swift, Foundation (`Data`, `String.Encoding`), XCTest

**Spec:** `docs/superpowers/specs/2026-03-26-mime-aware-snippet-extraction-design.md`

---

### Task 1: Make HeaderDecoder testable and add boundary extraction

**Files:**
- Modify: `BetterMail/Sources/DataSource/MailAppleScriptClient.swift:971` — change `private struct HeaderDecoder` to `internal struct HeaderDecoder`
- Modify: `BetterMail/Sources/DataSource/MailAppleScriptClient.swift:971-1086` — add `extractBoundary(from:)` method
- Create: `Tests/MIMESnippetExtractionTests.swift`

- [ ] **Step 1: Write failing test for boundary extraction**

Create `Tests/MIMESnippetExtractionTests.swift`:
```swift
import XCTest
@testable import BetterMail

final class MIMESnippetExtractionTests: XCTestCase {

    private let decoder = HeaderDecoder()

    // MARK: - extractBoundary

    func test_extractBoundary_quotedValue_returnsBoundary() {
        let ct = "multipart/alternative; boundary=\"_000_ABC123\""
        XCTAssertEqual(decoder.extractBoundary(from: ct), "_000_ABC123")
    }

    func test_extractBoundary_unquotedValue_returnsBoundary() {
        let ct = "multipart/mixed; boundary=_007_XYZ789"
        XCTAssertEqual(decoder.extractBoundary(from: ct), "_007_XYZ789")
    }

    func test_extractBoundary_noBoundary_returnsNil() {
        let ct = "text/plain; charset=utf-8"
        XCTAssertNil(decoder.extractBoundary(from: ct))
    }

    func test_extractBoundary_boundaryWithSpacesAroundEquals_returnsBoundary() {
        let ct = "multipart/alternative; boundary = \"spacey_boundary\""
        XCTAssertEqual(decoder.extractBoundary(from: ct), "spacey_boundary")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -destination 'platform=macOS' \
  -only-testing:BetterMailTests/MIMESnippetExtractionTests \
  > /tmp/xcodebuild.log 2>&1
tail -n 50 /tmp/xcodebuild.log
```
Expected: FAIL — `HeaderDecoder` is private and `extractBoundary` doesn't exist.

- [ ] **Step 3: Make HeaderDecoder internal and implement extractBoundary**

In `MailAppleScriptClient.swift`, change line 971:
```swift
// Change from:
private struct HeaderDecoder {
// To:
internal struct HeaderDecoder {
```

Add after the `extractIdentifiers` method (before the closing `}` of `HeaderDecoder`):
```swift
    func extractBoundary(from contentType: String) -> String? {
        let lower = contentType.lowercased()
        guard let range = lower.range(of: "boundary") else { return nil }
        let afterKey = contentType[range.upperBound...]
        let trimmed = afterKey.drop { $0.isWhitespace || $0 == "=" }
        guard !trimmed.isEmpty else { return nil }
        if trimmed.first == "\"" {
            let unquoted = trimmed.dropFirst()
            guard let endQuote = unquoted.firstIndex(of: "\"") else {
                return String(unquoted)
            }
            return String(unquoted[..<endQuote])
        }
        let end = trimmed.firstIndex(where: { $0 == ";" || $0.isWhitespace }) ?? trimmed.endIndex
        return String(trimmed[..<end])
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -destination 'platform=macOS' \
  -only-testing:BetterMailTests/MIMESnippetExtractionTests \
  > /tmp/xcodebuild.log 2>&1
tail -n 50 /tmp/xcodebuild.log
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add BetterMail/Sources/DataSource/MailAppleScriptClient.swift Tests/MIMESnippetExtractionTests.swift
git commit -m "feat: add extractBoundary to HeaderDecoder for MIME parsing"
```

---

### Task 2: Add transfer encoding and charset decoding

**Files:**
- Modify: `BetterMail/Sources/DataSource/MailAppleScriptClient.swift` — add `decodeMIMEBody(_:transferEncoding:contentType:)` and supporting methods
- Modify: `Tests/MIMESnippetExtractionTests.swift` — add transfer encoding and charset tests

The key design decision: `decodeMIMEBody` combines transfer encoding decoding and charset decoding in one method. Transfer encoding is decoded to `Data` first, then charset decoding converts to `String`. This ensures non-UTF-8 charsets (like `iso-8859-1`) are handled correctly.

- [ ] **Step 1: Write failing tests for transfer encoding and charset decoding**

Append to `MIMESnippetExtractionTests.swift`:
```swift
    // MARK: - decodeMIMEBody

    func test_decodeMIMEBody_quotedPrintable_decodesHexAndSoftBreaks() {
        let input = "Hello=20World=\nThis is a test"
        let result = decoder.decodeMIMEBody(input, transferEncoding: "quoted-printable", contentType: "text/plain")
        XCTAssertEqual(result, "Hello World\nThis is a test")
    }

    func test_decodeMIMEBody_quotedPrintable_utf8MultiByteSequence() {
        // =E2=80=93 is the UTF-8 encoding of "–" (em dash)
        let input = "Excel =E2=80=93 Push Rules"
        let result = decoder.decodeMIMEBody(input, transferEncoding: "quoted-printable", contentType: "text/plain; charset=utf-8")
        XCTAssertEqual(result, "Excel \u{2013} Push Rules")
    }

    func test_decodeMIMEBody_base64_decodesCorrectly() {
        let original = "Hello, this is a test message."
        let encoded = Data(original.utf8).base64EncodedString()
        let result = decoder.decodeMIMEBody(encoded, transferEncoding: "base64", contentType: "text/plain")
        XCTAssertEqual(result, original)
    }

    func test_decodeMIMEBody_caseInsensitive_works() {
        let original = "Test message"
        let encoded = Data(original.utf8).base64EncodedString()
        XCTAssertEqual(decoder.decodeMIMEBody(encoded, transferEncoding: "Base64", contentType: "text/plain"), original)
        XCTAssertEqual(decoder.decodeMIMEBody(encoded, transferEncoding: "BASE64", contentType: "text/plain"), original)
        let qp = "Hello=20World"
        XCTAssertEqual(decoder.decodeMIMEBody(qp, transferEncoding: "QUOTED-PRINTABLE", contentType: "text/plain"), "Hello World")
    }

    func test_decodeMIMEBody_7bit_passthrough() {
        let input = "Plain text content"
        XCTAssertEqual(decoder.decodeMIMEBody(input, transferEncoding: "7bit", contentType: "text/plain"), input)
        XCTAssertEqual(decoder.decodeMIMEBody(input, transferEncoding: "8bit", contentType: "text/plain"), input)
        XCTAssertEqual(decoder.decodeMIMEBody(input, transferEncoding: "", contentType: "text/plain"), input)
    }

    func test_decodeMIMEBody_latin1Charset_decodesCorrectly() {
        // Build a QP-encoded iso-8859-1 string: "café" where é = 0xE9 in latin1 = =E9 in QP
        let input = "caf=E9"
        let result = decoder.decodeMIMEBody(input, transferEncoding: "quoted-printable", contentType: "text/plain; charset=iso-8859-1")
        XCTAssertEqual(result, "café")
    }

    func test_decodeMIMEBody_unknownCharset_fallsBackToUTF8() {
        let input = "hello"
        let result = decoder.decodeMIMEBody(input, transferEncoding: "7bit", contentType: "text/plain; charset=iso-2022-jp")
        XCTAssertEqual(result, "hello")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -destination 'platform=macOS' \
  -only-testing:BetterMailTests/MIMESnippetExtractionTests \
  > /tmp/xcodebuild.log 2>&1
tail -n 50 /tmp/xcodebuild.log
```
Expected: FAIL — `decodeMIMEBody` doesn't exist.

- [ ] **Step 3: Implement decodeMIMEBody and supporting methods**

Add to `HeaderDecoder`:
```swift
    func decodeMIMEBody(_ text: String, transferEncoding: String, contentType: String) -> String {
        let data = decodeTransferEncodingToData(text, encoding: transferEncoding)
        return decodeCharset(data, contentType: contentType)
    }

    private func decodeTransferEncodingToData(_ text: String, encoding: String) -> Data {
        switch encoding.lowercased().trimmingCharacters(in: .whitespaces) {
        case "quoted-printable":
            return decodeQuotedPrintable(text)
        case "base64":
            let cleaned = text.replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Data(base64Encoded: cleaned) ?? Data(text.utf8)
        default:
            return Data(text.utf8)
        }
    }

    private func decodeCharset(_ data: Data, contentType: String) -> String {
        let encoding = charsetEncoding(from: contentType)
        return String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8) ?? ""
    }

    private func charsetEncoding(from contentType: String) -> String.Encoding {
        let lower = contentType.lowercased()
        guard let range = lower.range(of: "charset=") else { return .utf8 }
        let afterCharset = lower[range.upperBound...]
        let value: String
        if afterCharset.first == "\"" {
            let unquoted = afterCharset.dropFirst()
            let end = unquoted.firstIndex(of: "\"") ?? unquoted.endIndex
            value = String(unquoted[..<end])
        } else {
            let end = afterCharset.firstIndex(where: { $0 == ";" || $0.isWhitespace }) ?? afterCharset.endIndex
            value = String(afterCharset[..<end])
        }
        switch value.trimmingCharacters(in: .whitespaces) {
        case "us-ascii": return .ascii
        case "iso-8859-1", "latin1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        default: return .utf8
        }
    }

    private func decodeQuotedPrintable(_ text: String) -> Data {
        var result = Data()
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x3D { // "="
                if i + 1 < bytes.count && bytes[i + 1] == 0x0A { // =\n soft break
                    i += 2
                    continue
                }
                if i + 2 < bytes.count,
                   let high = hexValue(bytes[i + 1]),
                   let low = hexValue(bytes[i + 2]) {
                    result.append(high << 4 | low)
                    i += 3
                    continue
                }
            }
            result.append(bytes[i])
            i += 1
        }
        return result
    }

    private func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30       // 0-9
        case 0x41...0x46: return byte - 0x41 + 10  // A-F
        case 0x61...0x66: return byte - 0x61 + 10  // a-f
        default: return nil
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -destination 'platform=macOS' \
  -only-testing:BetterMailTests/MIMESnippetExtractionTests \
  > /tmp/xcodebuild.log 2>&1
tail -n 50 /tmp/xcodebuild.log
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add BetterMail/Sources/DataSource/MailAppleScriptClient.swift Tests/MIMESnippetExtractionTests.swift
git commit -m "feat: add MIME body decoding with transfer encoding and charset support"
```

---

### Task 3: Add MIME part extraction (core recursive walker)

**Files:**
- Modify: `BetterMail/Sources/DataSource/MailAppleScriptClient.swift` — add `extractPlainTextFromMIME(_:)`, `extractTextFromParts(_:boundary:depth:)`, and `stripHTML(_:)`
- Modify: `Tests/MIMESnippetExtractionTests.swift` — add MIME extraction tests

- [ ] **Step 1: Write failing tests for MIME extraction**

Append to `MIMESnippetExtractionTests.swift`:
```swift
    // MARK: - extractPlainTextFromMIME

    func test_extractPlainTextFromMIME_simpleMultipartAlternative_extractsPlainText() {
        let source = """
        Content-Type: multipart/alternative; boundary="boundary1"

        --boundary1
        Content-Type: text/plain; charset=utf-8

        Hello from the plain text part.
        --boundary1
        Content-Type: text/html; charset=utf-8

        <html><body>Hello from HTML</body></html>
        --boundary1--
        """
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "Hello from the plain text part.")
    }

    func test_extractPlainTextFromMIME_nestedMultipart_walksToPlainText() {
        let source = """
        Content-Type: multipart/mixed; boundary="outer"

        --outer
        Content-Type: multipart/related; boundary="middle"

        --middle
        Content-Type: multipart/alternative; boundary="inner"

        --inner
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        Dear team,=0APlease review.
        --inner
        Content-Type: text/html

        <html><body>Dear team</body></html>
        --inner--
        --middle--
        --outer--
        """
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertTrue(result?.contains("Dear team,") == true)
        XCTAssertTrue(result?.contains("Please review.") == true)
    }

    func test_extractPlainTextFromMIME_base64PlainText_decodes() {
        let body = "This is a base64 encoded message."
        let encoded = Data(body.utf8).base64EncodedString()
        let source = """
        Content-Type: multipart/alternative; boundary="b64bound"

        --b64bound
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: base64

        \(encoded)
        --b64bound--
        """
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines), body)
    }

    func test_extractPlainTextFromMIME_nonMultipart_returnsNil() {
        let source = """
        Content-Type: text/plain; charset=utf-8

        Just a simple email.
        """
        XCTAssertNil(decoder.extractPlainTextFromMIME(source))
    }

    func test_extractPlainTextFromMIME_htmlOnly_stripsTagsAsFallback() {
        let source = """
        Content-Type: multipart/alternative; boundary="htmlonly"

        --htmlonly
        Content-Type: text/html; charset=utf-8

        <html><head><style>body{color:red}</style></head><body><p>Important message</p></body></html>
        --htmlonly--
        """
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("Important message") == true)
        XCTAssertFalse(result?.contains("<p>") == true)
        XCTAssertFalse(result?.contains("color:red") == true)
    }

    func test_extractPlainTextFromMIME_closingDelimiter_ignoresEpilogue() {
        let source = """
        Content-Type: multipart/alternative; boundary="epilogue"

        --epilogue
        Content-Type: text/plain

        Real content.
        --epilogue--
        This is epilogue junk that should be ignored.
        """
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines), "Real content.")
    }

    func test_extractPlainTextFromMIME_depthLimit_returnsNil() {
        // Build a 12-level nested multipart to exceed the depth limit of 10
        var source = ""
        for i in 0..<12 {
            let boundary = "level\(i)"
            source += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\n\n--\(boundary)\n"
        }
        source += "Content-Type: text/plain\n\nShould not be reached.\n"
        for i in stride(from: 11, through: 0, by: -1) {
            source += "--level\(i)--\n"
        }
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertNil(result)
    }

    func test_extractPlainTextFromMIME_emptySource_returnsNil() {
        XCTAssertNil(decoder.extractPlainTextFromMIME(""))
    }

    func test_extractPlainTextFromMIME_oversizedSource_returnsNil() {
        // Build a source larger than 512 KB
        let padding = String(repeating: "X", count: 512 * 1024 + 1)
        let source = "Content-Type: multipart/mixed; boundary=\"big\"\n\n--big\nContent-Type: text/plain\n\n\(padding)\n--big--"
        XCTAssertNil(decoder.extractPlainTextFromMIME(source))
    }

    func test_extractPlainTextFromMIME_latin1Part_decodesCorrectly() {
        // QP-encoded iso-8859-1: "café" where é = =E9
        let source = """
        Content-Type: multipart/alternative; boundary="latin"

        --latin
        Content-Type: text/plain; charset=iso-8859-1
        Content-Transfer-Encoding: quoted-printable

        caf=E9
        --latin--
        """
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines), "café")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -destination 'platform=macOS' \
  -only-testing:BetterMailTests/MIMESnippetExtractionTests \
  > /tmp/xcodebuild.log 2>&1
tail -n 50 /tmp/xcodebuild.log
```
Expected: FAIL — `extractPlainTextFromMIME` doesn't exist.

- [ ] **Step 3: Implement extractPlainTextFromMIME, extractTextFromParts, and stripHTML**

Add to `HeaderDecoder`:
```swift
    private static let maxMIMESourceSize = 512 * 1024 // 512 KB
    private static let maxMIMEDepth = 10

    func extractPlainTextFromMIME(_ source: String) -> String? {
        guard source.utf8.count <= Self.maxMIMESourceSize else {
            Log.appleScript.debug("MIME parsing skipped: source exceeds 512 KB")
            return nil
        }
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let topHeaders = headers(from: normalized)
        guard let contentType = topHeaders["content-type"],
              contentType.lowercased().contains("multipart"),
              let boundary = extractBoundary(from: contentType) else {
            return nil
        }
        guard let headerEnd = normalized.range(of: "\n\n") else { return nil }
        let body = String(normalized[headerEnd.upperBound...])
        Log.appleScript.debug("MIME parsing: attempting multipart extraction with boundary")
        let result = extractTextFromParts(body, boundary: boundary, depth: 0)
        if result == nil {
            Log.appleScript.debug("MIME parsing: no text/plain part found")
        }
        return result
    }

    private func extractTextFromParts(_ body: String, boundary: String, depth: Int) -> String? {
        guard depth < Self.maxMIMEDepth else { return nil }
        let delimiter = "--" + boundary
        let closingDelimiter = delimiter + "--"

        // Truncate at closing delimiter to ignore epilogue
        let workingBody: String
        if let closingRange = body.range(of: closingDelimiter) {
            workingBody = String(body[..<closingRange.lowerBound])
        } else {
            workingBody = body
        }

        let rawParts = workingBody.components(separatedBy: delimiter)
        // First element is preamble — discard it
        let parts = Array(rawParts.dropFirst())

        var plainTextResult: String?
        var htmlFallback: String?

        for part in parts {
            let trimmedPart = part.hasPrefix("\n") ? String(part.dropFirst()) : part
            guard let headerEnd = trimmedPart.range(of: "\n\n") else { continue }
            let partHeaderStr = String(trimmedPart[..<headerEnd.lowerBound])
            let partBody = String(trimmedPart[headerEnd.upperBound...])
            // Append \n\n so headers(from:) sees the end-of-headers marker
            let partHeaders = headers(from: partHeaderStr + "\n\n")
            let rawPartContentType = partHeaders["content-type"] ?? ""
            let partContentType = rawPartContentType.lowercased()
            let transferEncoding = partHeaders["content-transfer-encoding"] ?? ""

            if partContentType.contains("multipart"),
               let nestedBoundary = extractBoundary(from: rawPartContentType) {
                if let nested = extractTextFromParts(partBody, boundary: nestedBoundary, depth: depth + 1) {
                    return nested
                }
            } else if partContentType.contains("text/plain") || (partContentType.isEmpty && depth > 0) {
                let decoded = decodeMIMEBody(partBody, transferEncoding: transferEncoding, contentType: rawPartContentType)
                plainTextResult = decoded
            } else if partContentType.contains("text/html") && htmlFallback == nil {
                let decoded = decodeMIMEBody(partBody, transferEncoding: transferEncoding, contentType: rawPartContentType)
                htmlFallback = stripHTML(decoded)
            }

            // Return plain text immediately if found (preferred over HTML)
            if plainTextResult != nil { return plainTextResult }
        }

        return htmlFallback
    }

    private func stripHTML(_ html: String) -> String {
        var result = html
        // Remove style blocks
        result = result.replacingOccurrences(
            of: "<style[^>]*>[\\s\\S]*?</style>",
            with: "",
            options: .regularExpression
        )
        // Remove script blocks
        result = result.replacingOccurrences(
            of: "<script[^>]*>[\\s\\S]*?</script>",
            with: "",
            options: .regularExpression
        )
        // Remove all remaining tags
        result = result.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Collapse whitespace
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
```

Note: `Log.appleScript` is the existing `OSLog` logger already used throughout `MailAppleScriptClient.swift`.

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -destination 'platform=macOS' \
  -only-testing:BetterMailTests/MIMESnippetExtractionTests \
  > /tmp/xcodebuild.log 2>&1
tail -n 50 /tmp/xcodebuild.log
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add BetterMail/Sources/DataSource/MailAppleScriptClient.swift Tests/MIMESnippetExtractionTests.swift
git commit -m "feat: add MIME boundary walker for text/plain extraction"
```

---

### Task 4: Wire MIME extraction into bodySnippetFromSource

**Files:**
- Modify: `BetterMail/Sources/DataSource/MailAppleScriptClient.swift:1012-1021` — update `bodySnippetFromSource` to try MIME extraction first
- Modify: `Tests/MIMESnippetExtractionTests.swift` — add integration tests via `bodySnippet`

- [ ] **Step 1: Write failing integration test**

Append to `MIMESnippetExtractionTests.swift`:
```swift
    // MARK: - bodySnippet integration

    func test_bodySnippet_emptyBodyWithMultipartSource_extractsFromMIME() {
        let source = """
        Content-Type: multipart/alternative; boundary="inttest"
        Subject: Test

        --inttest
        Content-Type: text/plain; charset=utf-8

        This is the real email body from MIME.
        --inttest
        Content-Type: text/html

        <html><body>HTML version</body></html>
        --inttest--
        """
        let result = decoder.bodySnippet(fromBody: "", fallbackSource: source)
        XCTAssertTrue(result.contains("This is the real email body from MIME."))
    }

    func test_bodySnippet_nonEmptyBody_usesPrimaryBody() {
        let result = decoder.bodySnippet(fromBody: "Primary body text", fallbackSource: "irrelevant")
        XCTAssertEqual(result, "Primary body text")
    }

    func test_bodySnippet_emptyBodyNonMultipartSource_usesNaiveFallback() {
        let source = """
        Subject: Test

        Simple body after headers.
        """
        let result = decoder.bodySnippet(fromBody: "", fallbackSource: source)
        XCTAssertTrue(result.contains("Simple body after headers."))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -destination 'platform=macOS' \
  -only-testing:BetterMailTests/MIMESnippetExtractionTests/test_bodySnippet_emptyBodyWithMultipartSource_extractsFromMIME \
  > /tmp/xcodebuild.log 2>&1
tail -n 50 /tmp/xcodebuild.log
```
Expected: FAIL — `bodySnippetFromSource` uses naive logic, returns MIME boundary junk.

- [ ] **Step 3: Update bodySnippetFromSource**

Replace the `bodySnippetFromSource` method (currently at line 1012):
```swift
    private func bodySnippetFromSource(_ source: String, maxLength: Int, maxLines: Int) -> String {
        // Try MIME-aware extraction first
        if let mimeText = extractPlainTextFromMIME(source) {
            let cleaned = cleanedSnippetLines(from: mimeText, maxLines: maxLines)
            if !cleaned.isEmpty {
                Log.appleScript.debug("MIME parsing: using extracted text/plain for snippet")
                return truncate(cleaned, maxLength: maxLength)
            }
        }
        // Fall back to naive header/body split for non-multipart emails
        Log.appleScript.debug("MIME parsing: falling back to naive header/body split")
        let normalizedSource = source.replacingOccurrences(of: "\r\n", with: "\n")
        guard let range = normalizedSource.range(of: "\n\n") else { return "" }
        let body = normalizedSource[range.upperBound...]
        let cleaned = cleanedSnippetLines(from: String(body), maxLines: maxLines)
        if cleaned.isEmpty {
            return ""
        }
        return truncate(cleaned, maxLength: maxLength)
    }
```

- [ ] **Step 4: Run all MIME tests to verify everything passes**

Run:
```bash
xcodebuild test \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -destination 'platform=macOS' \
  -only-testing:BetterMailTests/MIMESnippetExtractionTests \
  > /tmp/xcodebuild.log 2>&1
tail -n 50 /tmp/xcodebuild.log
```
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add BetterMail/Sources/DataSource/MailAppleScriptClient.swift Tests/MIMESnippetExtractionTests.swift
git commit -m "feat: wire MIME extraction into bodySnippetFromSource fallback"
```

---

### Task 5: Full build verification

**Files:**
- No new changes — verification only

- [ ] **Step 1: Run full build**

```bash
xcodebuild \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build \
  > /tmp/xcodebuild.log 2>&1
tail -n 200 /tmp/xcodebuild.log
grep -n "error:" /tmp/xcodebuild.log || true
grep -n "BUILD FAILED" /tmp/xcodebuild.log || echo "BUILD SUCCEEDED"
```
Expected: BUILD SUCCEEDED

- [ ] **Step 2: Run full test suite**

```bash
xcodebuild test \
  -project BetterMail.xcodeproj \
  -scheme BetterMail \
  -destination 'platform=macOS' \
  > /tmp/xcodebuild.log 2>&1
tail -n 100 /tmp/xcodebuild.log
grep "Test Suite.*Executed" /tmp/xcodebuild.log
grep "failed" /tmp/xcodebuild.log || echo "ALL TESTS PASSED"
```
Expected: ALL TESTS PASSED

- [ ] **Step 3: Fix any failures found**

If any test or build failures, fix them and re-run. Only proceed when clean.
