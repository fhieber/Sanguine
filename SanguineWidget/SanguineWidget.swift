import WidgetKit
import SwiftUI
import SwiftData

// MARK: - Widget Entry

struct SanguineEntry: TimelineEntry {
    let date: Date
    let latestReading: Double?
    let readingDate: Date?
    let readingInRange: Bool?
    let todayDose: Double?
    let todayDoseTime: String?   // formatted time string for planned dose
    let todayDoseTaken: Bool     // true if dose already applied today
    let doseTimeLocal: String    // reminder time formatted in user's local timezone
    let todayDoseActualTime: String?  // actual time dose was taken (nil if not yet taken)
    let isReadingReminderToday: Bool  // true when today is the scheduled reading reminder weekday
}

// MARK: - Timeline Provider

struct SanguineProvider: TimelineProvider {
    func placeholder(in context: Context) -> SanguineEntry {
        SanguineEntry(
            date: .now,
            latestReading: 2.5,
            readingDate: .now,
            readingInRange: true,
            todayDose: 1.25,
            todayDoseTime: "6pm CET",
            todayDoseTaken: false,
            doseTimeLocal: "6:00 PM",
            todayDoseActualTime: nil,
            isReadingReminderToday: false
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SanguineEntry) -> Void) {
        completion(buildEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SanguineEntry>) -> Void) {
        let entry = buildEntry()
        // Refresh every 15 minutes as a fallback; the app also triggers an immediate reload on data changes
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func buildEntry() -> SanguineEntry {
        let defaults = UserDefaults.appGroup
        let lowTarget  = (defaults.object(forKey: "readingLowTarget")  as? Double)  ?? 2.0
        let highTarget = (defaults.object(forKey: "readingHighTarget") as? Double)  ?? 3.0
        let doseHour   = (defaults.object(forKey: "doseTimeHour")      as? Int)     ?? 18
        let doseMinute = (defaults.object(forKey: "doseTimeMinute")    as? Int)     ?? 0
        let tzID       = defaults.string(forKey: "doseTimezone") ?? "Europe/Berlin"

        let readingReminderEnabled = (defaults.object(forKey: "readingReminderEnabled") as? Bool) ?? true
        let readingReminderWeekday = (defaults.object(forKey: "readingReminderWeekday") as? Int) ?? 1
        let isReadingReminderToday = readingReminderEnabled &&
            Calendar.current.component(.weekday, from: .now) == readingReminderWeekday

        // Compute dose reminder time converted to the user's local timezone
        let sourceTZ = TimeZone(identifier: tzID) ?? TimeZone(identifier: "Europe/Berlin")!
        var tzCal = Calendar(identifier: .gregorian)
        tzCal.timeZone = sourceTZ
        var doseComps = tzCal.dateComponents([.year, .month, .day], from: Date())
        doseComps.hour = doseHour
        doseComps.minute = doseMinute
        doseComps.second = 0
        let doseTimeLocal: String
        if let doseDate = tzCal.date(from: doseComps) {
            let fmt = DateFormatter()
            fmt.timeStyle = .short
            fmt.dateStyle = .none
            // fmt.timeZone defaults to system timezone — converts to user's local TZ
            doseTimeLocal = fmt.string(from: doseDate)
        } else {
            doseTimeLocal = ""
        }

        var latestReading: Double?
        var readingDate: Date?
        var readingInRange: Bool?
        var todayDose: Double?
        var todayDoseTime: String?
        var todayDoseTaken = false
        var todayDoseActualTime: String? = nil

        if let container = try? makeSharedModelContainer() {
            let ctx = ModelContext(container)

            // Latest reading
            var readingDesc = FetchDescriptor<Reading>(sortBy: [SortDescriptor(\.recordedAt, order: .reverse)])
            readingDesc.fetchLimit = 1
            if let r = try? ctx.fetch(readingDesc).first {
                latestReading  = r.value
                readingDate    = r.recordedAt
                readingInRange = r.value >= lowTarget && r.value <= highTarget
            }

            // Today's dose entry
            let allDoses = (try? ctx.fetch(FetchDescriptor<DoseEntry>())) ?? []
            if let entry = allDoses.first(where: { Calendar.current.isDateInToday($0.date) }) {
                todayDose = entry.dose
                if entry.isPlanned != false {
                    todayDoseTime = doseTimeLabel(hour: doseHour, minute: doseMinute, timezoneID: tzID)
                    todayDoseTaken = false
                } else {
                    todayDoseTaken = true
                    let fmt = DateFormatter()
                    fmt.timeStyle = .short
                    fmt.dateStyle = .none
                    todayDoseActualTime = fmt.string(from: entry.date)
                }
            }
        }

        return SanguineEntry(
            date: .now,
            latestReading: latestReading,
            readingDate: readingDate,
            readingInRange: readingInRange,
            todayDose: todayDose,
            todayDoseTime: todayDoseTime,
            todayDoseTaken: todayDoseTaken,
            doseTimeLocal: doseTimeLocal,
            todayDoseActualTime: todayDoseActualTime,
            isReadingReminderToday: isReadingReminderToday
        )
    }
}

// MARK: - Widget View

struct SanguineWidgetEntryView: View {
    var entry: SanguineEntry
    @Environment(\.widgetFamily) private var family

