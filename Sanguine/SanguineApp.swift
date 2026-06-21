import SwiftUI
import SwiftData

@main
struct SanguineApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    _ = await NotificationManager.shared.requestPermission()
                    NotificationManager.shared.refreshReadingReminder(lastReadingDate: latestReadingDate())
                }
        }
        .modelContainer(appDelegate.modelContainer ?? (try! makeSharedModelContainer()))
    }

    /// Most recent reading's timestamp, used to decide whether to skip the
    /// upcoming reading reminder.
    private func latestReadingDate() -> Date? {
        guard let container = appDelegate.modelContainer else { return nil }
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Reading>(sortBy: [SortDescriptor(\.recordedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.recordedAt
    }
}
