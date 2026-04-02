import UIKit
import UserNotifications
import SwiftData
import WidgetKit

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Shared container created at launch so it's available for background notification actions.
    private(set) var modelContainer: ModelContainer?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.shared.registerNotificationCategories()
        modelContainer = try? makeSharedModelContainer()
        UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
        return true
    }

    // Show notification banner even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    // Handle notification tap and background actions
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
        if response.actionIdentifier == NotificationManager.markTakenActionID {
            markTodaysDoseAsTaken()
        } else if response.notification.request.content.categoryIdentifier == NotificationManager.readingReminderID {
            // Reading reminder tap — navigate to Add Reading screen
            UserDefaults.standard.set(true, forKey: "navigateToAddReading")
            NotificationCenter.default.post(name: .navigateToAddReading, object: nil)
        } else {
            // Regular dose tap — navigate to today's dose detail
            UserDefaults.standard.set(true, forKey: "navigateToDoseDetail")
            NotificationCenter.default.post(name: .navigateToDoseDetail, object: nil)
        }
        completionHandler()
    }

    private func markTodaysDoseAsTaken() {
        guard let container = modelContainer else { return }
        let context = ModelContext(container)
        let all = (try? context.fetch(FetchDescriptor<DoseEntry>())) ?? []
        if let entry = all.first(where: { $0.isPlanned != false && Calendar.current.isDateInToday($0.date) }) {
            entry.isPlanned = false
            entry.date = .now
            try? context.save()
        }
        NotificationManager.shared.cancelPlannedDoseNotification()

        // Immediately re-schedule for remaining future planned doses so tomorrow's
        // notifications are in place without requiring the app to be opened.
        let tomorrow = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: .now)!)
        let futurePlanned = all.filter { $0.isPlanned == true && $0.date >= tomorrow }
        if !futurePlanned.isEmpty {
            let defaults = UserDefaults.appGroup
            let hour   = (defaults.object(forKey: "doseTimeHour")   as? Int) ?? 18
            let minute = (defaults.object(forKey: "doseTimeMinute") as? Int) ?? 0
            let tzID   = defaults.string(forKey: "doseTimezone") ?? "Europe/Berlin"
            NotificationManager.shared.schedulePlannedDoseNotifications(
                plannedDoses: futurePlanned.map { ($0.date, $0.dose) },
                hour: hour, minute: minute, timezoneID: tzID
            )
        }

        WidgetCenter.shared.reloadAllTimelines()
    }
}