    private var isSmall: Bool { family == .systemSmall }

    private var daysSinceReading: Int? {
        guard let d = entry.readingDate else { return nil }
        return Calendar.current.dateComponents([.day], from: d, to: .now).day
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isSmall ? 4 : 8) {
            // Row 1: Latest reading — taps to add new reading
            Link(destination: URL(string: "sanguine://add-reading")!) {
                HStack(spacing: 8) {
                    let staleReading = (daysSinceReading ?? 0) > 7
                    let readingTakenToday = entry.readingDate.map { Calendar.current.isDateInToday($0) } ?? false
                    let showReadingCalendar = entry.isReadingReminderToday && !readingTakenToday
                    Image(systemName: showReadingCalendar ? "calendar.circle.fill" :
                          (staleReading ? "exclamationmark.circle.fill" : "checkmark.circle.fill"))
                        .foregroundStyle(showReadingCalendar ? Color.primary :
                          (staleReading || entry.readingInRange == false ? .red : .green))
                        .font(isSmall ? .body : .title2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(daysSinceReading.map { "Reading (\($0)d ago)" } ?? "Reading")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(entry.latestReading.map { String(format: "%.1f", $0) } ?? "—")
                                .font(isSmall ? .headline : .title2)
                                .bold()
                            if !isSmall, let d = entry.readingDate {
                                Text(d.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(isSmall ? 4 : 10)
                .background(isSmall ? AnyShapeStyle(.clear) : AnyShapeStyle(.thinMaterial), in: RoundedRectangle(cornerRadius: 10))
            }

            if isSmall { Divider() }

            // Row 2: Today's dose — taps to open dose detail
            Link(destination: URL(string: "sanguine://dose-detail")!) {
                HStack(spacing: 8) {
                    Image(systemName: entry.todayDoseTaken ? "checkmark.circle.fill" : (entry.todayDose != nil ? "calendar.badge.checkmark" : "exclamationmark.circle.fill"))
                        .foregroundStyle(entry.todayDoseTaken ? .green : (entry.todayDose != nil ? .primary : .red))
                        .font(isSmall ? .body : .title2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.todayDoseTaken && entry.todayDoseActualTime != nil
                             ? "Today \(entry.todayDoseActualTime!)"
                             : "Today \(entry.doseTimeLocal)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if entry.todayDoseTaken {
                            Text(entry.todayDose?.doseFormatted ?? "—")
                                .font(isSmall ? .headline : .title2)
                                .bold()
                        } else if let dose = entry.todayDose {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(dose.doseFormatted)
                                    .font(isSmall ? .headline : .title2)
                                    .bold()
                                if !isSmall, let t = entry.todayDoseTime {
                                    Text("@ \(t)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Text("—")
                                .font(isSmall ? .headline : .title2)
                                .bold()
                        }
                    }
                    Spacer()
                }
                .padding(isSmall ? 4 : 10)
                .background(isSmall ? AnyShapeStyle(.clear) : AnyShapeStyle(.thinMaterial), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(isSmall ? 4 : 12)
    }

}

// MARK: - Widget Definition

struct SanguineWidget: Widget {
    let kind: String = "SanguineWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SanguineProvider()) { entry in
            SanguineWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Sanguine")
        .description("Latest reading and today's dose.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Preview

#Preview(as: .systemMedium) {
    SanguineWidget()
} timeline: {
    SanguineEntry(date: .now, latestReading: 2.5, readingDate: .now, readingInRange: true, todayDose: 1.25, todayDoseTime: "6pm CET", todayDoseTaken: false, doseTimeLocal: "6:00 PM", todayDoseActualTime: nil, isReadingReminderToday: false)
    SanguineEntry(date: .now, latestReading: 3.8, readingDate: .now, readingInRange: false, todayDose: 1.0, todayDoseTime: nil, todayDoseTaken: true, doseTimeLocal: "6:00 PM", todayDoseActualTime: "4:32 PM", isReadingReminderToday: true)
    SanguineEntry(date: .now, latestReading: 2.1, readingDate: .now, readingInRange: true, todayDose: nil, todayDoseTime: nil, todayDoseTaken: false, doseTimeLocal: "6:00 PM", todayDoseActualTime: nil, isReadingReminderToday: false)
}
