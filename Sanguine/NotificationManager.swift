import Foundation
import UserNotifications

final class NotificationManager: Sendable {
    static let shared = NotificationManager()
    static let doseCategoryID      = "DOSE_REMINDER"
    static let markTakenActionID   = "ADMINISTERED"
    static let dosePlanIDPrefix    = "planned-dose-today"
    static let readingReminderID   = "reading-weekly-reminder"

    private init() {}

    func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    /// Register the "Applied" action category. Call once at launch.
    func registerNotificationCategories() {
        let markTaken = UNNotificationAction(
            identifier: Self.markTakenActionID,
            title: "Applied",
            options: []
        )
        let doseCategory = UNNotificationCategory(
            identifier: Self.doseCategoryID,
            actions: [markTaken],
            intentIdentifiers: [],
            options: []
        )
        let readingCategory = UNNotificationCategory(
            identifier: Self.readingReminderID,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([doseCategory, readingCategory])
    }

    // iOS caps pending notifications at 64; reserve 1 slot for the reading reminder.
    private static let maxDoseNotifications = 63

    /// Schedule time-sensitive notifications for today's planned dose, starting at the user's
    /// configured time and repeating every 15 minutes until midnight. Notifications break through
    /// Focus modes and notification summaries. Does nothing if the time has already passed today.
    func schedulePlannedDoseNotification(dose: Double, hour: Int, minute: Int, timezoneID: String) {
        let center = UNUserNotificationCenter.current()

        Task {
            // Cancel any existing dose notifications before scheduling new ones.
            let pending = await center.pendingNotificationRequests()
            let oldIDs  = pending.map(\.identifier).filter { $0.hasPrefix(Self.dosePlanIDPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: oldIDs)

            let tz = TimeZone(identifier: timezoneID) ?? .current
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz

            var components = cal.dateComponents([.year, .month, .day], from: .now)
            components.hour = hour; components.minute = minute; components.second = 0
            guard let startDate = cal.date(from: components) else { return }

            // If the configured time already passed, start from now + 1 min
            let firstFire = startDate > .now ? startDate : Date(timeIntervalSinceNow: 60)

            // Midnight in the user's timezone
            let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: .now)!)
            guard firstFire < tomorrow else { return }

            let content = UNMutableNotificationContent()
            content.title = "Dose Reminder"
            content.body  = "Time to apply your dose (\(dose.doseFormatted))"
            content.sound = .default
            content.categoryIdentifier  = Self.doseCategoryID
            content.interruptionLevel   = .timeSensitive

            var fireDate = firstFire
            var index = 0
            let interval: TimeInterval = 15 * 60

            while fireDate < tomorrow {
                guard index < Self.maxDoseNotifications else { break }
                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: fireDate.timeIntervalSinceNow,
                    repeats: false
                )
                let request = UNNotificationRequest(
                    identifier: "\(Self.dosePlanIDPrefix)-\(index)",
                    content: content,
                    trigger: trigger
                )
                center.add(request)
                fireDate  = fireDate.addingTimeInterval(interval)
                index    += 1
            }
        }
    }

    func cancelPlannedDoseNotification() {
        let center = UNUserNotificationCenter.current()
        Task {
            let pending = await center.pendingNotificationRequests()
            let ids = pending.map(\.identifier).filter { $0.hasPrefix(Self.dosePlanIDPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    // MARK: - Reading Reminder

    /// Schedules a weekly repeating reminder to take a reading.
    /// weekday: 1 = Sunday … 7 = Saturday (matches Calendar.Component.weekday)
    func scheduleReadingReminder(weekday: Int, hour: Int, minute: Int) {
        cancelReadingReminder()
        let content = UNMutableNotificationContent()
        content.title = "Time for your reading"
        content.body  = "Tap to record today's reading."
        content.sound = .default
        content.categoryIdentifier = Self.readingReminderID
        content.interruptionLevel  = .timeSensitive

        var components = DateComponents()
        components.weekday = weekday
        components.hour    = hour
        components.minute  = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: Self.readingReminderID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    func cancelReadingReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.readingReminderID])
    }

    func updateReadingReminder(enabled: Bool, weekday: Int, hour: Int, minute: Int) {
        if enabled { scheduleReadingReminder(weekday: weekday, hour: hour, minute: minute) }
        else { cancelReadingReminder() }
    }
}
