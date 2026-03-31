import XCTest
import SwiftData
@testable import Sanguine

// MARK: - Helpers

private func makeContext() throws -> ModelContext {
    let container = try ModelContainer(
        for: Reading.self, DoseEntry.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return ModelContext(container)
}

/// Returns a Date for the given ISO 8601 string.
private func date(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso)!
}

/// Returns a Date set to the start of the given calendar day offset from today.
private func today(offsetDays: Int = 0) -> Date {
    Calendar.current.date(byAdding: .day, value: offsetDays,
                          to: Calendar.current.startOfDay(for: .now))!
}

/// Returns a Date at the start of the Monday of the week offset from this week.
private func monday(weeksAgo: Int = 0) -> Date {
    var cal = Calendar.current
    cal.firstWeekday = 2 // Monday
    let weekInterval = cal.dateInterval(of: .weekOfYear, for: .now)!
    let weekStart = cal.date(byAdding: .weekOfYear, value: -weeksAgo, to: weekInterval.start)!
    return weekStart
}

// MARK: - ReadingStats Tests

final class ReadingStatsTests: XCTestCase {

    private let low = 2.0, high = 3.0

    func testEmptyReturnsNils() {
        let s = ReadingStats(readings: [], lowTarget: low, highTarget: high)
        XCTAssertEqual(s.count, 0)
        XCTAssertNil(s.latest)
        XCTAssertNil(s.average)
        XCTAssertNil(s.minimum)
        XCTAssertNil(s.maximum)
        XCTAssertNil(s.stdDev)
        XCTAssertNil(s.timeInRangePercent)
    }

    func testSingleReading() {
        let r = Reading(value: 2.5, recordedAt: .now)
        let s = ReadingStats(readings: [r], lowTarget: low, highTarget: high)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.average, 2.5)
        XCTAssertEqual(s.minimum, 2.5)
        XCTAssertEqual(s.maximum, 2.5)
        XCTAssertNil(s.stdDev) // need >1 for std dev
        XCTAssertEqual(s.timeInRangePercent, 100.0)
    }

    func testAllInRange() {
        let rs = [2.1, 2.5, 2.9].map { Reading(value: $0, recordedAt: .now) }
        let s = ReadingStats(readings: rs, lowTarget: low, highTarget: high)
        XCTAssertEqual(s.timeInRangePercent, 100.0)
        rs.forEach { XCTAssertTrue(s.isInRange($0)) }
    }

    func testNoneInRange() {
        let rs = [1.0, 3.5, 4.0].map { Reading(value: $0, recordedAt: .now) }
        let s = ReadingStats(readings: rs, lowTarget: low, highTarget: high)
        XCTAssertEqual(s.timeInRangePercent, 0.0)
        rs.forEach { XCTAssertFalse(s.isInRange($0)) }
    }

    func testPartialInRange() {
        let rs = [1.5, 2.5, 3.5].map { Reading(value: $0, recordedAt: .now) }
        let s = ReadingStats(readings: rs, lowTarget: low, highTarget: high)
        XCTAssertEqual(s.timeInRangePercent!, 100.0 / 3.0, accuracy: 0.01)
    }

    func testAverage() {
        let rs = [2.0, 3.0, 4.0].map { Reading(value: $0, recordedAt: .now) }
        let s = ReadingStats(readings: rs, lowTarget: low, highTarget: high)
        XCTAssertEqual(s.average!, 3.0, accuracy: 0.001)
    }

    func testMinMax() {
        let rs = [1.5, 2.5, 3.8].map { Reading(value: $0, recordedAt: .now) }
        let s = ReadingStats(readings: rs, lowTarget: low, highTarget: high)
        XCTAssertEqual(s.minimum!, 1.5, accuracy: 0.001)
        XCTAssertEqual(s.maximum!, 3.8, accuracy: 0.001)
    }

    func testStdDev() {
        // values: 2, 4 → mean 3, variance = ((2-3)²+(4-3)²)/2 = 1, stddev = 1
        let rs = [2.0, 4.0].map { Reading(value: $0, recordedAt: .now) }
        let s = ReadingStats(readings: rs, lowTarget: low, highTarget: high)
        XCTAssertEqual(s.stdDev!, 1.0, accuracy: 0.001)
    }

    func testLatestIsNewest() {
        let older = Reading(value: 2.0, recordedAt: date("2026-01-01T10:00:00+00:00"))
        let newer = Reading(value: 3.0, recordedAt: date("2026-02-01T10:00:00+00:00"))
        let s = ReadingStats(readings: [older, newer], lowTarget: low, highTarget: high)
        XCTAssertEqual(s.latest?.value, 3.0)
    }
}

