import Foundation
import SwiftData

extension Double {
    /// Locale-independent dose string: whole numbers as "2", fractions as "1.25"
    var doseFormatted: String {
        truncatingRemainder(dividingBy: 1) == 0 ? String(Int(self)) : String(self)
    }
}

// MARK: - Reading

@Model
final class Reading {
    var value: Double
    var recordedAt: Date
    var note: String
    /// Dose on the day of reading (if recorded)
    var dose: Double?
    /// Set during CSV import; used for deduplication on re-import
    var externalID: String?

    init(value: Double, recordedAt: Date = .now, note: String = "", dose: Double? = nil, externalID: String? = nil) {
        self.value = value
        self.recordedAt = recordedAt
        self.note = note
        self.dose = dose
        self.externalID = externalID
    }
}

// MARK: - Daily Dose Entry

@Model
final class DoseEntry {
    var date: Date
    var dose: Double
    var note: String
    /// true = planned future dose; nil/false = historical/taken (default for imported data)
    var isPlanned: Bool?
    /// Set during CSV import; used for deduplication on re-import
    var externalID: String?

    init(date: Date, dose: Double, note: String = "", isPlanned: Bool? = nil, externalID: String? = nil) {
        self.date = date
        self.dose = dose
        self.note = note
        self.isPlanned = isPlanned
        self.externalID = externalID
    }
}

// MARK: - Shared Notification Names

extension Notification.Name {
    static let navigateToDoseDetail  = Notification.Name("navigateToDoseDetail")
    static let navigateToAddReading  = Notification.Name("navigateToAddReading")
}

// MARK: - Dose Time Formatting

/// Formats a stored hour/minute/timezone into a human-readable label, e.g. "6pm CET".
func doseTimeLabel(hour: Int, minute: Int, timezoneID: String) -> String {
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

// MARK: - Dose Planning

struct PlannedDay: Identifiable {
    let id = UUID()
    var date: Date
    var doseText: String
}

/// Returns the existing DoseEntry for a given calendar day, if any.
func existingDose(for date: Date, in doses: [DoseEntry]) -> DoseEntry? {
    doses.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
}

/// Formats an existing dose as a text string, or "" if none exists.
func plannedDoseText(for date: Date, in doses: [DoseEntry]) -> String {
    guard let entry = existingDose(for: date, in: doses) else { return "" }
    let d = entry.dose
    return d.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(d)) : String(d)
}

/// Builds the initial PlannedDay array from startDay, pre-populating any existing doses.
func buildPlannedDays(startingAt startDay: Date, in doses: [DoseEntry]) -> [PlannedDay] {
    let futureDates = doses
        .map { Calendar.current.startOfDay(for: $0.date) }
        .filter { $0 >= startDay }
        .sorted()
    var uniqueDates = Array(NSOrderedSet(array: futureDates)) as! [Date]
    // Always include startDay as the first entry so today is always editable
    if uniqueDates.first != startDay {
        uniqueDates.insert(startDay, at: 0)
    }
    return uniqueDates.map { PlannedDay(date: $0, doseText: plannedDoseText(for: $0, in: doses)) }
}

/// Appends the next calendar day to days if index is the last entry; returns the index to focus.
@discardableResult
func appendNextDayIfNeeded(after index: Int, days: inout [PlannedDay], doses: [DoseEntry]) -> Int {
    guard index >= days.count - 1 else { return index + 1 }
    let cal = Calendar.current
    guard let nextDate = cal.date(byAdding: .day, value: 1, to: days[index].date) else { return index }
    days.append(PlannedDay(date: nextDate, doseText: plannedDoseText(for: nextDate, in: doses)))
    return index + 1
}

/// Upserts planned dose entries: updates existing same-day entries, inserts new ones.
func upsertPlannedDays(_ days: [PlannedDay], doses: [DoseEntry], into context: ModelContext) {
    for day in days {
        guard let dose = Double(day.doseText.replacingOccurrences(of: ",", with: ".")) else { continue }
        if let existing = existingDose(for: day.date, in: doses) {
            existing.dose = dose
            if existing.isPlanned == nil { existing.isPlanned = true }
        } else {
            context.insert(DoseEntry(date: day.date, dose: dose, isPlanned: true))
        }
    }
}

// MARK: - Demo Data

