import Foundation

/// Pure extraction of organization sources from the current mailbox snapshot.
/// It preserves the coordinator's established identity, deduplication, and
/// representative-content rules while keeping orchestration out of projection.
internal nonisolated enum OrganizationSourceSnapshotBuilder {
    internal static func build(from snapshot: GraphAutomationSnapshot) -> [GraphAutomationSource] {
        snapshot.roots.compactMap { root in
            let rawThreadID = GraphData.rawThreadID(for: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawThreadID.isEmpty else { return nil }
            let nodes = flatten(root).sorted {
                if $0.message.date != $1.message.date { return $0.message.date < $1.message.date }
                return $0.id < $1.id
            }
            guard !nodes.isEmpty else { return nil }

            let accounts = Set(nodes.map {
                $0.message.physicalSource.accountName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })
            let accountName = accounts.count == 1 ? accounts.first ?? "" : ""
            let manualGroup = snapshot.manualGroups[rawThreadID]
            let automaticThreadIDs = Set(nodes.compactMap {
                snapshot.jwzThreadMap[$0.message.threadKey]
            })
            let isBranch = manualGroup != nil || nodes.count > 1
            let jwzThreadIDs: Set<String>
            let manualMessageKeys: Set<String>
            if let manualGroup {
                jwzThreadIDs = manualGroup.jwzThreadIDs
                manualMessageKeys = manualGroup.manualMessageKeys
            } else if isBranch {
                jwzThreadIDs = automaticThreadIDs.isEmpty ? [rawThreadID] : automaticThreadIDs
                manualMessageKeys = []
            } else {
                jwzThreadIDs = []
                manualMessageKeys = [nodes[0].message.threadKey]
            }

            var seenPhysicalSources = Set<String>()
            let messages = nodes.compactMap { node -> GraphAutomationMessageSource? in
                let physical = node.message.physicalSource
                let identity = GraphAutomationIdentity.make([
                    physical.accountName.lowercased(),
                    physical.mailboxID.lowercased(),
                    physical.internalMailID ?? "",
                    physical.messageID.lowercased()
                ])
                guard seenPhysicalSources.insert(identity).inserted else { return nil }
                return GraphAutomationMessageSource(messageID: physical.messageID,
                                                    messageKey: node.message.threadKey,
                                                    internalMailID: physical.internalMailID,
                                                    accountName: physical.accountName,
                                                    mailboxPath: physical.mailboxID,
                                                    date: physical.date)
            }

            let summary = nodes.reversed().compactMap { node -> String? in
                let value = (snapshot.summariesByNodeID[node.id]
                    ?? snapshot.summariesByNodeID[GraphData.messageNodeID(for: node.id)])?.text
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return value.isEmpty ? nil : value
            }.first ?? ""
            let content = representativeContent(nodes)
            let fingerprintComponents = [
                "graph-automation-source-v1",
                rawThreadID,
                manualGroup?.id ?? "",
                jwzThreadIDs.sorted().joined(separator: ","),
                manualMessageKeys.sorted().joined(separator: ",")
            ] + nodes.map { node in
                let message = node.message
                return [
                    message.physicalSource.accountName.lowercased(),
                    message.physicalSource.messageID.lowercased(),
                    String(message.physicalSource.date.timeIntervalSinceReferenceDate),
                    message.subject,
                    message.snippet,
                    message.inReplyTo ?? "",
                    message.references.joined(separator: ",")
                ].joined(separator: "|")
            }
            return GraphAutomationSource(rawThreadID: rawThreadID,
                                         effectiveThreadID: rawThreadID,
                                         manualGroupID: manualGroup?.id,
                                         subject: root.message.subject
                                             .trimmingCharacters(in: .whitespacesAndNewlines),
                                         summary: summary,
                                         representativeContent: content,
                                         accountName: accountName,
                                         jwzThreadIDs: jwzThreadIDs,
                                         manualMessageKeys: manualMessageKeys,
                                         messages: messages,
                                         fingerprint: GraphAutomationIdentity.make(fingerprintComponents))
        }
    }

    private static func flatten(_ node: ThreadNode) -> [ThreadNode] {
        [node] + node.children.flatMap(flatten)
    }

    private static func representativeContent(_ nodes: [ThreadNode]) -> String {
        let indices: [Int]
        if nodes.count <= 4 {
            indices = Array(nodes.indices)
        } else {
            indices = Array(Set([
                0,
                nodes.count / 3,
                (nodes.count * 2) / 3,
                nodes.count - 1
            ])).sorted()
        }
        return indices.enumerated().map { offset, index in
            let message = nodes[index].message
            return "\(offset + 1). Subject: \(String(message.subject.prefix(200))) | From: \(String(message.from.prefix(120))) | Content: \(String(message.snippet.prefix(600)))"
        }.joined(separator: "\n")
    }
}

internal nonisolated enum OrganizationPlacementPolicy {
    internal static func isReviewable(score: Double,
                                      thresholds: GraphAutomationThresholds) -> Bool {
        score >= thresholds.reviewFloor
    }

    internal static func isAmbiguous(winnerScore: Double,
                                     runnerUpScore: Double,
                                     thresholds: GraphAutomationThresholds) -> Bool {
        winnerScore - runnerUpScore < thresholds.winnerMargin
    }

    internal static func allowsAutomatic(score: Double,
                                         automaticThreshold: Double,
                                         isPaused: Bool,
                                         isAmbiguous: Bool,
                                         hasExistingFolderConflict: Bool,
                                         hasManualGroupMergeConflict: Bool) -> Bool {
        !isPaused
            && !isAmbiguous
            && !hasExistingFolderConflict
            && !hasManualGroupMergeConflict
            && score >= automaticThreshold
    }
}