// MARK: - DoseStats Tests

final class DoseStatsTests: XCTestCase {

    func testEmptyReturnsNils() {
        let s = DoseStats(entries: [])
        XCTAssertNil(s.average)
        XCTAssertNil(s.minimum)
        XCTAssertNil(s.maximum)
        XCTAssertNil(s.averageWeeklyTotal)
        XCTAssertEqual(s.completeWeekCount, 0)
    }

    func testAverageAndMinMax() {
        let entries = [1.0, 1.25, 1.5].map { DoseEntry(date: .now, dose: $0) }
        let s = DoseStats(entries: entries)
        XCTAssertEqual(s.average!, (1.0 + 1.25 + 1.5) / 3, accuracy: 0.001)
        XCTAssertEqual(s.minimum!, 1.0, accuracy: 0.001)
        XCTAssertEqual(s.maximum!, 1.5, accuracy: 0.001)
    }

    /// A single complete week (Mon–Sun with 7 daily entries) should give the correct total.
    func testWeeklyTotalOneCompleteWeek() {
        let mon = monday(weeksAgo: 1)
        var cal = Calendar.current; cal.firstWeekday = 2
        let entries = (0..<7).map { day -> DoseEntry in
            let d = cal.date(byAdding: .day, value: day, to: mon)!
            return DoseEntry(date: d, dose: 1.0)
        }
        let s = DoseStats(entries: entries)
        XCTAssertEqual(s.completeWeekCount, 1)
        XCTAssertEqual(s.averageWeeklyTotal!, 7.0, accuracy: 0.001)
    }

    /// Two complete weeks should average correctly.
    func testWeeklyTotalTwoCompleteWeeks() {
        var cal = Calendar.current; cal.firstWeekday = 2
        var entries: [DoseEntry] = []
        for weeksAgo in 1...2 {
            let mon = monday(weeksAgo: weeksAgo)
            for day in 0..<7 {
                let d = cal.date(byAdding: .day, value: day, to: mon)!
                entries.append(DoseEntry(date: d, dose: weeksAgo == 1 ? 1.0 : 2.0))
            }
        }
        let s = DoseStats(entries: entries)
        XCTAssertEqual(s.completeWeekCount, 2)
        // week1: 7×1.0=7, week2: 7×2.0=14 → avg = 10.5
        XCTAssertEqual(s.averageWeeklyTotal!, 10.5, accuracy: 0.001)
    }

    /// If only partial boundary weeks exist, averageWeeklyTotal should be nil.
    func testWeeklyTotalNilWhenOnlyPartialWeeks() {
        let entries = [
            DoseEntry(date: today(offsetDays: -1), dose: 1.0),
            DoseEntry(date: today(),               dose: 1.0),
        ]
        let s = DoseStats(entries: entries)
        XCTAssertNil(s.averageWeeklyTotal)
        XCTAssertEqual(s.completeWeekCount, 0)
    }
}

// MARK: - Dose Planning Helper Tests

final class DosePlanningTests: XCTestCase {

    func testExistingDoseFindsMatch() {
        let entry = DoseEntry(date: today(), dose: 1.5)
        XCTAssertNotNil(existingDose(for: today(), in: [entry]))
    }

    func testExistingDoseIgnoresDifferentDay() {
        let entry = DoseEntry(date: today(offsetDays: -1), dose: 1.5)
        XCTAssertNil(existingDose(for: today(), in: [entry]))
    }

    func testPlannedDoseTextFormatsCorrectly() {
        let entry = DoseEntry(date: today(), dose: 1.5)
        XCTAssertEqual(plannedDoseText(for: today(), in: [entry]), "1.5")
    }

    func testPlannedDoseTextWholeNumber() {
        let entry = DoseEntry(date: today(), dose: 2.0)
        XCTAssertEqual(plannedDoseText(for: today(), in: [entry]), "2")
    }

    func testPlannedDoseTextEmptyWhenNoEntry() {
        XCTAssertEqual(plannedDoseText(for: today(), in: []), "")
    }

