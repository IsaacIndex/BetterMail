#if DEBUG
import Combine
import Foundation
import SwiftUI

/// Launch-only configuration for the frozen visual-organizer benchmark.
///
/// The mode is deliberately unavailable in Release builds. A malformed
/// benchmark invocation fails closed to an explanatory screen instead of
/// falling through to the user's real mailbox.
internal nonisolated struct OrganizerBenchmarkConfiguration: Equatable, Sendable {
    internal enum Stratum: String, Equatable, Sendable {
        case warm
        case coldRelaunch = "cold-relaunch"
    }

    internal enum Task: String, Equatable, Sendable {
        case diagnostic
        case livePointer = "live-pointer"
        case placementSet = "placement-set"
        case firstOrganization = "first-organization"
        case fiveConversationOrganization = "five-conversation-organization"
        case retrieval

        internal var evidenceType: OrganizerMetricEvidenceType {
            switch self {
            case .diagnostic:
                return .accessibilityAudit
            case .livePointer, .placementSet:
                return .livePointer
            case .firstOrganization, .fiveConversationOrganization, .retrieval:
                return .timedHumanTask
            }
        }

        internal var targetOutcome: OrganizerMetricTargetOutcome {
            switch self {
            case .diagnostic:
                return .accessibility
            case .livePointer:
                return .pointerDrop
            case .placementSet:
                return .placement
            case .firstOrganization, .fiveConversationOrganization:
                return .organization
            case .retrieval:
                return .retrieval
            }
        }

        internal var timedKindAtTaskReady: OrganizerTimedMetricKind? {
            switch self {
            case .firstOrganization:
                return .firstAction
            case .fiveConversationOrganization:
                return .fiveConversation
            case .diagnostic, .livePointer, .placementSet, .retrieval:
                return nil
            }
        }

        internal var metricContract: OrganizerMetricTaskContract {
            switch self {
            case .diagnostic:
                return .diagnostic
            case .livePointer:
                return OrganizerMetricTaskContract(taskID: .livePointer,
                                                   sourceNodeKeys: [],
                                                   destinationGroupKeys: [],
                                                   queryKey: nil)
            case .placementSet:
                return OrganizerMetricTaskContract(taskID: .placementSet,
                                                   sourceNodeKeys: [],
                                                   destinationGroupKeys: [],
                                                   queryKey: nil)
            case .firstOrganization:
                return OrganizerMetricTaskContract(
                    taskID: .firstOrganization,
                    sourceNodeKeys: ["node-100-0000"],
                    destinationGroupKeys: ["group-flat-00"],
                    queryKey: nil
                )
            case .fiveConversationOrganization:
                return OrganizerMetricTaskContract(
                    taskID: .fiveConversationOrganization,
                    sourceNodeKeys: (0..<5).map { String(format: "node-100-%04d", $0) },
                    destinationGroupKeys: [
                        "group-flat-00",
                        "group-flat-01",
                        "group-nested-00",
                        "group-nested-01",
                        "group-flat-02"
                    ],
                    queryKey: OrganizerMetricsRecorder.frozenRetrievalQuery
                )
            case .retrieval:
                return OrganizerMetricTaskContract(
                    taskID: .retrieval,
                    sourceNodeKeys: ["node-100-0004"],
                    destinationGroupKeys: ["group-flat-02"],
                    queryKey: OrganizerMetricsRecorder.frozenRetrievalQuery
                )
            }
        }
    }

    internal struct PlacementSetContract: Equatable, Sendable {
        internal let setID: String
        internal let sourceNodeKeys: [String]
        internal let destinationGroupKey: String
    }

    internal static let placementSetContracts: [PlacementSetContract] = [
        PlacementSetContract(
            setID: "placement-set-01",
            sourceNodeKeys: (0..<20).map { String(format: "node-500-%04d", $0) },
            destinationGroupKey: "group-flat-00"
        ),
        PlacementSetContract(
            setID: "placement-set-02",
            sourceNodeKeys: (20..<40).map { String(format: "node-500-%04d", $0) },
            destinationGroupKey: "group-flat-01"
        ),
        PlacementSetContract(
            setID: "placement-set-03",
            sourceNodeKeys: (40..<60).map { String(format: "node-500-%04d", $0) },
            destinationGroupKey: "group-nested-00"
        ),
        PlacementSetContract(
            setID: "placement-set-04",
            sourceNodeKeys: (60..<80).map { String(format: "node-500-%04d", $0) },
            destinationGroupKey: "group-nested-01"
        ),
        PlacementSetContract(
            setID: "placement-set-05",
            sourceNodeKeys: (80..<100).map { String(format: "node-500-%04d", $0) },
            destinationGroupKey: "group-flat-02"
        )
    ]

    internal let nodeCount: Int
    internal let runID: String
    internal let reset: Bool
    internal let stratum: Stratum
    internal let task: Task
    internal let placementSetID: String?

    internal init(nodeCount: Int,
                  runID: String,
                  reset: Bool,
                  stratum: Stratum,
                  task: Task = .diagnostic,
                  placementSetID: String? = nil) {
        self.nodeCount = nodeCount
        self.runID = runID
        self.reset = reset
        self.stratum = stratum
        self.task = task
        self.placementSetID = placementSetID
    }

    internal var fixtureID: String {
        String(format: "organizer-%03d-v1", nodeCount)
    }

    internal var defaultsSuiteName: String {
        "com.bettermail.organizer-benchmark.\(fixtureID).\(runID)"
    }

    internal var metricContract: OrganizerMetricTaskContract {
        guard task == .placementSet,
              let placementSetID,
              let placement = Self.placementSetContracts.first(where: {
                  $0.setID == placementSetID
              }) else {
            return task.metricContract
        }
        return OrganizerMetricTaskContract(
            taskID: .placementSet,
            sourceNodeKeys: placement.sourceNodeKeys,
            destinationGroupKeys: [placement.destinationGroupKey],
            queryKey: nil
        )
    }

    internal func runtimeMetricContract(
        fixture: OrganizerBenchmarkFixture
    ) -> OrganizerMetricRuntimeTaskContract {
        let exportedContract = metricContract
        let rawThreadIDByNodeKey = Dictionary(uniqueKeysWithValues: fixture.nodes.map {
            ($0.fixtureNodeKey, $0.effectiveConversationKey)
        })
        let destinationKeys: [String]
        if exportedContract.destinationGroupKeys.count == 1 {
            destinationKeys = Array(
                repeating: exportedContract.destinationGroupKeys[0],
                count: exportedContract.sourceNodeKeys.count
            )
        } else {
            destinationKeys = exportedContract.destinationGroupKeys
        }
        let memberships = zip(exportedContract.sourceNodeKeys, destinationKeys).compactMap {
            nodeKey, destinationGroupKey -> OrganizerMetricExpectedMembership? in
            guard let rawThreadID = rawThreadIDByNodeKey[nodeKey] else { return nil }
            return OrganizerMetricExpectedMembership(rawThreadID: rawThreadID,
                                                      destinationGroupKey: destinationGroupKey)
        }
        return OrganizerMetricRuntimeTaskContract(
            expectedMemberships: memberships,
            placementSetID: placementSetID,
            allowsRetrievalTiming: task == .fiveConversationOrganization || task == .retrieval
        )
    }
}

