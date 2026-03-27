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
            todayDoseTaken: false
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
        let lowTarget  = defaults.object(forKey: "readingLowTarget")  == nil ? 2.0 : defaults.double(forKey: "readingLowTarget")
        let highTarget = defaults.object(forKey: "readingHighTarget") == nil ? 3.0 : defaults.double(forKey: "readingHighTarget")
        let doseHour   = defaults.object(forKey: "doseTimeHour")   == nil ? 18  : defaults.integer(forKey: "doseTimeHour")
        let doseMinute = defaults.object(forKey: "doseTimeMinute") == nil ? 0   : defaults.integer(forKey: "doseTimeMinute")
        let tzID       = defaults.string(forKey: "doseTimezone") ?? "Europe/Berlin"

        var latestReading: Double?
        var readingDate: Date?
        var readingInRange: Bool?
        var todayDose: Double?
        var todayDoseTime: String?
        var todayDoseTaken = false

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
                if entry.isPlanned == true {
                    todayDoseTime = widgetDoseTimeLabel(hour: doseHour, minute: doseMinute, timezoneID: tzID)
                    todayDoseTaken = false
                } else {
                    todayDoseTaken = true
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
            todayDoseTaken: todayDoseTaken
        )
    }
}

// MARK: - Widget View

struct SanguineWidgetEntryView: View {
    var entry: SanguineEntry
    @Environment(\.widgetFamily) private var family

    private var isSmall: Bool { family == .systemSmall }

    var body: some View {
        VStack(alignment: .leading, spacing: isSmall ? 4 : 8) {
            // Row 1: Latest reading — taps to add new reading
            Link(destination: URL(string: "medtracker://add-reading")!) {
                HStack(spacing: 8) {
                    Image(systemName: entry.readingInRange == false ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(entry.readingInRange == false ? .red : .green)
                        .font(isSmall ? .body : .title2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Last Reading")
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
            Link(destination: URL(string: "medtracker://dose-detail")!) {
                HStack(spacing: 8) {
                    Image(systemName: entry.todayDoseTaken ? "checkmark.circle.fill" : (entry.todayDose != nil ? "calendar.badge.checkmark" : "exclamationmark.circle.fill"))
                        .foregroundStyle(entry.todayDoseTaken ? .green : (entry.todayDose != nil ? .primary : .red))
                        .font(isSmall ? .body : .title2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Today's Dose")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if entry.todayDoseTaken {
                            Text(doseString(entry.todayDose))
                                .font(isSmall ? .headline : .title2)
                                .bold()
                        } else if let dose = entry.todayDose {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(doseString(dose))
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

    private func doseString(_ dose: Double?) -> String {
        guard let d = dose else { return "—" }
        return d.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(d))" : "\(d)"
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
    SanguineEntry(date: .now, latestReading: 2.5, readingDate: .now, readingInRange: true, todayDose: 1.25, todayDoseTime: "6pm CET", todayDoseTaken: false)
    SanguineEntry(date: .now, latestReading: 3.8, readingDate: .now, readingInRange: false, todayDose: 1.0, todayDoseTime: nil, todayDoseTaken: true)
    SanguineEntry(date: .now, latestReading: 2.1, readingDate: .now, readingInRange: true, todayDose: nil, todayDoseTime: nil, todayDoseTaken: false)
}

// MARK: - Helpers

private func widgetDoseTimeLabel(hour: Int, minute: Int, timezoneID: String) -> String {
    let tz = TimeZone(identifier: timezoneID) ?? .current
    let abbr = tz.abbreviation(for: .now) ?? tz.identifier
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    var c = DateComponents(); c.hour = hour; c.minute = minute
    guard let date = cal.date(from: c) else { return "" }
    let fmt = DateFormatter()
    fmt.timeZone = tz
    fmt.dateFormat = minute == 0 ? "ha" : "h:mma"
    fmt.amSymbol = "am"; fmt.pmSymbol = "pm"
    return "\(fmt.string(from: date)) \(abbr)"
}