    func testBuildPlannedDaysEmptyReturnsSingleToday() {
        let days = buildPlannedDays(startingAt: today(), in: [])
        XCTAssertEqual(days.count, 1)
        XCTAssertTrue(Calendar.current.isDate(days[0].date, inSameDayAs: today()))
        XCTAssertEqual(days[0].doseText, "")
    }

    func testBuildPlannedDaysPrePopulates() {
        let future = today(offsetDays: 2)
        let entry = DoseEntry(date: future, dose: 1.25)
        let days = buildPlannedDays(startingAt: today(), in: [entry])
        XCTAssertEqual(days.count, 1)
        XCTAssertTrue(Calendar.current.isDate(days[0].date, inSameDayAs: future))
        XCTAssertEqual(days[0].doseText, "1.25")
    }

    func testBuildPlannedDaysExcludesPast() {
        let past = today(offsetDays: -1)
        let future = today(offsetDays: 1)
        let entries = [DoseEntry(date: past, dose: 1.0), DoseEntry(date: future, dose: 1.5)]
        let days = buildPlannedDays(startingAt: today(), in: entries)
        XCTAssertTrue(days.allSatisfy { $0.date >= today() })
    }

    func testAppendNextDayIfNeededAddsDay() {
        var days = [PlannedDay(date: today(), doseText: "")]
        let next = appendNextDayIfNeeded(after: 0, days: &days, doses: [])
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(next, 1)
        let expectedNext = Calendar.current.date(byAdding: .day, value: 1, to: today())!
        XCTAssertTrue(Calendar.current.isDate(days[1].date, inSameDayAs: expectedNext))
    }

    func testAppendNextDayIfNeededDoesNotAddWhenNotLast() {
        var days = [PlannedDay(date: today(), doseText: ""),
                    PlannedDay(date: today(offsetDays: 1), doseText: "")]
        let next = appendNextDayIfNeeded(after: 0, days: &days, doses: [])
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(next, 1)
    }
}

// MARK: - doseTimeLabel Tests

final class DoseTimeLabelTests: XCTestCase {

    func testOnTheHour() {
        let label = doseTimeLabel(hour: 18, minute: 0, timezoneID: "Europe/Berlin")
        XCTAssertTrue(label.contains("6pm") || label.contains("6PM") || label.contains("18"),
                      "Expected 6pm in label, got: \(label)")
    }

    func testWithMinutes() {
        let label = doseTimeLabel(hour: 8, minute: 30, timezoneID: "Europe/Berlin")
        XCTAssertTrue(label.contains("8:30"), "Expected 8:30 in label, got: \(label)")
    }

    func testFallsBackToCurrentForUnknownTimezone() {
        let label = doseTimeLabel(hour: 8, minute: 0, timezoneID: "Invalid/Zone")
        XCTAssertFalse(label.isEmpty)
    }
}

// MARK: - CSV Import Date Parsing Tests

final class CSVDateParsingTests: XCTestCase {

    private var context: ModelContext!

    override func setUpWithError() throws {
        throw XCTSkip("Requires simulator (ModelContainer)")
    }

    private func importCSV(_ csv: String) throws -> [Reading] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        _ = try CSVImporter.importData(from: url, into: context)
        return try context.fetch(FetchDescriptor<Reading>(sortBy: [SortDescriptor(\.recordedAt)]))
    }

    func testISODateTimePreservesExactTimestamp() throws {
        let csv = "date,reading,dose,note\n2026-03-22T09:27:41+01:00,2.2,1.25,"
        let readings = try importCSV(csv)
        XCTAssertEqual(readings.count, 1)
        let expected = date("2026-03-22T09:27:41+01:00")
        XCTAssertEqual(readings[0].recordedAt.timeIntervalSince1970,
                       expected.timeIntervalSince1970, accuracy: 1)
    }

    func testDateOnlyDefaultsTo8amCET() throws {
        let csv = "date,reading,dose,note\n2026-01-15,2.5,,"
        let readings = try importCSV(csv)
        XCTAssertEqual(readings.count, 1)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let comps = cal.dateComponents([.hour, .minute], from: readings[0].recordedAt)
        XCTAssertEqual(comps.hour, 8)
        XCTAssertEqual(comps.minute, 0)
    }

    func testDotSeparatedDateFormat() throws {
        let csv = "date,reading,dose,note\n15.01.2026,2.5,,"
        let readings = try importCSV(csv)
        XCTAssertEqual(readings.count, 1)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let comps = cal.dateComponents([.year, .month, .day], from: readings[0].recordedAt)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 1)
        XCTAssertEqual(comps.day, 15)
    }

    func testInvalidDateProducesError() throws {
        let csv = "date,reading,dose,note\nnot-a-date,2.5,,"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        let result = try CSVImporter.importData(from: url, into: context)
        XCTAssertEqual(result.insertedReading, 0)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testRowWithNeitherReadingNorDoseIsSkipped() throws {
        let csv = "date,reading,dose,note\n2026-01-15,,,some note"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        let result = try CSVImporter.importData(from: url, into: context)
        XCTAssertEqual(result.insertedReading, 0)
        XCTAssertEqual(result.insertedDose, 0)
        XCTAssertEqual(result.errors.count, 0)
    }
}

