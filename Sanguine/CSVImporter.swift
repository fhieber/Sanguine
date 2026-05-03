import Foundation
import SwiftData

/// Import historical data from a CSV file.
///
/// Expected CSV format (header row required):
///   date,reading,dose,note
///   2024-01-15,2.4,1.25,
///   2024-01-22,2.8,,felt fine
///   2024-01-10,,1.0,
///
/// - Rows with a `reading` value → imported as `Reading` (dose attached if present)
/// - Rows with only a `dose` value → imported as `DoseEntry`
/// - Rows with neither are skipped
///
/// Accepted date formats: ISO 8601 (yyyy-MM-dd), dd.MM.yyyy, MM/dd/yyyy
struct CSVImporter {

    struct ImportResult {
        var insertedReading: Int = 0
        var insertedDose: Int = 0
        var skipped: Int = 0    // duplicates
        var errors: [String] = []
    }

    private static let maxImportBytes = 5_000_000 // 5 MB

    static func importData(from url: URL, into context: ModelContext) throws -> ImportResult {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? Int, size > Self.maxImportBytes {
            throw ImportError.fileTooLarge
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.isEmpty else { throw ImportError.emptyFile }

        // Parse header
        let header = parseCSVLine(lines[0].lowercased())
        guard let dateCol = header.firstIndex(where: { $0.contains("date") }) else {
            throw ImportError.missingColumns
        }
        let readingCol = header.firstIndex(where: { $0.contains("reading") })
        let doseCol    = header.firstIndex(where: { $0.contains("dose") || $0.contains("dosis") })
        let noteCol    = header.firstIndex(where: { $0.contains("note") })

        if readingCol == nil && doseCol == nil { throw ImportError.missingColumns }

        // Fetch existing externalIDs to detect duplicates
        let existingReadings = try context.fetch(FetchDescriptor<Reading>())
        let existingDoses    = try context.fetch(FetchDescriptor<DoseEntry>())
        var knownReadings = Set(existingReadings.compactMap(\.externalID))
        var knownDoses    = Set(existingDoses.compactMap(\.externalID))

        var result = ImportResult()
        let parsers = Self.dateParsers

        for (lineIndex, line) in lines.dropFirst().enumerated() {
            guard !line.isEmpty else { continue }
            let cols = Self.parseCSVLine(line)

            guard dateCol < cols.count else {
                result.errors.append("Line \(lineIndex + 2): too few columns")
                continue
            }

            let rawDate = cols[dateCol].trimmingCharacters(in: .whitespaces)
            guard let date = Self.parseDate(rawDate, using: parsers) else {
                result.errors.append("Line \(lineIndex + 2): unrecognized date '\(rawDate)'")
                continue
            }

            let rawReading = readingCol.flatMap { $0 < cols.count ? cols[$0].trimmingCharacters(in: .whitespaces) : nil } ?? ""
            let rawDose    = doseCol.flatMap    { $0 < cols.count ? cols[$0].trimmingCharacters(in: .whitespaces) : nil } ?? ""
            let note       = noteCol.flatMap    { $0 < cols.count ? cols[$0].trimmingCharacters(in: .whitespaces) : nil } ?? ""

            let readingValue = Double(rawReading.replacingOccurrences(of: ",", with: "."))
            let doseValue    = Double(rawDose.replacingOccurrences(of: ",", with: "."))

            if readingValue == nil && doseValue == nil { continue }

            if let rv = readingValue {
                // Reading row — attach dose if present
                let externalID = "\(rawDate)_\(rawReading)"
                if knownReadings.contains(externalID) {
                    result.skipped += 1
                } else {
                    let r = Reading(value: rv, recordedAt: date, note: note, dose: doseValue, externalID: externalID)
                    context.insert(r)
                    knownReadings.insert(externalID)
                    result.insertedReading += 1
                }
                // Also insert a DoseEntry when dose is present on a reading row
                if let dose = doseValue {
                    let doseExternalID = "\(rawDate)_dose_\(rawDose)"
                    if !knownDoses.contains(doseExternalID) {
                        let e = DoseEntry(date: date, dose: dose, note: note, externalID: doseExternalID)
                        context.insert(e)
                        knownDoses.insert(doseExternalID)
                        result.insertedDose += 1
                    }
                }
            } else if let dose = doseValue {
                // Dose-only row
                let externalID = "\(rawDate)_dose_\(rawDose)"
                if knownDoses.contains(externalID) {
                    result.skipped += 1
                } else {
                    let e = DoseEntry(date: date, dose: dose, note: note, externalID: externalID)
                    context.insert(e)
                    knownDoses.insert(externalID)
                    result.insertedDose += 1
                }
            }
        }

        return result
    }

    // MARK: - Private helpers

    /// Parse a single CSV line respecting RFC 4180 quoting (handles commas inside quoted fields).
    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex

        while i < line.endIndex {
            let ch = line[i]
            if inQuotes {
                if ch == "\"" {
                    let next = line.index(after: i)
                    if next < line.endIndex && line[next] == "\"" {
                        // Escaped quote
                        current.append("\"")
                        i = line.index(after: next)
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(ch)
                }
            } else {
                if ch == "\"" {
                    inQuotes = true
                } else if ch == "," {
                    fields.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            i = line.index(after: i)
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    private static var isoDateTimeParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static var dateParsers: [DateFormatter] {
        let formats = ["yyyy-MM-dd", "dd.MM.yyyy", "MM/dd/yyyy", "dd-MM-yyyy"]
        return formats.map { fmt in
            let f = DateFormatter()
            f.dateFormat = fmt
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }
    }

    private static func parseDate(_ string: String, using parsers: [DateFormatter]) -> Date? {
        // Try full ISO 8601 datetime first (e.g. "2024-10-22T18:42:07+02:00")
        if string.contains("T"), let d = isoDateTimeParser.date(from: string) {
            return d
        }
        // Date-only strings: parse then set to 18:00 CET
        for parser in parsers {
            if let d = parser.date(from: string) {
                return dateAt6pmCET(d)
            }
        }
        return nil
    }

    private static func dateAt6pmCET(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        var components = cal.dateComponents([.year, .month, .day], from: date)
        components.hour = 18
        components.minute = 0
        components.second = 0
        return cal.date(from: components) ?? date
    }

    // MARK: - Export

    static func exportCSV(readings: [Reading], doseEntries: [DoseEntry]) -> String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        let cal = Calendar.current

        // Build a set of days where a reading already carries a dose value
        let readingDaysWithDose = Set(
            readings.compactMap { $0.dose != nil ? cal.startOfDay(for: $0.recordedAt) : nil }
        )

        // Exclude planned doses and deduplicate actual entries by calendar day — keep the latest per day
        var latestDosePerDay: [Date: DoseEntry] = [:]
        for e in doseEntries where e.isPlanned != true {
            let day = cal.startOfDay(for: e.date)
            if let existing = latestDosePerDay[day] {
                if e.date > existing.date { latestDosePerDay[day] = e }
            } else {
                latestDosePerDay[day] = e
            }
        }

        // Collect all rows as (sortDate, csvLine) — merge readings and dose-only entries
        var rows: [(date: Date, line: String)] = []

        for r in readings {
            let note = r.note.replacingOccurrences(of: ",", with: ";")
            let dose = r.dose.map { $0.doseFormatted } ?? ""
            rows.append((r.recordedAt, "\(df.string(from: r.recordedAt)),\(r.value),\(dose),\(note)"))
        }

        for e in latestDosePerDay.values {
            guard !readingDaysWithDose.contains(cal.startOfDay(for: e.date)) else { continue }
            let note = e.note.replacingOccurrences(of: ",", with: ";")
            rows.append((e.date, "\(df.string(from: e.date)),,\(e.dose.doseFormatted),\(note)"))
        }

        rows.sort { $0.date < $1.date }

        return (["date,reading,dose,note"] + rows.map(\.line)).joined(separator: "\n")
    }

    enum ImportError: LocalizedError {
        case emptyFile
        case missingColumns
        case fileTooLarge

        var errorDescription: String? {
            switch self {
            case .emptyFile: return "The file is empty."
            case .missingColumns: return "CSV must have a 'date' column and at least 'reading' or 'dose'."
            case .fileTooLarge: return "File exceeds the 5 MB import limit."
            }
        }
    }
}
