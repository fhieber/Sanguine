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
    let config = ModelConfiguration(url: storeURL)
    return try ModelContainer(
        for: Reading.self, DoseEntry.self,
        configurations: config
    )
}

/// The URL of the SwiftData store inside the shared App Group container.
func sharedStoreURL() -> URL {
    let groupURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupID
    ) ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return groupURL.appendingPathComponent("Sanguine.store")
}
