import SwiftData
import Foundation

/// The App Group identifier shared between the main app and the widget extension.
let appGroupID = "group.com.fhieber.Sanguine"

extension UserDefaults {
    /// Shared suite readable by both the main app and widget extension.
    static let appGroup = UserDefaults(suiteName: appGroupID) ?? .standard
}

/// Creates a ModelContainer whose store lives in the shared App Group container,
/// making the data accessible to both the main app and any widget extensions.
func makeSharedModelContainer() throws -> ModelContainer {
    let storeURL = sharedStoreURL()
    // Upgrade protection on any existing files before opening (handles migration
    // from versions that did not set an explicit protection class).
    applyFileProtection(to: storeURL)
    let config = ModelConfiguration(url: storeURL)
    let container = try ModelContainer(
        for: Reading.self, DoseEntry.self,
        configurations: config
    )
    // Apply again after creation so WAL/SHM sidecars created on open are covered.
    applyFileProtection(to: storeURL)
    return container
}

/// The URL of the SwiftData store inside the shared App Group container.
func sharedStoreURL() -> URL {
    let groupURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupID
    ) ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return groupURL.appendingPathComponent("Sanguine.store")
}

/// Sets NSFileProtectionCompleteUntilFirstUserAuthentication on the store file
/// and its SQLite WAL/SHM sidecar files. Idempotent; skips files that don't exist.
private func applyFileProtection(to storeURL: URL) {
    let attrs: [FileAttributeKey: Any] = [
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
    ]
    let dir = storeURL.deletingLastPathComponent()
    let name = storeURL.lastPathComponent
    for filename in [name, name + "-wal", name + "-shm"] {
        let url = dir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
    }
}