private nonisolated enum OrganizerBenchmarkArgumentValue {
    case value(String?)
    case failure(String)
}

internal nonisolated enum OrganizerBenchmarkLaunchSelection: Equatable, Sendable {
    case inactive
    case active(OrganizerBenchmarkConfiguration)
    case invalid(String)

    internal static func parse(arguments: [String]) -> OrganizerBenchmarkLaunchSelection {
        let prefix = "--organizer-benchmark-"
        let benchmarkArguments = arguments.filter { $0.hasPrefix(prefix) }
        guard !benchmarkArguments.isEmpty else { return .inactive }

        let valueFlags: Set<String> = [
            "--organizer-benchmark-fixture",
            "--organizer-benchmark-run",
            "--organizer-benchmark-stratum",
            "--organizer-benchmark-task",
            "--organizer-benchmark-placement-set"
        ]
        let booleanFlags: Set<String> = ["--organizer-benchmark-reset"]
        let knownFlags = valueFlags.union(booleanFlags)
        guard benchmarkArguments.allSatisfy(knownFlags.contains) else {
            return .invalid("Unknown organizer benchmark launch argument.")
        }

        func singleValue(after flag: String) -> OrganizerBenchmarkArgumentValue {
            let indices = arguments.indices.filter { arguments[$0] == flag }
            guard indices.count <= 1 else {
                return .failure("Duplicate organizer benchmark launch argument: \(flag)")
            }
            guard let index = indices.first else { return .value(nil) }
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex,
                  !arguments[valueIndex].hasPrefix("--") else {
                return .failure("Missing organizer benchmark value for \(flag)")
            }
            return .value(arguments[valueIndex])
        }

        let fixtureValue: String
        switch singleValue(after: "--organizer-benchmark-fixture") {
        case .value(let value?): fixtureValue = value
        case .value(nil): return .invalid("The organizer benchmark fixture is required.")
        case .failure(let message): return .invalid(message)
        }
        guard let nodeCount = Int(fixtureValue), [100, 500].contains(nodeCount) else {
            return .invalid("Organizer benchmark fixture must be 100 or 500.")
        }

        let runID: String
        switch singleValue(after: "--organizer-benchmark-run") {
        case .value(let value?): runID = value
        case .value(nil): runID = "synthetic-run-manual"
        case .failure(let message): return .invalid(message)
        }
        guard isValidRunID(runID) else {
            return .invalid("Organizer benchmark run IDs must start with synthetic- and contain only lowercase letters, digits, or hyphens.")
        }

        let stratum: OrganizerBenchmarkConfiguration.Stratum
        switch singleValue(after: "--organizer-benchmark-stratum") {
        case .value(let value?):
            guard let parsed = OrganizerBenchmarkConfiguration.Stratum(rawValue: value) else {
                return .invalid("Organizer benchmark stratum must be warm or cold-relaunch.")
            }
            stratum = parsed
        case .value(nil):
            stratum = .warm
        case .failure(let message):
            return .invalid(message)
        }

        let resetCount = arguments.filter { $0 == "--organizer-benchmark-reset" }.count
        guard resetCount <= 1 else {
            return .invalid("Duplicate organizer benchmark reset argument.")
        }
        let task: OrganizerBenchmarkConfiguration.Task
        switch singleValue(after: "--organizer-benchmark-task") {
        case .value(let value?):
            guard let parsed = OrganizerBenchmarkConfiguration.Task(rawValue: value) else {
                return .invalid("Organizer benchmark task is not recognized.")
            }
            task = parsed
        case .value(nil):
            task = .diagnostic
        case .failure(let message):
            return .invalid(message)
        }
        guard task.evidenceType != .timedHumanTask || nodeCount == 100 else {
            return .invalid("Timed organizer benchmark tasks require fixture 100.")
        }
        let placementSetID: String?
        switch singleValue(after: "--organizer-benchmark-placement-set") {
        case .value(let value?):
            placementSetID = value
        case .value(nil):
            placementSetID = nil
        case .failure(let message):
            return .invalid(message)
        }
        if task == .placementSet {
            guard nodeCount == 500 else {
                return .invalid("Placement-set organizer benchmark tasks require fixture 500.")
            }
            guard let placementSetID,
                  OrganizerBenchmarkConfiguration.placementSetContracts.contains(where: {
                      $0.setID == placementSetID
                  }) else {
                return .invalid("Placement-set organizer benchmark tasks require one frozen placement-set ID.")
            }
        } else if placementSetID != nil {
            return .invalid("A placement-set ID is valid only for the placement-set task.")
        }
        return .active(OrganizerBenchmarkConfiguration(nodeCount: nodeCount,
                                                       runID: runID,
                                                       reset: resetCount == 1,
                                                       stratum: stratum,
                                                       task: task,
                                                       placementSetID: placementSetID))
    }

    private static func isValidRunID(_ value: String) -> Bool {
        guard value.hasPrefix("synthetic-"), (1...64).contains(value.count) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

internal nonisolated enum OrganizerBenchmarkEnvironmentError: LocalizedError, Equatable, Sendable {
    case applicationSupportUnavailable
    case defaultsUnavailable
    case unsafePath
    case preparationFailed

    internal var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "The synthetic benchmark Application Support directory is unavailable."
        case .defaultsUnavailable:
            return "The synthetic benchmark preferences domain is unavailable."
        case .unsafePath:
            return "The synthetic benchmark path did not pass its safety check."
        case .preparationFailed:
            return "The synthetic benchmark workspace could not be prepared."
        }
    }
}

