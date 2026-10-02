import Combine
import Foundation

internal final class MailAccountSelectionSettings: ObservableObject {
    internal static let selectedAccountNameKey = "mailAccountSelection.selectedAccountName"

    @Published internal private(set) var selectedAccountName: String?

    private let userDefaults: UserDefaults

    internal init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        selectedAccountName = Self.normalizedAccountName(
            userDefaults.string(forKey: Self.selectedAccountNameKey)
        )
    }

    internal func selectAccount(named accountName: String?) {
        let normalized = Self.normalizedAccountName(accountName)
        guard normalized != selectedAccountName else { return }
        selectedAccountName = normalized
        if let normalized {
            userDefaults.set(normalized, forKey: Self.selectedAccountNameKey)
        } else {
            userDefaults.removeObject(forKey: Self.selectedAccountNameKey)
        }
    }

    internal func matchesSelectedAccount(_ accountName: String) -> Bool {
        guard let selectedAccountName else { return true }
        return accountName.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(selectedAccountName) == .orderedSame
    }

    internal static func normalizedAccountName(_ accountName: String?) -> String? {
        let trimmed = accountName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
