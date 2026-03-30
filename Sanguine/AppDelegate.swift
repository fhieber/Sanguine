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
        completionHandler([.banner, .sound])
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
        WidgetCenter.shared.reloadAllTimelines()
    }
}
