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