internal nonisolated enum OrganizerBenchmarkEnvironment {
    internal static func prepare(_ configuration: OrganizerBenchmarkConfiguration,
                                 fileManager: FileManager = .default) throws {
        guard UserDefaults(suiteName: configuration.defaultsSuiteName) != nil else {
            throw OrganizerBenchmarkEnvironmentError.defaultsUnavailable
        }
        if configuration.reset {
            UserDefaults.standard.removePersistentDomain(forName: configuration.defaultsSuiteName)
        }

        let rootURL = try runRootURL(for: configuration, fileManager: fileManager)
        do {
            if configuration.reset, fileManager.fileExists(atPath: rootURL.path) {
                try fileManager.removeItem(at: rootURL)
            }
            try fileManager.createDirectory(at: rootURL,
                                            withIntermediateDirectories: true)
        } catch {
            throw OrganizerBenchmarkEnvironmentError.preparationFailed
        }
    }

    internal static func runRootURL(for configuration: OrganizerBenchmarkConfiguration,
                                    fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask).first else {
            throw OrganizerBenchmarkEnvironmentError.applicationSupportUnavailable
        }
        return try runRootURL(for: configuration,
                              applicationSupportURL: applicationSupport)
    }

    internal static func runRootURL(for configuration: OrganizerBenchmarkConfiguration,
                                    applicationSupportURL: URL) throws -> URL {
        guard configuration.fixtureID.hasPrefix("organizer-"),
              configuration.runID.hasPrefix("synthetic-"),
              !configuration.fixtureID.contains("/"),
              !configuration.runID.contains("/") else {
            throw OrganizerBenchmarkEnvironmentError.unsafePath
        }
        let benchmarkRoot = applicationSupportURL
            .appendingPathComponent("BetterMail", isDirectory: true)
            .appendingPathComponent("OrganizerBenchmark", isDirectory: true)
        let runRoot = benchmarkRoot
            .appendingPathComponent(configuration.fixtureID, isDirectory: true)
            .appendingPathComponent(configuration.runID, isDirectory: true)
            .standardizedFileURL
        let expectedPrefix = benchmarkRoot.standardizedFileURL.path + "/"
        guard runRoot.path.hasPrefix(expectedPrefix) else {
            throw OrganizerBenchmarkEnvironmentError.unsafePath
        }
        return runRoot
    }
}

