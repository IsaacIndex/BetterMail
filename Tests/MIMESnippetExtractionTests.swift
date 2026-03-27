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

    // MARK: - decodeMIMEBody

    func test_decodeMIMEBody_quotedPrintable_decodesHexAndSoftBreaks() {
        // =\n is a QP soft line break (continuation) — it should be removed, joining the lines
        let input = "Hello=20World=\nThis is a test"
        let result = decoder.decodeMIMEBody(input, transferEncoding: "quoted-printable", contentType: "text/plain")
        XCTAssertEqual(result, "Hello WorldThis is a test")
        // =0A encodes a literal newline
        let input2 = "Line one=0ALine two"
        let result2 = decoder.decodeMIMEBody(input2, transferEncoding: "quoted-printable", contentType: "text/plain")
        XCTAssertEqual(result2, "Line one\nLine two")
    }

    func test_decodeMIMEBody_quotedPrintable_utf8MultiByteSequence() {
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
        let input = "caf=E9"
        let result = decoder.decodeMIMEBody(input, transferEncoding: "quoted-printable", contentType: "text/plain; charset=iso-8859-1")
        XCTAssertEqual(result, "café")
    }

    func test_decodeMIMEBody_unknownCharset_fallsBackToUTF8() {
        let input = "hello"
        let result = decoder.decodeMIMEBody(input, transferEncoding: "7bit", contentType: "text/plain; charset=iso-2022-jp")
        XCTAssertEqual(result, "hello")
    }

    // MARK: - extractPlainTextFromMIME

    func test_extractPlainTextFromMIME_simpleMultipartAlternative_extractsPlainText() {
        let source = "Content-Type: multipart/alternative; boundary=\"boundary1\"\n\n--boundary1\nContent-Type: text/plain; charset=utf-8\n\nHello from the plain text part.\n--boundary1\nContent-Type: text/html; charset=utf-8\n\n<html><body>Hello from HTML</body></html>\n--boundary1--\n"
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "Hello from the plain text part.")
    }

    func test_extractPlainTextFromMIME_nestedMultipart_walksToPlainText() {
        let source = "Content-Type: multipart/mixed; boundary=\"outer\"\n\n--outer\nContent-Type: multipart/related; boundary=\"middle\"\n\n--middle\nContent-Type: multipart/alternative; boundary=\"inner\"\n\n--inner\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\n\nDear team,=0APlease review.\n--inner\nContent-Type: text/html\n\n<html><body>Dear team</body></html>\n--inner--\n--middle--\n--outer--\n"
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertTrue(result?.contains("Dear team,") == true)
        XCTAssertTrue(result?.contains("Please review.") == true)
    }

    func test_extractPlainTextFromMIME_base64PlainText_decodes() {
        let body = "This is a base64 encoded message."
        let encoded = Data(body.utf8).base64EncodedString()
        let source = "Content-Type: multipart/alternative; boundary=\"b64bound\"\n\n--b64bound\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: base64\n\n\(encoded)\n--b64bound--\n"
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines), body)
    }

    func test_extractPlainTextFromMIME_nonMultipart_returnsNil() {
        let source = "Content-Type: text/plain; charset=utf-8\n\nJust a simple email.\n"
        XCTAssertNil(decoder.extractPlainTextFromMIME(source))
    }

    func test_extractPlainTextFromMIME_htmlOnly_stripsTagsAsFallback() {
        let source = "Content-Type: multipart/alternative; boundary=\"htmlonly\"\n\n--htmlonly\nContent-Type: text/html; charset=utf-8\n\n<html><head><style>body{color:red}</style></head><body><p>Important message</p></body></html>\n--htmlonly--\n"
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("Important message") == true)
        XCTAssertFalse(result?.contains("<p>") == true)
        XCTAssertFalse(result?.contains("color:red") == true)
    }

    func test_extractPlainTextFromMIME_closingDelimiter_ignoresEpilogue() {
        let source = "Content-Type: multipart/alternative; boundary=\"epilogue\"\n\n--epilogue\nContent-Type: text/plain\n\nReal content.\n--epilogue--\nThis is epilogue junk that should be ignored.\n"
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines), "Real content.")
    }

    func test_extractPlainTextFromMIME_depthLimit_returnsNil() {
        // Use zero-padded names so no boundary is a prefix of another
        var source = ""
        for i in 0..<12 {
            let boundary = String(format: "depth_%02d", i)
            source += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\n\n--\(boundary)\n"
        }
        source += "Content-Type: text/plain\n\nShould not be reached.\n"
        for i in stride(from: 11, through: 0, by: -1) {
            let boundary = String(format: "depth_%02d", i)
            source += "--\(boundary)--\n"
        }
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertNil(result)
    }

    func test_extractPlainTextFromMIME_emptySource_returnsNil() {
        XCTAssertNil(decoder.extractPlainTextFromMIME(""))
    }

    func test_extractPlainTextFromMIME_oversizedSource_returnsNil() {
        let padding = String(repeating: "X", count: 512 * 1024 + 1)
        let source = "Content-Type: multipart/mixed; boundary=\"big\"\n\n--big\nContent-Type: text/plain\n\n\(padding)\n--big--"
        XCTAssertNil(decoder.extractPlainTextFromMIME(source))
    }

    func test_extractPlainTextFromMIME_latin1Part_decodesCorrectly() {
        let source = "Content-Type: multipart/alternative; boundary=\"latin\"\n\n--latin\nContent-Type: text/plain; charset=iso-8859-1\nContent-Transfer-Encoding: quoted-printable\n\ncaf=E9\n--latin--\n"
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines), "café")
    }
}
