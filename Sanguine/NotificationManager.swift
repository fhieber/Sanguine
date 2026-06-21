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

    /// Schedule time-sensitive notifications for all planned doses across multiple days.
    /// Distributes the 63 available slots evenly across each planned day, providing up to
    /// 9 follow-up reminders per day (every 15 min) when 7 days are planned. Notifications
    /// break through Focus modes. Does not require the app to be opened on any given day.
    func schedulePlannedDoseNotifications(
        plannedDoses: [(date: Date, dose: Double)],
        hour: Int,
        minute: Int,
        timezoneID: String
    ) {
        let center = UNUserNotificationCenter.current()

        Task {
            // Cancel any existing dose notifications before scheduling new ones.
            let pending = await center.pendingNotificationRequests()
            let oldIDs  = pending.map(\.identifier).filter { $0.hasPrefix(Self.dosePlanIDPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: oldIDs)

            let tz = TimeZone(identifier: timezoneID) ?? .current
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz

            let todayStart = cal.startOfDay(for: .now)

            // Deduplicate to one entry per calendar day (use first entry per day).
            var seenDays = Set<Date>()
            var days: [(dayStart: Date, dose: Double)] = []
            for entry in plannedDoses.sorted(by: { $0.date < $1.date }) {
                let dayStart = cal.startOfDay(for: entry.date)
                guard dayStart >= todayStart, !seenDays.contains(dayStart) else { continue }
                seenDays.insert(dayStart)
                days.append((dayStart: dayStart, dose: entry.dose))
            }
            guard !days.isEmpty else { return }

            // Distribute slots evenly across all planned days (min 1 per day).
            let slotsPerDay = max(1, Self.maxDoseNotifications / days.count)
            let interval: TimeInterval = 15 * 60

            var index = 0
            for (dayStart, dose) in days {
                guard index < Self.maxDoseNotifications else { break }

                // Configured fire time for this day.
                var comps = cal.dateComponents([.year, .month, .day], from: dayStart)
                comps.hour = hour; comps.minute = minute; comps.second = 0
                guard let configuredStart = cal.date(from: comps) else { continue }

                // For today: if configured time already passed, start from now + 1 min.
                let isToday = cal.isDate(dayStart, inSameDayAs: .now)
                let firstFire = (isToday && configuredStart <= .now)
                    ? Date(timeIntervalSinceNow: 60)
                    : configuredStart

                // Midnight ending this day.
                let midnight = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: dayStart)!)
                guard firstFire < midnight else { continue }

                let content = UNMutableNotificationContent()
                content.title = "Dose Reminder"
                content.body  = "Time to apply your dose (\(dose.doseFormatted))"
                content.sound = .default
                content.categoryIdentifier = Self.doseCategoryID
                content.interruptionLevel  = .timeSensitive

                var fireDate = firstFire
                var daySlot = 0
                while fireDate < midnight && daySlot < slotsPerDay && index < Self.maxDoseNotifications {
                    let fireComponents = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                    let trigger = UNCalendarNotificationTrigger(dateMatching: fireComponents, repeats: false)
                    let request = UNNotificationRequest(
                        identifier: "\(Self.dosePlanIDPrefix)-\(index)",
                        content: content,
                        trigger: trigger
                    )
                    try? await center.add(request)
                    fireDate = fireDate.addingTimeInterval(interval)
                    daySlot += 1
                    index   += 1
                }
            }
        }
    }

    func cancelPlannedDoseNotification() {
        let center = UNUserNotificationCenter.current()
        Task {
            async let pendingReqs = center.pendingNotificationRequests()
            async let deliveredNotifs = center.deliveredNotifications()
            let (pending, delivered) = await (pendingReqs, deliveredNotifs)

            let pendingIDs = pending.map(\.identifier).filter { $0.hasPrefix(Self.dosePlanIDPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: pendingIDs)

            let deliveredIDs = delivered.map(\.request.identifier).filter { $0.hasPrefix(Self.dosePlanIDPrefix) }
            center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
        }
    }

    // MARK: - Reading Reminder

    /// Builds and adds the reading reminder request for the given trigger,
    /// always reusing the shared `readingReminderID` identifier.
    private func addReadingReminderRequest(trigger: UNNotificationTrigger) {
        let content = UNMutableNotificationContent()
        content.title = "Time for your reading"
        content.body  = "Tap to record today's reading."
        content.sound = .default
        content.categoryIdentifier = Self.readingReminderID
        content.interruptionLevel  = .timeSensitive

        let request = UNNotificationRequest(identifier: Self.readingReminderID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    /// Cancels and reschedules the weekly reading reminder, skipping the
    /// upcoming occurrence when a reading has already been recorded on that
    /// same calendar day. Normally a weekly repeating trigger is installed;
    /// when the imminent occurrence is skipped, a one-shot is scheduled for the
    /// following week instead (the next launch re-arms the repeating trigger).
    /// weekday: 1 = Sunday … 7 = Saturday (matches Calendar.Component.weekday)
    func refreshReadingReminder(enabled: Bool, weekday: Int, hour: Int, minute: Int, lastReadingDate: Date?) {
        cancelReadingReminder()
        guard enabled else { return }

        var components = DateComponents()
        components.weekday = weekday
        components.hour    = hour
        components.minute  = minute

        let cal = Calendar.current
        guard let nextFire = cal.nextDate(after: .now, matching: components, matchingPolicy: .nextTime) else { return }

        // Same-day check — the analog of the dose "already done today" filter.
        if let last = lastReadingDate, cal.isDate(last, inSameDayAs: nextFire),
           let following = cal.date(byAdding: .weekOfYear, value: 1, to: nextFire) {
            // Skip the imminent occurrence: one-shot for next week.
            let oneShot = cal.dateComponents([.year, .month, .day, .hour, .minute], from: following)
            addReadingReminderRequest(trigger: UNCalendarNotificationTrigger(dateMatching: oneShot, repeats: false))
        } else {
            // Normal: weekly repeating trigger.
            addReadingReminderRequest(trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true))
        }
    }

    /// Convenience overload that reads the reminder settings from the shared
    /// app group defaults, for callers without direct access to them.
    func refreshReadingReminder(lastReadingDate: Date?) {
        let d = UserDefaults.appGroup
        refreshReadingReminder(
            enabled: d.object(forKey: "readingReminderEnabled") as? Bool ?? true,
            weekday: d.object(forKey: "readingReminderWeekday") as? Int ?? 1,
            hour:    d.object(forKey: "readingReminderHour")    as? Int ?? 8,
            minute:  d.object(forKey: "readingReminderMinute")  as? Int ?? 0,
            lastReadingDate: lastReadingDate
        )
    }

    func cancelReadingReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.readingReminderID])
    }

    /// Removes a delivered reading reminder from the notification center without
    /// cancelling the pending weekly schedule.
    func removeDeliveredReadingReminder() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Self.readingReminderID])
    }

}
