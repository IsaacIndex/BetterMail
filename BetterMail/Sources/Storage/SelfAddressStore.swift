import Combine
import Foundation

@MainActor
final class SelfAddressStore: ObservableObject {
    static let shared = SelfAddressStore()

    @Published private(set) var addresses: [String]

    private let defaults: UserDefaults
    private let key = "SelfAddressStore.addresses"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.array(forKey: key) as? [String] {
            addresses = stored
        } else {
            addresses = []
        }
    }

    var addressSet: Set<String> {
        Set(addresses.map { $0.lowercased() })
    }

    func addAddress(_ value: String) {
        guard let normalized = Self.normalize(value), addresses.contains(normalized) == false else { return }
        addresses.append(normalized)
        persist()
    }

    func removeAddress(_ value: String) {
        let normalized = value.lowercased()
        addresses.removeAll { $0.lowercased() == normalized }
        persist()
    }

    func updateAddresses(_ values: [String]) {
        let unique = Array(Set(values.compactMap(Self.normalize))).sorted()
        addresses = unique
        persist()
    }

    private func persist() {
        defaults.set(addresses, forKey: key)
    }

    private static func normalize(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@"), trimmed.contains(".") else { return nil }
        return trimmed
    }
}