/// Codable twin of the frozen JSON fixtures. Keeping the generator in the app
/// avoids bundling test assets into the production target while tests can
/// still prove byte-level field parity with the checked-in contract.
internal nonisolated struct OrganizerBenchmarkFixture: Codable, Equatable, Sendable {
    internal struct Point: Codable, Equatable, Sendable {
        internal let x: Int
        internal let y: Int
    }

    internal struct Node: Codable, Equatable, Sendable {
        internal let fixtureNodeKey: String
        internal let effectiveConversationKey: String
        internal let displayLabel: String
        internal let currentGroupKey: String?
        internal let messageCount: Int
        internal let eligibleForPlacement: Bool
        internal let position: Point
        internal let longLabel: Bool
    }

    internal struct Group: Codable, Equatable, Sendable {
        internal let groupKey: String
        internal let displayLabel: String
        internal let parentGroupKey: String?
        internal let targetShape: String
        internal let acceptsDrop: Bool
        internal let longLabel: Bool
    }

    internal let schemaVersion: String
    internal let fixtureId: String
    internal let fixtureKind: String
    internal let description: String
    internal let nodeCount: Int
    internal let scopeKey: String
    internal let nodes: [Node]
    internal let groups: [Group]
    internal let invalidTargets: [String]
    internal let zoomBands: [String: Double]
    internal let labelVariants: [String: String]

    internal static func make(nodeCount: Int) -> OrganizerBenchmarkFixture? {
        guard [100, 500].contains(nodeCount) else { return nil }
        let groups = (0..<4).map { index in
            Group(groupKey: String(format: "group-flat-%02d", index),
                  displayLabel: String(format: "Confirmed Group %02d", index + 1),
                  parentGroupKey: nil,
                  targetShape: "flat",
                  acceptsDrop: true,
                  longLabel: index.isMultiple(of: 2))
        } + (0..<4).map { index in
            Group(groupKey: String(format: "group-nested-%02d", index),
                  displayLabel: String(format: "Nested Group %02d", index + 1),
                  parentGroupKey: String(format: "group-flat-%02d", index),
                  targetShape: "nested",
                  acceptsDrop: true,
                  longLabel: !index.isMultiple(of: 2))
        } + [
            Group(groupKey: "group-suggested-00",
                  displayLabel: "Potential Group 01",
                  parentGroupKey: nil,
                  targetShape: "ghost",
                  acceptsDrop: false,
                  longLabel: false),
            Group(groupKey: "group-remainder-00",
                  displayLabel: "More conversations",
                  parentGroupKey: nil,
                  targetShape: "virtual-remainder",
                  acceptsDrop: false,
                  longLabel: false)
        ]
        let columns = nodeCount == 100 ? 10 : 25
        let nodes = (0..<nodeCount).map { index in
            Node(fixtureNodeKey: String(format: "node-%03d-%04d", nodeCount, index),
                 effectiveConversationKey: String(format: "conversation-%03d-%04d", nodeCount, index),
                 displayLabel: String(format: "Synthetic conversation %04d", index + 1),
                 currentGroupKey: nil,
                 messageCount: 1 + (index % 5),
                 eligibleForPlacement: true,
                 position: Point(x: (index % columns) * 92 + 48,
                                 y: (index / columns) * 58 + 48),
                 longLabel: index.isMultiple(of: 2))
        }
        return OrganizerBenchmarkFixture(
            schemaVersion: "organizer-fixture-v1",
            fixtureId: String(format: "organizer-%03d-v1", nodeCount),
            fixtureKind: "synthetic-organizer-canvas",
            description: "Deterministic synthetic organizer canvas with \(nodeCount) conversation nodes.",
            nodeCount: nodeCount,
            scopeKey: String(format: "scope-%03d-v1", nodeCount),
            nodes: nodes,
            groups: groups,
            invalidTargets: [
                "group-suggested-00",
                "group-remainder-00",
                "canvas-outside-targets"
            ],
            zoomBands: ["low": 0.75, "medium": 1.0, "high": 1.75],
            labelVariants: [
                "short": "Synthetic conversation 0001",
                "long": "Synthetic conversation 0001 — deterministic long display label for pointer targeting"
            ]
        )
    }

    internal func emailMessages() -> [EmailMessage] {
        let baseDate = Date(timeIntervalSince1970: 1_787_529_600)
        return nodes.enumerated().flatMap { nodeIndex, node in
            let rootMessageID = "<\(node.effectiveConversationKey)>"
            return (0..<node.messageCount).map { messageIndex in
                let messageID = messageIndex == 0
                    ? rootMessageID
                    : "<\(node.effectiveConversationKey)-message-\(String(format: "%04d", messageIndex))>"
                let numericID = Int64(nodeCount) * 1_000_000
                    + Int64(nodeIndex) * 10
                    + Int64(messageIndex)
                let stableUUID = UUID(uuidString: String(
                    format: "00000000-0000-4000-8000-%012lld",
                    numericID
                )) ?? UUID()
                let subject = node.longLabel
                    ? "\(node.displayLabel) — deterministic long display label for pointer targeting"
                    : node.displayLabel
                let retrievalMarker = node.fixtureNodeKey.hasSuffix("-0004")
                    ? " synthetic-query-organized-0004"
                    : ""
                return EmailMessage(
                    id: stableUUID,
                    messageID: messageID,
                    internalMailID: nil,
                    mailboxID: "Synthetic Inbox",
                    accountName: "Synthetic Benchmark",
                    subject: subject,
                    from: "synthetic-sender-\(String(format: "%04d", nodeIndex))@example.invalid",
                    to: "synthetic-user@example.invalid",
                    date: baseDate
                        .addingTimeInterval(TimeInterval(-nodeIndex * 60 + messageIndex)),
                    snippet: "Synthetic benchmark content for \(node.fixtureNodeKey).\(retrievalMarker)",
                    isUnread: nodeIndex.isMultiple(of: 3),
                    inReplyTo: messageIndex == 0 ? nil : rootMessageID,
                    references: messageIndex == 0 ? [] : [rootMessageID],
                    threadID: node.effectiveConversationKey
                )
            }
        }
    }

    internal func threadFolders() -> [ThreadFolder] {
        groups.enumerated().compactMap { index, group in
            guard group.acceptsDrop else { return nil }
            let hue = Double(index % 8) / 8.0
            return ThreadFolder(
                id: group.groupKey,
                title: group.displayLabel,
                color: ThreadFolderColor(red: 0.38 + hue * 0.22,
                                         green: 0.48 + (1 - hue) * 0.12,
                                         blue: 0.62 - hue * 0.18,
                                         alpha: 1),
                threadIDs: [],
                parentID: group.parentGroupKey,
                mailboxAccount: nil,
                mailboxPath: nil
            )
        }
    }

    @MainActor
    internal func initialSpatialSnapshot() -> GraphSpatialSnapshot {
        let nodePositions = nodes.reduce(into: [String: GraphSpatialPoint]()) { result, node in
            result[GraphData.threadNodeID(for: node.effectiveConversationKey)] = GraphSpatialPoint(
                x: Double(node.position.x),
                y: Double(node.position.y)
            )
        }
        let confirmed = groups.filter(\.acceptsDrop)
        let anchors = confirmed.enumerated().reduce(into: [String: GraphSpatialPoint]()) { result, entry in
            let (index, group) = entry
            result[group.groupKey] = GraphSpatialPoint(
                x: Double(120 + (index % 4) * 100),
                y: Double(180 + (index / 4) * 180)
            )
        }
        return GraphSpatialSnapshot(nodePositions: nodePositions,
                                    confirmedGroupAnchors: anchors,
                                    zoomScale: 1,
                                    panOffset: .zero,
                                    updatedAt: Date(timeIntervalSince1970: 1_787_529_600))
    }
}

internal nonisolated enum OrganizerBenchmarkMailBoundaryError: LocalizedError, Equatable, Sendable {
    case blocked

    internal var errorDescription: String? {
        "Apple Mail mutations are disabled in the synthetic organizer benchmark."
    }
}