/// Generates synthetic demo readings and dose entries, inserts them into `context`,
/// and returns the inserted readings (so callers can derive statistics like target range).
@discardableResult
func generateDemoData(into context: ModelContext) -> [Reading] {
    func gaussian(mean: Double, sigma: Double) -> Double {
        let u1 = Double.random(in: .leastNormalMagnitude...1)
        let u2 = Double.random(in: 0...1)
        return mean + sigma * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }

    let cal = Calendar.current
    let now = Date()
    let mean = 8.0
    let sigma = 0.7
    let meanDose = 3.5
    var generatedReadings: [Reading] = []
    var prevDose = meanDose

    for week in stride(from: -38, through: 0, by: 1) {
        guard let baseDate = cal.date(byAdding: .weekOfYear, value: week, to: now) else { continue }
        let jitter = TimeInterval.random(in: -86400...86400)
        let date = baseDate.addingTimeInterval(jitter)
        guard date <= now else { continue }

        let doseEffect = -0.7 * (prevDose - meanDose)
        let value = max(4, min(12, gaussian(mean: mean + doseEffect, sigma: sigma)))
        let roundedValue = (value * 10).rounded() / 10

        let readingDeviation = roundedValue - mean
        let nextDose = max(1, min(6, gaussian(mean: meanDose + 0.4 * readingDeviation, sigma: 0.3)))
        let roundedDose = (nextDose * 4).rounded() / 4

        let r = Reading(value: roundedValue, recordedAt: date)
        r.dose = roundedDose
        generatedReadings.append(r)
        context.insert(r)
        prevDose = roundedDose

        if let midDate = cal.date(byAdding: .day, value: 3, to: date), midDate <= now {
            let midDose = max(1, min(6, gaussian(mean: roundedDose, sigma: 0.2)))
            let entry = DoseEntry(date: midDate, dose: (midDose * 4).rounded() / 4)
            entry.isPlanned = false
            context.insert(entry)
        }
    }

    return generatedReadings
}

// MARK: - Statistics Helpers

struct ReadingStats {
    let readings: [Reading]
    let lowTarget: Double
    let highTarget: Double

    var count: Int { readings.count }
    var latest: Reading? { readings.max(by: { $0.recordedAt < $1.recordedAt }) }
    var average: Double? {
        guard !readings.isEmpty else { return nil }
        return readings.map(\.value).reduce(0, +) / Double(readings.count)
    }
    var minimum: Double? { readings.map(\.value).min() }
    var maximum: Double? { readings.map(\.value).max() }
    var stdDev: Double? {
        guard let avg = average, readings.count > 1 else { return nil }
        let variance = readings.map { pow($0.value - avg, 2) }.reduce(0, +) / Double(readings.count)
        return sqrt(variance)
    }
    var timeInRangePercent: Double? {
        guard !readings.isEmpty else { return nil }
        let inRange = readings.filter { $0.value >= lowTarget && $0.value <= highTarget }.count
        return Double(inRange) / Double(readings.count) * 100
    }

    func isInRange(_ r: Reading) -> Bool {
        r.value >= lowTarget && r.value <= highTarget
    }
}

struct DoseStats {
    let entries: [DoseEntry]

    var count: Int { entries.count }
    var latest: DoseEntry? { entries.max(by: { $0.date < $1.date }) }
    var average: Double? {
        guard !entries.isEmpty else { return nil }
        return entries.map(\.dose).reduce(0, +) / Double(entries.count)
    }
    var minimum: Double? { entries.map(\.dose).min() }
    var maximum: Double? { entries.map(\.dose).max() }

    /// Average total dose per complete calendar week. Boundary weeks that don't
    /// span a full Mon–Sun are discarded so partial weeks don't skew the average.
    var averageWeeklyTotal: Double? {
        let weeks = completeWeeklyGroups
        guard !weeks.isEmpty else { return nil }
        let totals = weeks.values.map { $0.map(\.dose).reduce(0, +) }
        return totals.reduce(0, +) / Double(totals.count)
    }

    var completeWeekCount: Int { completeWeeklyGroups.count }

    private var completeWeeklyGroups: [Date: [DoseEntry]] {
        guard let minDate = entries.map(\.date).min(),
              let maxDate = entries.map(\.date).max() else { return [:] }
        let cal = Calendar.current
        let byWeek = Dictionary(grouping: entries) { entry -> Date in
            cal.dateInterval(of: .weekOfYear, for: entry.date)?.start ?? entry.date
        }
        let firstWeekStart = cal.dateInterval(of: .weekOfYear, for: minDate)?.start
        let lastWeekStart  = cal.dateInterval(of: .weekOfYear, for: maxDate)?.start
        return byWeek.filter { weekStart, _ in
            if weekStart == firstWeekStart,
               let interval = cal.dateInterval(of: .weekOfYear, for: minDate),
               !cal.isDate(minDate, inSameDayAs: interval.start) { return false }
            if weekStart == lastWeekStart,
               let interval = cal.dateInterval(of: .weekOfYear, for: maxDate),
               let lastDay = cal.date(byAdding: .day, value: -1, to: interval.end),
               !cal.isDate(maxDate, inSameDayAs: lastDay) { return false }
            return true
        }
    }
}
