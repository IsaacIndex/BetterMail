import Foundation

internal struct ThreadFolderColor: Hashable {
    internal let red: Double
    internal let green: Double
    internal let blue: Double
    internal let alpha: Double

    private static let calibratedPalette: [ThreadFolderColor] = [
        ThreadFolderColor(red: 0.620, green: 0.455, blue: 0.500, alpha: 1.0),
        ThreadFolderColor(red: 0.663, green: 0.502, blue: 0.431, alpha: 1.0),
        ThreadFolderColor(red: 0.604, green: 0.561, blue: 0.384, alpha: 1.0),
        ThreadFolderColor(red: 0.431, green: 0.584, blue: 0.502, alpha: 1.0),
        ThreadFolderColor(red: 0.424, green: 0.525, blue: 0.671, alpha: 1.0),
        ThreadFolderColor(red: 0.541, green: 0.467, blue: 0.639, alpha: 1.0),
        ThreadFolderColor(red: 0.376, green: 0.529, blue: 0.569, alpha: 1.0),
        ThreadFolderColor(red: 0.565, green: 0.420, blue: 0.431, alpha: 1.0),
        ThreadFolderColor(red: 0.420, green: 0.380, blue: 0.522, alpha: 1.0),
        ThreadFolderColor(red: 0.647, green: 0.439, blue: 0.369, alpha: 1.0),
        ThreadFolderColor(red: 0.486, green: 0.533, blue: 0.357, alpha: 1.0),
        ThreadFolderColor(red: 0.361, green: 0.486, blue: 0.549, alpha: 1.0)
    ]
    private static let defaultPaletteIndex = 1

    internal static var defaultNewFolder: ThreadFolderColor {
        calibratedPalette[defaultPaletteIndex]
    }

    internal static func random() -> ThreadFolderColor {
        calibratedPalette.randomElement() ?? defaultNewFolder
    }

    internal static func recalibrated(for folder: ThreadFolder, among folders: [ThreadFolder]) -> ThreadFolderColor {
        let siblingIndices = folders
            .filter { $0.id != folder.id && $0.parentID == folder.parentID }
            .map { nearestPaletteIndex(for: $0.color) }
        let referenceIndices = siblingIndices.isEmpty
            ? folders.filter { $0.id != folder.id }.map { nearestPaletteIndex(for: $0.color) }
            : siblingIndices

        guard !referenceIndices.isEmpty else {
            return defaultNewFolder
        }

        let usageByIndex = referenceIndices.reduce(into: [Int: Int]()) { result, index in
            result[index, default: 0] += 1
        }
        let currentIndex = nearestPaletteIndex(for: folder.color)
        let targetIndex = Int((Double(referenceIndices.reduce(0, +)) / Double(referenceIndices.count)).rounded())

        let sortedCandidates = calibratedPalette.indices.sorted { lhs, rhs in
            if lhs == currentIndex { return false }
            if rhs == currentIndex { return true }

            let lhsUsage = usageByIndex[lhs, default: 0]
            let rhsUsage = usageByIndex[rhs, default: 0]
            if lhsUsage != rhsUsage {
                return lhsUsage < rhsUsage
            }

            let lhsTargetDistance = abs(lhs - targetIndex)
            let rhsTargetDistance = abs(rhs - targetIndex)
            if lhsTargetDistance != rhsTargetDistance {
                return lhsTargetDistance < rhsTargetDistance
            }

            let lhsDefaultDistance = abs(lhs - defaultPaletteIndex)
            let rhsDefaultDistance = abs(rhs - defaultPaletteIndex)
            if lhsDefaultDistance != rhsDefaultDistance {
                return lhsDefaultDistance < rhsDefaultDistance
            }

            return lhs < rhs
        }

        guard let bestIndex = sortedCandidates.first else {
            return defaultNewFolder
        }
        return calibratedPalette[bestIndex]
    }

    private static func nearestPaletteIndex(for color: ThreadFolderColor) -> Int {
        calibratedPalette.indices.min { lhs, rhs in
            squaredDistance(from: calibratedPalette[lhs], to: color) < squaredDistance(from: calibratedPalette[rhs], to: color)
        } ?? defaultPaletteIndex
    }

    private static func squaredDistance(from lhs: ThreadFolderColor, to rhs: ThreadFolderColor) -> Double {
        let redDelta = lhs.red - rhs.red
        let greenDelta = lhs.green - rhs.green
        let blueDelta = lhs.blue - rhs.blue
        return (redDelta * redDelta) + (greenDelta * greenDelta) + (blueDelta * blueDelta)
    }
}

internal struct ThreadFolder: Identifiable, Hashable {
    internal let id: String
    internal var title: String
    internal var color: ThreadFolderColor
    internal var threadIDs: Set<String>
    internal var parentID: String?
    internal var mailboxAccount: String? = nil
    internal var mailboxPath: String? = nil

    internal var mailboxDestination: (account: String, path: String)? {
        let trimmedAccount = mailboxAccount?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedPath = mailboxPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedAccount.isEmpty, !trimmedPath.isEmpty else { return nil }
        return (trimmedAccount, trimmedPath)
    }
}