internal actor OrganizerBenchmarkMailBoundary {
    private var deniedMutationCount = 0

    internal func recordDeniedMutation() {
        deniedMutationCount += 1
    }

    internal func snapshot() -> (externalCallCount: Int, deniedMutationCount: Int) {
        // This boundary has no production transport, so its external-call
        // count is structurally fixed at zero.
        (externalCallCount: 0, deniedMutationCount: deniedMutationCount)
    }
}

internal actor OrganizerBenchmarkMailClient: MailCanvasClient, GraphSnipMailMoving {
    private let messages: [EmailMessage]
    private let boundary: OrganizerBenchmarkMailBoundary

    internal init(messages: [EmailMessage], boundary: OrganizerBenchmarkMailBoundary) {
        self.messages = messages
        self.boundary = boundary
    }

    internal func fetchMessages(since date: Date?,
                                limit: Int,
                                mailbox: String,
                                account: String?,
                                snippetLineLimit: Int,
                                profile: MailFetchProfile) async throws -> [EmailMessage] {
        Array(messages.prefix(max(0, limit)))
    }

    internal func fetchMailboxHierarchy() async throws -> [MailboxFolder] {
        []
    }

    internal func countMessages(in range: DateInterval,
                                mailbox: String,
                                account: String?) async throws -> Int {
        messages.filter { range.contains($0.date) }.count
    }

    internal func fetchMessages(in range: DateInterval,
                                limit: Int,
                                mailbox: String,
                                account: String?,
                                snippetLineLimit: Int) async throws -> [EmailMessage] {
        Array(messages.filter { range.contains($0.date) }.prefix(max(0, limit)))
    }

    internal func countMessages(matchingNormalizedSubjects normalizedSubjects: [String],
                                mailbox: String,
                                account: String?) async throws -> Int {
        let subjects = Set(normalizedSubjects.map(Self.normalizedSubject))
        return messages.filter {
            subjects.contains(Self.normalizedSubject($0.subject))
        }.count
    }

    internal func fetchMessages(matchingNormalizedSubjects normalizedSubjects: [String],
                                limit: Int,
                                mailbox: String,
                                account: String?,
                                snippetLineLimit: Int) async throws -> [EmailMessage] {
        let subjects = Set(normalizedSubjects.map(Self.normalizedSubject))
        return Array(messages.filter {
            subjects.contains(Self.normalizedSubject($0.subject))
        }.prefix(max(0, limit)))
    }

    internal func moveMessages(messageIDs: [String],
                               toMailboxPath mailboxPath: String,
                               account: String?,
                               sourceMailboxPath: String?,
                               sourceAccount: String?) async throws -> GraphMailMoveResult {
        await boundary.recordDeniedMutation()
        throw OrganizerBenchmarkMailBoundaryError.blocked
    }

    private nonisolated static func normalizedSubject(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

internal nonisolated struct OrganizerBenchmarkDeniedMailTransport: OrganizationMailGatewayTransport, Sendable {
    internal let boundary: OrganizerBenchmarkMailBoundary

    internal func createMailbox(destination: OrganizationMailDestination) async throws -> OrganizationMailTransportResult {
        await boundary.recordDeniedMutation()
        throw OrganizerBenchmarkMailBoundaryError.blocked
    }

    internal func move(routes: [OrganizationMailRoute],
                       destination: OrganizationMailDestination) async throws -> OrganizationMailTransportResult {
        await boundary.recordDeniedMutation()
        throw OrganizerBenchmarkMailBoundaryError.blocked
    }

    internal func restore(routes: [OrganizationMailRestoreRoute]) async throws -> OrganizationMailTransportResult {
        await boundary.recordDeniedMutation()
        throw OrganizerBenchmarkMailBoundaryError.blocked
    }
}

internal nonisolated struct OrganizerBenchmarkSpatialFileAccessor: GraphSpatialFileAccessing, Sendable {
    internal let fileURL: URL

    internal func read() throws -> Data {
        do {
            return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            throw GraphSpatialFileAccessError.notFound
        }
    }

    internal func writeAtomically(_ data: Data) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
    }
}

internal nonisolated struct OrganizerBenchmarkSpatialSecretProvider: GraphSpatialSecretProviding, Sendable {
    internal func loadOrCreateSecret() throws -> Data {
        Data("bettermail-synthetic-spatial-secret-v1".utf8)
    }
}

/// DEBUG-only geometry receipt for the frozen synthetic fixture. Production
/// mailbox identifiers never enter this file; it exists so installed native
/// pointer audits can use the exact screen-space frames that satisfied the
/// rendered accessibility readiness contract.
internal nonisolated struct OrganizerBenchmarkRenderedGeometryDocument: Codable,
                                                                        Equatable,
                                                                        Sendable {
    internal static let currentSchemaVersion = "organizer-rendered-geometry-v1"
    internal static let coordinateSpaceIdentifier = "global-screen-bottom-left"

    internal let schemaVersion: String
    internal let coordinateSpace: String
    internal let screenFrame: OrganizerRenderedAccessibilityFrame?
    internal let conversationFramesByRawThreadID:
        [String: OrganizerRenderedAccessibilityFrame]
    internal let confirmedGroupFramesByGroupKey:
        [String: OrganizerRenderedAccessibilityFrame]

    internal init(snapshot: OrganizerRenderedGraphSnapshot,
                  allowedRawThreadIDs: Set<String>,
                  allowedGroupKeys: Set<String>) {
        schemaVersion = Self.currentSchemaVersion
        coordinateSpace = Self.coordinateSpaceIdentifier
        screenFrame = snapshot.accessibilityScreenFrame
        conversationFramesByRawThreadID =
            snapshot.accessibleConversationFramesByRawThreadID.filter {
                allowedRawThreadIDs.contains($0.key) && $0.value.isFiniteAndNonEmpty
            }
        confirmedGroupFramesByGroupKey =
            snapshot.accessibleConfirmedGroupFramesByGroupKey.filter {
                allowedGroupKeys.contains($0.key) && $0.value.isFiniteAndNonEmpty
            }
    }
}

@MainActor
private final class OrganizerBenchmarkTopicProvider: GraphTopicProviding {
    func generateTopic(_ request: GraphTopicRequest) async throws -> GraphTopicSignal? {
        guard request.subject.hasPrefix("Synthetic conversation") else { return nil }
        return GraphTopicSignal(topic: "Potential Group 01",
                                displayTitle: "Potential Group 01",
                                confidence: 0.99,
                                supportingReason: "Synthetic benchmark conversations share the frozen review topic.")
    }
}

@MainActor
internal final class OrganizerBenchmarkRuntime: ObservableObject {
    internal enum State: Equatable {
        case seeding
        case launching
        case ready
        case failed(String)
    }

    @Published internal private(set) var state: State = .seeding

    internal let configuration: OrganizerBenchmarkConfiguration
    internal let fixture: OrganizerBenchmarkFixture
    internal let viewModel: ThreadCanvasViewModel
    internal let graphSettings: GraphCanvasSettings
    internal let graphViewModel: GraphCanvasViewModel
    internal let boundary: OrganizerBenchmarkMailBoundary
    internal let metricsRecorder: OrganizerMetricsRecorder

    private let store: MessageStore
    private let spatialStore: GraphSpatialStateStore
    private let renderedGeometryURL: URL
    private var modelReadinessSatisfied = false
    private var latestRenderedSnapshot: OrganizerRenderedGraphSnapshot?
    private var isReadinessFinalizationScheduled = false
    private var isFinalizingReadiness = false
    private var pendingRenderedGeometry: OrganizerBenchmarkRenderedGeometryDocument?
    private var renderedGeometryWriteTask: Task<Void, Never>?

    internal init(configuration: OrganizerBenchmarkConfiguration,
                  settings: AutoRefreshSettings,
                  inspectorSettings: InspectorViewSettings,
                  displaySettings: ThreadCanvasDisplaySettings,
                  pinnedFolderSettings: PinnedFolderSettings,
                  activityCenter: ProcessingActivityCenter) {
        self.configuration = configuration
        self.fixture = OrganizerBenchmarkFixture.make(nodeCount: configuration.nodeCount)!

        let defaults = UserDefaults(suiteName: configuration.defaultsSuiteName)!
        let runRoot = try! OrganizerBenchmarkEnvironment.runRootURL(for: configuration)
        self.renderedGeometryURL = runRoot.appendingPathComponent(
            "OrganizerRenderedGeometry.json"
        )
        let metricStratum: OrganizerMetricStratum = configuration.stratum == .warm
            ? .warm
            : .coldRelaunch
        let metricsRecorder = try! OrganizerMetricsRecorder(
            runID: configuration.runID,
            fixtureID: configuration.fixtureID,
            protocolID: "visual-email-organizer-v1",
            appBuild: Self.appBuildIdentifier(),
            evidenceType: configuration.task.evidenceType,
            defaultStratum: metricStratum,
            targetOutcome: configuration.task.targetOutcome,
            taskContract: configuration.metricContract,
            runtimeTaskContract: configuration.runtimeMetricContract(fixture: fixture),
            outputURL: runRoot.appendingPathComponent("OrganizerMetrics.json")
        )
        self.metricsRecorder = metricsRecorder
        let store = MessageStore(userDefaults: defaults,
                                 storeURL: runRoot.appendingPathComponent("Messages.sqlite"))
        self.store = store

        let routeCrypto = CryptoKitOrganizationRouteCryptoProvider(
            keyIdentifier: "synthetic-route-key-v1",
            keyData: Data(repeating: 0x42, count: 32)
        )
        let operationStore = OrganizationOperationStore(
            fileURL: runRoot.appendingPathComponent("OrganizationOperations.json"),
            routeCrypto: routeCrypto
        )
        let boundary = OrganizerBenchmarkMailBoundary()
        self.boundary = boundary
        let messages = fixture.emailMessages()
        let mailClient = OrganizerBenchmarkMailClient(messages: messages,
                                                      boundary: boundary)
        let dayFetchCoordinator = DayFetchCoordinator(client: mailClient,
                                                      store: store)
        let mailService = OrganizationMailExecutionService(
            operationStore: operationStore,
            transport: OrganizerBenchmarkDeniedMailTransport(boundary: boundary),
            metricsRecorder: metricsRecorder
        )
        let spatialStore = GraphSpatialStateStore(
            fileAccessor: OrganizerBenchmarkSpatialFileAccessor(
                fileURL: runRoot.appendingPathComponent("GraphSpatialState.json")
            ),
            secretProvider: OrganizerBenchmarkSpatialSecretProvider()
        )
        self.spatialStore = spatialStore

        settings.isEnabled = false
        let automationSettings = GraphAutomationSettings(userDefaults: defaults)
        automationSettings.isPaused = false
        let topicProvider = OrganizerBenchmarkTopicProvider()
        let unavailableRelationship: @MainActor @Sendable () -> GraphRelationshipCapability = {
            GraphRelationshipCapability(provider: nil,
                                        providerVersion: "synthetic-none-v1",
                                        statusMessage: "Synthetic benchmark relationship generation is disabled.",
                                        shouldRetry: false)
        }
        let syntheticTopicCapability: @MainActor @Sendable () -> GraphTopicCapability = {
            GraphTopicCapability(provider: topicProvider,
                                 statusMessage: "Synthetic benchmark topic provider ready.",
                                 providerID: "synthetic-topic-v1",
                                 shouldRetry: false)
        }
        self.viewModel = ThreadCanvasViewModel(
            settings: settings,
            inspectorSettings: inspectorSettings,
            pinnedFolderSettings: pinnedFolderSettings,
            mailboxFolderOrderSettings: MailboxFolderOrderSettings(userDefaults: defaults),
            mailboxThreadAutoMoveSettings: MailboxThreadAutoMoveSettings(userDefaults: defaults),
            store: store,
            organizationOperationStore: operationStore,
            organizationMailService: mailService,
            organizerMetricsRecorder: metricsRecorder,
            client: mailClient,
            calendarRecoveryClient: mailClient,
            dayFetchCoordinator: dayFetchCoordinator,
            summaryCapability: EmailSummaryCapability(provider: nil,
                                                       statusMessage: "Synthetic benchmark summaries are disabled.",
                                                       providerID: "synthetic-none-v1"),
            tagCapability: EmailTagCapability(provider: nil,
                                              statusMessage: "Synthetic benchmark tags are disabled.",
                                              providerID: "synthetic-none-v1"),
            graphAutomationSettings: automationSettings,
            graphAutomationMailClient: mailClient,
            mailAutomationConsentProvider: {
                OrganizationMailAutomationConsent.resolve(from: defaults)
            },
            graphRelationshipCapabilityProvider: unavailableRelationship,
            graphTopicCapabilityProvider: syntheticTopicCapability,
            activityCenter: activityCenter,
            performsInitialSourceRefresh: false,
            includesAllCachedMessagesInRethread: true
        )

        let graphSettings = GraphCanvasSettings(userDefaults: defaults)
        graphSettings.mode = .graph
        graphSettings.visibleBranchCount = GraphCanvasSettings.visibleBranchCountRange.upperBound
        graphSettings.visibleBranchesPerNode = GraphCanvasSettings.visibleBranchesPerNodeRange.upperBound
        graphSettings.visibleEmailsPerThread = GraphCanvasSettings.visibleEmailsPerThreadRange.upperBound
        graphSettings.soundOn = false
        graphSettings.reduceMotionOverride = .reduce
        self.graphSettings = graphSettings
        self.graphViewModel = GraphCanvasViewModel(
            store: store,
            mailClient: mailClient,
            organizationOperationStore: operationStore,
            organizationMailService: mailService,
            graphTitleCapabilityProvider: {
                GraphTitleCapability(provider: nil,
                                     statusMessage: "Synthetic benchmark titles are disabled.",
                                     providerID: "synthetic-none-v1",
                                     shouldRetry: false)
            },
            graphTopicCapabilityProvider: syntheticTopicCapability,
            graphSpatialStore: spatialStore
        )
    }

    internal func seedIfNeeded() async {
        guard state == .seeding else { return }
        do {
            try await store.upsert(messages: fixture.emailMessages())
            let existingFolders = try await store.fetchThreadFolders()
            let existingIDs = Set(existingFolders.map(\.id))
            let missingFolders = fixture.threadFolders().filter { !existingIDs.contains($0.id) }
            try await store.upsertThreadFolders(missingFolders)

            let nodeIDs = Set(fixture.nodes.map {
                GraphData.threadNodeID(for: $0.effectiveConversationKey)
            })
            let groupIDs = Set(fixture.groups.filter(\.acceptsDrop).map {
                $0.groupKey
            })
            let existingSpatial = await spatialStore.load(scopeID: MailboxScope.allEmails.graphPagingScopeID,
                                                          sourceNodeIDs: nodeIDs,
                                                          confirmedGroupIDs: groupIDs)
            if existingSpatial.nodePositions.isEmpty &&
                existingSpatial.confirmedGroupAnchors.isEmpty {
                try await spatialStore.save(fixture.initialSpatialSnapshot(),
                                            forScopeID: MailboxScope.allEmails.graphPagingScopeID)
            }
            state = .launching
        } catch {
            state = .failed("Synthetic benchmark preparation failed without opening Apple Mail.")
        }
    }

    internal func evaluateReadiness(roots: [ThreadNode], graphData: GraphData) async {
        guard state == .launching else { return }
        let expectedGroupIDs = Set(fixture.groups.filter(\.acceptsDrop).map {
            "folder:\($0.groupKey)"
        })
        let visibleGroupIDs = Set(graphData.groupings.filter { $0.kind == .folder }.map(\.id))
        guard roots.count == fixture.nodeCount,
              expectedGroupIDs.isSubset(of: visibleGroupIDs),
              !graphData.threads.isEmpty else { return }
        modelReadinessSatisfied = true
        scheduleReadinessFinalizationIfNeeded()
    }

    internal func evaluateRenderedReadiness(
        _ receipt: OrganizerRenderedGraphReceipt
    ) {
        scheduleRenderedGeometryWrite(receipt.snapshot)
        switch state {
        case .seeding:
            latestRenderedSnapshot = receipt.snapshot
            return
        case .launching:
            latestRenderedSnapshot = receipt.snapshot
            scheduleReadinessFinalizationIfNeeded()
        case .ready, .failed:
            return
        }
    }

    private func scheduleRenderedGeometryWrite(
        _ snapshot: OrganizerRenderedGraphSnapshot
    ) {
        guard snapshot.isLayoutSettled else { return }
        pendingRenderedGeometry = OrganizerBenchmarkRenderedGeometryDocument(
            snapshot: snapshot,
            allowedRawThreadIDs: Set(fixture.nodes.map(\.effectiveConversationKey)),
            allowedGroupKeys: Set(fixture.groups.filter(\.acceptsDrop).map(\.groupKey))
        )
        renderedGeometryWriteTask?.cancel()
        renderedGeometryWriteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled,
                  let self,
                  let document = self.pendingRenderedGeometry else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(document).write(to: self.renderedGeometryURL,
                                                    options: .atomic)
            } catch {
                self.state = .failed(
                    "Synthetic benchmark rendered-geometry evidence could not be persisted."
                )
            }
        }
    }

    /// Coalesces model and render updates onto one deferred readiness check.
    /// Deferral keeps `@Published state` mutations outside SwiftUI's current
    /// update pass while the flag prevents render churn from queuing redundant
    /// finalizers before the first one can run.
    private func scheduleReadinessFinalizationIfNeeded() {
        guard state == .launching,
              !isReadinessFinalizationScheduled,
              !isFinalizingReadiness else { return }
        isReadinessFinalizationScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.isReadinessFinalizationScheduled = false
            await self.completeReadinessIfPossible()
        }
    }

    private func completeReadinessIfPossible() async {
        guard state == .launching,
              modelReadinessSatisfied,
              !isFinalizingReadiness,
              let latestRenderedSnapshot,
              renderedSnapshotSatisfiesTask(latestRenderedSnapshot) else {
            return
        }
        isFinalizingReadiness = true
        let metricStratum: OrganizerMetricStratum = configuration.stratum == .warm
            ? .warm
            : .coldRelaunch
        guard await metricsRecorder.recordEvent(.workspaceReady,
                                                count: 1,
                                                status: .success),
              await metricsRecorder.recordEvent(.taskVisible,
                                                count: 1,
                                                status: .success) else {
            state = .failed("Synthetic benchmark instrumentation failed before task-ready.")
            isFinalizingReadiness = false
            return
        }
        let didStartTask: Bool
        if let timedKind = configuration.task.timedKindAtTaskReady {
            didStartTask = await metricsRecorder.beginTimedEvent(kind: timedKind,
                                                                 stratum: metricStratum,
                                                                 event: .taskReady)
        } else {
            didStartTask = await metricsRecorder.recordEvent(.taskReady,
                                                             stratum: metricStratum,
                                                             count: 1)
        }
        guard didStartTask else {
            state = .failed("Synthetic benchmark instrumentation failed before task-ready.")
            isFinalizingReadiness = false
            return
        }
        state = .ready
        isFinalizingReadiness = false
    }

    private func renderedSnapshotSatisfiesTask(
        _ snapshot: OrganizerRenderedGraphSnapshot
    ) -> Bool {
        configuration.runtimeMetricContract(fixture: fixture)
            .isAccessibilityReady(for: snapshot)
    }

    private static func appBuildIdentifier(bundle: Bundle = .main) -> String {
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let raw = "build-\(shortVersion)-\(build)"
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" })
    }

    internal var bannerText: String {
        switch state {
        case .seeding:
            return "Preparing \(configuration.fixtureID)"
        case .launching:
            return "Loading \(configuration.fixtureID) · Apple Mail locked"
        case .ready:
            return "Ready · \(configuration.fixtureID) · \(configuration.task.rawValue) · \(configuration.stratum.rawValue) · Apple Mail locked"
        case .failed:
            return "Synthetic benchmark unavailable · Apple Mail remained locked"
        }
    }
}

