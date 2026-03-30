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
                    let store   = UserDefaults.appGroup
                    let enabled = store.object(forKey: "readingReminderEnabled") as? Bool ?? true
                    let weekday = store.object(forKey: "readingReminderWeekday") as? Int ?? 1
                    let hour    = store.object(forKey: "readingReminderHour")    as? Int ?? 8
                    let minute  = store.object(forKey: "readingReminderMinute")  as? Int ?? 0
                    NotificationManager.shared.updateReadingReminder(enabled: enabled, weekday: weekday, hour: hour, minute: minute)
                }
        }
        .modelContainer(appDelegate.modelContainer ?? (try! makeSharedModelContainer()))
    }
}
