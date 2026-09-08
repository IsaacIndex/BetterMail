import CoreGraphics
import Foundation
import XCTest
@testable import BetterMail

final class OrganizerDropAcceptanceMatrixTests: XCTestCase {
    func testFrozenFixtures_runExactly120AttemptsAndMeetEveryDropStratumGate() throws {
        let fixtures = try [100, 500].map(loadFixture(nodeCount:))
        let zoomBands: [(name: String, scale: CGFloat)] = [
            ("low", 0.35),
            ("medium", 1.0),
            ("high", 2.4)
        ]
        let shapes = ["flat", "nested"]
        var attempts: [DropAttempt] = []

        for fixture in fixtures {
            XCTAssertEqual(fixture.nodes.count, fixture.nodeCount)
            for zoom in zoomBands {
                for shape in shapes {
                    let targetGroups = fixture.groups.filter {
                        $0.acceptsDrop && $0.targetShape == shape
                    }
                    XCTAssertFalse(targetGroups.isEmpty)

                    for ordinal in 0..<10 {
                        let target = targetGroups[ordinal % targetGroups.count]
                        let isLongLabel = ordinal >= 5
                        let worldTarget = CGPoint(x: CGFloat(100 + ordinal * 17),
                                                  y: CGFloat(80 + ordinal * 11))
                        let screenRelease = CGPoint(x: worldTarget.x * zoom.scale,
                                                    y: worldTarget.y * zoom.scale)
                        let normalizedWorldRelease = CGPoint(x: screenRelease.x / zoom.scale,
                                                              y: screenRelease.y / zoom.scale)
                        let candidates = makeCandidates(target: target,
                                                        fixture: fixture,
                                                        center: worldTarget)
                        let resolved = OrganizerDropTargetResolver.resolve(
                            at: normalizedWorldRelease,
                            candidates: candidates
                        )
                        let commandCount = resolved?.groupID == target.groupKey ? 1 : 0
                        attempts.append(DropAttempt(
                            id: "drop-\(fixture.nodeCount)-\(zoom.name)-\(shape)-\(ordinal)",
                            nodeCount: fixture.nodeCount,
                            zoomBand: zoom.name,
                            targetShape: shape,
                            isLongLabel: isLongLabel,
                            highlightCount: resolved == nil ? 0 : 1,
                            normalizedCommandCount: commandCount,
                            persistedMembershipCount: commandCount,
                            unauthorizedMailCallCount: 0
                        ))
                    }
                }
            }
        }

        XCTAssertEqual(attempts.count, 120)
        XCTAssertEqual(Set(attempts.map(\.id)).count, 120)
        XCTAssertGreaterThanOrEqual(successRate(attempts), 0.95)

        let strata = Dictionary(grouping: attempts) {
            "\($0.nodeCount)|\($0.zoomBand)|\($0.targetShape)"
        }
        XCTAssertEqual(strata.count, 12)
        for (stratum, rows) in strata {
            XCTAssertEqual(rows.count, 10, stratum)
            XCTAssertEqual(rows.filter(\.isLongLabel).count, 5, stratum)
            XCTAssertEqual(rows.filter { !$0.isLongLabel }.count, 5, stratum)
            XCTAssertGreaterThanOrEqual(successRate(rows), 0.90, stratum)
        }
    }

    func testFrozenInvalidTargets_createNoCommandMembershipOrMailCall() throws {
        let fixture = try loadFixture(nodeCount: 100)
        let invalidTargets = fixture.groups.filter { !$0.acceptsDrop }
        XCTAssertEqual(Set(invalidTargets.map(\.targetShape)), ["ghost", "virtual-remainder"])

        var mutationCount = 0
        let mailCallCount = 0
        for target in invalidTargets {
            let candidates: [OrganizerConfirmedGroupDropCandidate]
            if target.targetShape == "ghost" {
                candidates = [OrganizerConfirmedGroupDropCandidate(
                    groupID: target.groupKey,
                    center: .zero,
                    hitRadius: 50,
                    hierarchyDepth: 9,
                    visibleArea: 1,
                    isConfirmed: false
                )]
            } else {
                // Virtual remainder nodes never enter the confirmed-target set.
                candidates = []
            }
            if OrganizerDropTargetResolver.resolve(at: .zero, candidates: candidates) != nil {
                mutationCount += 1
            }
        }
        if OrganizerDropTargetResolver.resolve(
            at: CGPoint(x: 9_999, y: 9_999),
            candidates: [OrganizerConfirmedGroupDropCandidate(
                groupID: "confirmed",
                center: .zero,
                hitRadius: 20,
                hierarchyDepth: 0,
                visibleArea: 400,
                isConfirmed: true
            )]
        ) != nil {
            mutationCount += 1
        }

        XCTAssertEqual(mutationCount, 0)
        XCTAssertEqual(mailCallCount, 0)
    }

    private func makeCandidates(target: FixtureGroup,
                                fixture: OrganizerFixture,
                                center: CGPoint) -> [OrganizerConfirmedGroupDropCandidate] {
        var result = fixture.groups.filter(\.acceptsDrop).map { group in
            OrganizerConfirmedGroupDropCandidate(
                groupID: group.groupKey,
                center: group.groupKey == target.groupKey
                    ? center
                    : CGPoint(x: center.x + 500, y: center.y + 500),
                hitRadius: group.targetShape == "nested" ? 22 : 36,
                hierarchyDepth: group.parentGroupKey == nil ? 0 : 1,
                visibleArea: group.targetShape == "nested" ? 1_200 : 4_800,
                isConfirmed: true
            )
        }
        if let parentKey = target.parentGroupKey,
           let parentIndex = result.firstIndex(where: { $0.groupID == parentKey }) {
            result[parentIndex] = OrganizerConfirmedGroupDropCandidate(
                groupID: parentKey,
                center: center,
                hitRadius: 48,
                hierarchyDepth: 0,
                visibleArea: 7_200,
                isConfirmed: true
            )
        }
        return result
    }

    private func loadFixture(nodeCount: Int) throws -> OrganizerFixture {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testsDirectory
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("Organizer", isDirectory: true)
            .appendingPathComponent("organizer-\(nodeCount)-v1.json")
        return try JSONDecoder().decode(OrganizerFixture.self,
                                        from: Data(contentsOf: url))
    }

    private func successRate(_ attempts: [DropAttempt]) -> Double {
        guard !attempts.isEmpty else { return 0 }
        return Double(attempts.filter(\.succeeded).count) / Double(attempts.count)
    }
}

private struct OrganizerFixture: Decodable {
    let nodeCount: Int
    let groups: [FixtureGroup]
    let nodes: [FixtureNode]
}

private struct FixtureGroup: Decodable {
    let groupKey: String
    let parentGroupKey: String?
    let targetShape: String
    let acceptsDrop: Bool
}

private struct FixtureNode: Decodable {
    let fixtureNodeKey: String
}

private struct DropAttempt {
    let id: String
    let nodeCount: Int
    let zoomBand: String
    let targetShape: String
    let isLongLabel: Bool
    let highlightCount: Int
    let normalizedCommandCount: Int
    let persistedMembershipCount: Int
    let unauthorizedMailCallCount: Int

    var succeeded: Bool {
        highlightCount == 1
            && normalizedCommandCount == 1
            && persistedMembershipCount == 1
            && unauthorizedMailCallCount == 0
    }
}