internal struct OrganizerBenchmarkRootView: View {
    @ObservedObject private var settings: AutoRefreshSettings
    @ObservedObject private var inspectorSettings: InspectorViewSettings
    @ObservedObject private var displaySettings: ThreadCanvasDisplaySettings
    @ObservedObject private var pinnedFolderSettings: PinnedFolderSettings
    @ObservedObject private var activityCenter: ProcessingActivityCenter
    @StateObject private var runtime: OrganizerBenchmarkRuntime

    internal init(configuration: OrganizerBenchmarkConfiguration,
                  settings: AutoRefreshSettings,
                  inspectorSettings: InspectorViewSettings,
                  displaySettings: ThreadCanvasDisplaySettings,
                  pinnedFolderSettings: PinnedFolderSettings,
                  activityCenter: ProcessingActivityCenter) {
        self.settings = settings
        self.inspectorSettings = inspectorSettings
        self.displaySettings = displaySettings
        self.pinnedFolderSettings = pinnedFolderSettings
        self.activityCenter = activityCenter
        _runtime = StateObject(wrappedValue: OrganizerBenchmarkRuntime(
            configuration: configuration,
            settings: settings,
            inspectorSettings: inspectorSettings,
            displaySettings: displaySettings,
            pinnedFolderSettings: pinnedFolderSettings,
            activityCenter: activityCenter
        ))
    }

