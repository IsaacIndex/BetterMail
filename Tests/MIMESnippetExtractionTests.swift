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
}
