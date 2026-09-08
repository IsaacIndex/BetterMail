import Foundation
@testable import BetterMail

internal final class InMemoryOrganizationMailOperationFileIO: OrganizationOperationFileIO, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL: Data] = [:]

    internal func read(at url: URL) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[url] else {
            throw OrganizationOperationFileIOError.notFound
        }
        return value
    }

    internal func writeAtomically(_ data: Data, to url: URL) throws {
        lock.lock()
        values[url] = data
        lock.unlock()
    }

    internal func persistedData() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return Array(values.values)
    }
}

internal func makeInMemoryOrganizationOperationStore(
    label: String = UUID().uuidString,
    fileIO: InMemoryOrganizationMailOperationFileIO = InMemoryOrganizationMailOperationFileIO()
) -> OrganizationOperationStore {
    OrganizationOperationStore(
        fileURL: URL(fileURLWithPath: "/tmp/organization-mail-tests-\(label).json"),
        fileIO: fileIO,
        routeCrypto: CryptoKitOrganizationRouteCryptoProvider(
            keyIdentifier: "organization-mail-tests-key",
            keyData: Data(repeating: 0x5A, count: 32),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
    )
}