    internal var body: some View {
        Group {
            switch runtime.state {
            case .seeding:
                ProgressView(runtime.bannerText)
                    .frame(minWidth: 720, minHeight: 520)
            case .launching, .ready:
                benchmarkContent
            case .failed(let message):
                OrganizerBenchmarkLaunchErrorView(message: message)
            }
        }
        .task {
            await runtime.seedIfNeeded()
        }
    }

    private var benchmarkContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: runtime.state == .ready ? "checkmark.shield.fill" : "hourglass")
                Text(runtime.bannerText)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("External Mail calls: 0")
                    .font(.caption.monospacedDigit())
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .foregroundStyle(.white)
            .background(Color.indigo.opacity(0.92))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.organizerBenchmarkBanner)

            ContentView(settings: settings,
                        inspectorSettings: inspectorSettings,
                        displaySettings: displaySettings,
                        pinnedFolderSettings: pinnedFolderSettings,
                        activityCenter: activityCenter,
                        viewModel: runtime.viewModel,
                        graphSettings: runtime.graphSettings,
                        graphViewModel: runtime.graphViewModel,
                        onRenderedOrganizerReceipt: { receipt in
                            runtime.evaluateRenderedReadiness(receipt)
                        })
        }
        .onReceive(runtime.viewModel.$roots.combineLatest(runtime.graphViewModel.$data)) { roots, data in
            Task {
                await runtime.evaluateReadiness(roots: roots, graphData: data)
            }
        }
    }
}

internal struct OrganizerBenchmarkLaunchErrorView: View {
    internal let message: String

    internal var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Organizer benchmark stopped safely")
                .font(.title2.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("The normal mailbox was not opened.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(minWidth: 720, minHeight: 520)
        .accessibilityIdentifier(AccessibilityID.organizerBenchmarkError)
    }
}
#endif