// MARK: - CSV Roundtrip Tests

final class CSVRoundtripTests: XCTestCase {

    override func setUpWithError() throws {
        throw XCTSkip("Requires simulator (ModelContainer)")
    }

    func testRoundtrip() throws {
        let container = try ModelContainer(
            for: Reading.self, DoseEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let date1 = date("2026-01-10T09:00:00+01:00")
        let date2 = date("2026-01-17T18:30:00+01:00")
        let date3 = date("2026-01-20T08:00:00+01:00")

        let r1 = Reading(value: 2.4, recordedAt: date1, note: "feeling good", dose: 1.25)
        let r2 = Reading(value: 3.1, recordedAt: date2, note: "")
        let d1 = DoseEntry(date: date3, dose: 1.5, note: "skipped lunch")
        context.insert(r1); context.insert(r2); context.insert(d1)
        try context.save()

        let csv = CSVImporter.exportCSV(readings: [r1, r2], doseEntries: [d1])

        let importContainer = try ModelContainer(
            for: Reading.self, DoseEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let importContext = ModelContext(importContainer)
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip_test.csv")
        try csv.write(to: tmpURL, atomically: true, encoding: .utf8)
        let result = try CSVImporter.importData(from: tmpURL, into: importContext)

        XCTAssertEqual(result.insertedReading, 2)
        XCTAssertEqual(result.insertedDose, 2) // r1's dose + d1
        XCTAssertEqual(result.skipped, 0)
        XCTAssertTrue(result.errors.isEmpty)

        let importedReadings = try importContext.fetch(
            FetchDescriptor<Reading>(sortBy: [SortDescriptor(\.recordedAt)])
        )
        XCTAssertEqual(importedReadings[0].value, r1.value, accuracy: 0.001)
        XCTAssertEqual(importedReadings[0].recordedAt.timeIntervalSince1970, r1.recordedAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(importedReadings[0].note, r1.note)
        XCTAssertEqual(try XCTUnwrap(importedReadings[0].dose), try XCTUnwrap(r1.dose), accuracy: 0.001)
        XCTAssertEqual(importedReadings[1].value, r2.value, accuracy: 0.001)
        XCTAssertNil(importedReadings[1].dose)

        let importedDoses = try importContext.fetch(
            FetchDescriptor<DoseEntry>(sortBy: [SortDescriptor(\.date)])
        )
        XCTAssertEqual(importedDoses.count, 2)
        let doseFromReading = try XCTUnwrap(importedDoses.first { abs($0.date.timeIntervalSince1970 - date1.timeIntervalSince1970) < 1 })
        XCTAssertEqual(doseFromReading.dose, 1.25, accuracy: 0.001)
        let doseOnly = try XCTUnwrap(importedDoses.first { abs($0.date.timeIntervalSince1970 - date3.timeIntervalSince1970) < 1 })
        XCTAssertEqual(doseOnly.dose, 1.5, accuracy: 0.001)
        XCTAssertEqual(doseOnly.note, d1.note)
    }

    func testDeduplication() throws {
        let context = try makeContext()
        let r = Reading(value: 2.8, recordedAt: date("2026-02-05T10:00:00+01:00"), dose: 1.0)
        context.insert(r); try context.save()

        let csv = CSVImporter.exportCSV(readings: [r], doseEntries: [])
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("dedup_test.csv")
        try csv.write(to: tmpURL, atomically: true, encoding: .utf8)

        let first = try CSVImporter.importData(from: tmpURL, into: context)
        XCTAssertEqual(first.insertedReading, 1)

        let second = try CSVImporter.importData(from: tmpURL, into: context)
        XCTAssertEqual(second.insertedReading, 0)
        XCTAssertEqual(second.skipped, 1)
    }
}
