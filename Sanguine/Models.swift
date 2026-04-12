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

// MARK: - Polynomial Trendline

/// Solves A·x = b via Gaussian elimination with partial pivoting.
/// Returns nil if any pivot is below 1e-12 (singular or near-singular system).
private func gaussianElimination(_ A: [[Double]], _ b: [Double]) -> [Double]? {
    let n = b.count
    var M = A.enumerated().map { (i, row) -> [Double] in var r = row; r.append(b[i]); return r }

    for col in 0 ..< n {
        var maxRow = col
        var maxVal = abs(M[col][col])
        for row in (col + 1) ..< n {
            let v = abs(M[row][col])
            if v > maxVal { maxVal = v; maxRow = row }
        }
        guard maxVal > 1e-12 else { return nil }
        if maxRow != col { M.swapAt(col, maxRow) }
        let pivot = M[col][col]
        for row in (col + 1) ..< n {
            let factor = M[row][col] / pivot
            for k in col ... n { M[row][k] -= factor * M[col][k] }
        }
    }

    var x = [Double](repeating: 0, count: n)
    for i in stride(from: n - 1, through: 0, by: -1) {
        var sum = M[i][n]
        for j in (i + 1) ..< n { sum -= M[i][j] * x[j] }
        guard abs(M[i][i]) > 1e-12 else { return nil }
        x[i] = sum / M[i][i]
    }
    return x
}

/// Represents a polynomial fit to (normalizedX, y) pairs.
/// Coefficients are in ascending power order: `coefficients[i]` is the coefficient of `x^i`.
struct PolynomialFit {
    let degree: Int
    let coefficients: [Double]

    /// Fits a polynomial of `degree` to `normalizedX` ∈ [0,1] and `y` values.
    /// Returns nil when there are fewer than (degree + 1) points or the system is singular.
    static func fit(normalizedX xs: [Double], y ys: [Double], degree: Int) -> PolynomialFit? {
        let n = xs.count
        guard n >= degree + 1, n == ys.count else { return nil }
        let k = degree + 1

        var XtX = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
        var Xty = [Double](repeating: 0, count: k)

        for i in 0 ..< n {
            var pw = [Double](repeating: 1, count: k)
            for j in 1 ..< k { pw[j] = pw[j - 1] * xs[i] }
            for row in 0 ..< k {
                Xty[row] += pw[row] * ys[i]
                for col in 0 ..< k { XtX[row][col] += pw[row] * pw[col] }
            }
        }

        guard let coeffs = gaussianElimination(XtX, Xty) else { return nil }
        return PolynomialFit(degree: degree, coefficients: coeffs)
    }

    /// Evaluates the polynomial at a normalized x value.
    func evaluate(at x: Double) -> Double {
        var result = 0.0
        var power = 1.0
        for c in coefficients { result += c * power; power *= x }
        return result
    }

    /// BIC = n·ln(RSS/n) + k·ln(n), k = degree + 2. RSS is clamped to 1e-10.
    func computeBIC(normalizedX xs: [Double], y ys: [Double]) -> Double {
        let n = Double(xs.count)
        let k = Double(degree + 2)
        var rss = 0.0
        for i in 0 ..< xs.count {
            let residual = ys[i] - evaluate(at: xs[i])
            rss += residual * residual
        }
        return n * log(max(rss, 1e-10) / n) + k * log(n)
    }
}

/// Wraps a `PolynomialFit` with date normalization so it can evaluate at any `Date`.
struct ReadingTrend {
    let fit: PolynomialFit
    /// The earliest reading date (x = 0 in normalized space).
    let t0: Date
    /// Total time span in seconds (x = 1 in normalized space).
    let tScale: TimeInterval

    /// Computes the best-fit polynomial (degrees 1–4) for the given readings using BIC selection.
    /// Returns nil when readings.count < 3, all readings share the same timestamp, or all fits fail.
    static func compute(from readings: [Reading]) -> ReadingTrend? {
        guard readings.count >= 3 else { return nil }
        let sorted = readings.sorted { $0.recordedAt < $1.recordedAt }
        let t0 = sorted.first!.recordedAt
        let tScale = sorted.last!.recordedAt.timeIntervalSince(t0)
        guard tScale > 0 else { return nil }

        let xs = sorted.map { $0.recordedAt.timeIntervalSince(t0) / tScale }
        let ys = sorted.map(\.value)

        var bestFit: PolynomialFit? = nil
        var bestBIC = Double.infinity
        let maxDegree = min(4, sorted.count - 1)
        for degree in 1 ... maxDegree {
            guard let candidate = PolynomialFit.fit(normalizedX: xs, y: ys, degree: degree) else { continue }
            let bic = candidate.computeBIC(normalizedX: xs, y: ys)
            if bic < bestBIC { bestBIC = bic; bestFit = candidate }
        }

        guard let fit = bestFit else { return nil }
        return ReadingTrend(fit: fit, t0: t0, tScale: tScale)
    }

    /// Evaluates the polynomial at the given date.
    func evaluate(at date: Date) -> Double {
        let x = date.timeIntervalSince(t0) / tScale
        return fit.evaluate(at: x)
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
