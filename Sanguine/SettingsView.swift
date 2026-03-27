import SwiftUI
import SwiftData
import WidgetKit

struct SettingsView: View {
    @AppStorage("readingLowTarget", store: .appGroup) private var lowTarget: Double = 2.0
    @AppStorage("readingHighTarget", store: .appGroup) private var highTarget: Double = 3.0
    @AppStorage("doseReminderEnabled", store: .appGroup) private var doseReminderEnabled: Bool = true
    @AppStorage("doseTimeHour", store: .appGroup) private var doseHour: Int = 18
    @AppStorage("doseTimeMinute", store: .appGroup) private var doseMinute: Int = 0
    @AppStorage("doseTimezone", store: .appGroup) private var doseTimezoneID: String = "Europe/Berlin"
    @AppStorage("readingReminderEnabled", store: .appGroup) private var readingReminderEnabled: Bool = true
    @AppStorage("readingReminderWeekday", store: .appGroup) private var readingReminderWeekday: Int = 1  // 1 = Sunday
    @AppStorage("readingReminderHour", store: .appGroup) private var readingReminderHour: Int = 8
    @AppStorage("readingReminderMinute", store: .appGroup) private var readingReminderMinute: Int = 0

    @State private var doseTime: Date = Date()
    @State private var readingReminderTime: Date = Date()
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Reading.recordedAt) private var readings: [Reading]

    @Query private var doseEntries: [DoseEntry]

    @State private var showingFilePicker = false
    @State private var importResult: String? = nil
    @State private var showingImportAlert = false
    @State private var showingDeleteConfirm = false
    @State private var showingDemoConfirm = false
    @State private var exportFile: ExportFile? = nil

    @FocusState private var isTargetFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                // 1) Target Range
                Section {
                    HStack {
                        Text("Low Target")
                        Spacer()
                        TextField("Low", value: $lowTarget, format: .number.precision(.fractionLength(1)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .focused($isTargetFocused)
                    }
                    HStack {
                        Text("High Target")
                        Spacer()
                        TextField("High", value: $highTarget, format: .number.precision(.fractionLength(1)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .focused($isTargetFocused)
                    }
                } header: {
                    Text("Target Range")
                }

                // 2) Dose Time
                Section {
                    Toggle("Reminder", isOn: $doseReminderEnabled)
                        .onChange(of: doseReminderEnabled) { scheduleDoseReminderIfNeeded() }
                    DatePicker("Time", selection: $doseTime, displayedComponents: .hourAndMinute)
                        .onChange(of: doseTime) {
                            let c = Calendar.current.dateComponents([.hour, .minute], from: doseTime)
                            doseHour   = c.hour   ?? 18
                            doseMinute = c.minute ?? 0
                            scheduleDoseReminderIfNeeded()
                        }
                    Picker("Timezone", selection: $doseTimezoneID) {
                        ForEach(commonTimezones, id: \.identifier) { tz in
                            Text(tz.displayLabel).tag(tz.identifier)
                        }
                    }
                } header: {
                    Text("Dose Time")
                } footer: {
                    Text(doseTimeFooter)
                }
                .onAppear {
                    var c = DateComponents()
                    c.hour = doseHour; c.minute = doseMinute
                    doseTime = Calendar.current.date(from: c) ?? Date()
                }

                // 3) Reading Reminder
                Section {
                    Toggle("Reminder", isOn: $readingReminderEnabled)
                        .onChange(of: readingReminderEnabled) {
                            NotificationManager.shared.updateReadingReminder(
                                enabled: readingReminderEnabled,
                                weekday: readingReminderWeekday,
                                hour: readingReminderHour,
                                minute: readingReminderMinute
                            )
                        }
                    if readingReminderEnabled {
                        Picker("Day", selection: $readingReminderWeekday) {
                            ForEach(1...7, id: \.self) { weekday in
                                Text(weekdayName(weekday)).tag(weekday)
                            }
                        }
                        .onChange(of: readingReminderWeekday) {
                            NotificationManager.shared.updateReadingReminder(
                                enabled: readingReminderEnabled,
                                weekday: readingReminderWeekday,
                                hour: readingReminderHour,
                                minute: readingReminderMinute
                            )
                        }
                        DatePicker("Time", selection: $readingReminderTime, displayedComponents: .hourAndMinute)
                            .onChange(of: readingReminderTime) {
                                let c = Calendar.current.dateComponents([.hour, .minute], from: readingReminderTime)
                                readingReminderHour   = c.hour   ?? 8
                                readingReminderMinute = c.minute ?? 0
                                NotificationManager.shared.updateReadingReminder(
                                    enabled: readingReminderEnabled,
                                    weekday: readingReminderWeekday,
                                    hour: readingReminderHour,
                                    minute: readingReminderMinute
                                )
                            }
                    }
                } header: {
                    Text("Reading Reminder")
                } footer: {
                    if readingReminderEnabled {
                        Text("Reminder every \(weekdayName(readingReminderWeekday)) at \(doseTimeLabel(hour: readingReminderHour, minute: readingReminderMinute, timezoneID: "local"))")
                    }
                }
                .onAppear {
                    var c = DateComponents()
                    c.hour = readingReminderHour; c.minute = readingReminderMinute
                    readingReminderTime = Calendar.current.date(from: c) ?? Date()
                }

                // 4) Data
                Section {
                    Button("Import") { showingFilePicker = true }
                    Button("Export") { exportFile = ExportFile(url: makeExportURL()) }
                    Button("Load Demo Data") { showingDemoConfirm = true }
                        .disabled(!readings.isEmpty || !doseEntries.isEmpty)
                    Button("Delete All Data", role: .destructive) { showingDeleteConfirm = true }
                } header: {
                    Text("Data")
                } footer: {
                    if !readings.isEmpty || !doseEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            let readingCount = readings.count
                            let doseCount    = doseEntries.count
                            let noteCount    = readings.filter { !$0.note.isEmpty }.count +
                                               doseEntries.filter { !$0.note.isEmpty }.count
                            Text("\(readingCount) readings · \(doseCount) dose records · \(noteCount) notes")
                            if let earliest = dataEarliestDate, let latest = dataLatestDate {
                                Text("\(earliest.formatted(date: .abbreviated, time: .omitted)) – \(latest.formatted(date: .abbreviated, time: .omitted))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    }
                }
                .fileImporter(
                    isPresented: $showingFilePicker,
                    allowedContentTypes: [.commaSeparatedText, .plainText],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        guard let url = urls.first else { return }
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                        do {
                            let summary = try CSVImporter.importData(from: url, into: modelContext)
                            try modelContext.save()
                            WidgetCenter.shared.reloadAllTimelines()
                            importResult = "Imported \(summary.insertedReading) readings and \(summary.insertedDose) dose entries. Skipped \(summary.skipped) duplicates."
                            if !summary.errors.isEmpty {
                                importResult! += "\n\(summary.errors.count) row(s) had errors."
                            }
                        } catch {
                            importResult = "Import failed: \(error.localizedDescription)"
                        }
                        showingImportAlert = true
                    case .failure(let error):
                        importResult = "Could not open file: \(error.localizedDescription)"
                        showingImportAlert = true
                    }
                }
                .alert("Import Result", isPresented: $showingImportAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(importResult ?? "")
                }
                .confirmationDialog("Delete all data?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
                    Button("Delete All Data", role: .destructive) { deleteAllData() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently remove all readings and dose entries.")
                }
                .confirmationDialog("Load Demo Data?", isPresented: $showingDemoConfirm, titleVisibility: .visible) {
                    Button("Load Demo Data", role: .destructive) { loadDemoData() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will delete all existing data and replace it with generated sample data.")
                }
                .sheet(item: $exportFile) { file in
                    ActivityView(url: file.url)
                }

                // 5) Version
                Section("About") {
                    LabeledContent("Version", value: "1.0")
                    LabeledContent("Data", value: "Stored on device only")
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isTargetFocused = false }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var doseTimeFooter: String {
        doseReminderEnabled
            ? "Reminder at \(doseTimeLabel(hour: doseHour, minute: doseMinute, timezoneID: doseTimezoneID))"
            : "Reminders disabled"
    }

    private func scheduleDoseReminderIfNeeded() {
        if !doseReminderEnabled {
            NotificationManager.shared.cancelPlannedDoseNotification()
        }
    }

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        guard weekday >= 1, weekday <= symbols.count else { return "" }
        return symbols[weekday - 1]
    }

    private var commonTimezones: [TimeZone] {
        [
            "Europe/Berlin", "Europe/London", "Europe/Paris",
            "Europe/Zurich", "Europe/Rome", "Europe/Madrid",
            "America/New_York", "America/Chicago", "America/Los_Angeles",
            "America/Sao_Paulo", "Asia/Tokyo", "Asia/Shanghai",
            "Australia/Sydney", "UTC"
        ].compactMap { TimeZone(identifier: $0) }
    }

    private var dataEarliestDate: Date? {
        let dates = readings.map(\.recordedAt) + doseEntries.map(\.date)
        return dates.min()
    }

    private var dataLatestDate: Date? {
        let dates = readings.map(\.recordedAt) + doseEntries.map(\.date)
        return dates.max()
    }

    private func loadDemoData() {
        // Box-Muller Gaussian sampler
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

        // Generate readings with dose-reading feedback loop:
        // higher reading → higher next dose → lower subsequent reading
        var generatedReadings: [Reading] = []
        var prevDose = meanDose

        for week in stride(from: -38, through: 0, by: 1) {
            guard let baseDate = cal.date(byAdding: .weekOfYear, value: week, to: now) else { continue }
            let jitter = TimeInterval.random(in: -86400...86400)
            let date = baseDate.addingTimeInterval(jitter)
            guard date <= now else { continue }

            // Reading influenced by previous dose: higher dose pulls reading down
            let doseEffect = -0.7 * (prevDose - meanDose)
            let value = max(4, min(12, gaussian(mean: mean + doseEffect, sigma: sigma)))
            let roundedValue = (value * 10).rounded() / 10

            // Dose at reading day: respond to reading deviation
            let readingDeviation = roundedValue - mean
            let nextDose = max(1, min(6, gaussian(mean: meanDose + 0.4 * readingDeviation, sigma: 0.3)))
            let roundedDose = (nextDose * 4).rounded() / 4

            let r = Reading(value: roundedValue, recordedAt: date)
            r.dose = roundedDose
            generatedReadings.append(r)
            modelContext.insert(r)
            prevDose = roundedDose

            // Mid-week dose entry (3 days later)
            if let midDate = cal.date(byAdding: .day, value: 3, to: date), midDate <= now {
                let midDose = max(1, min(6, gaussian(mean: roundedDose, sigma: 0.2)))
                let entry = DoseEntry(date: midDate, dose: (midDose * 4).rounded() / 4)
                entry.isPlanned = false
                modelContext.insert(entry)
            }
        }

        // Set target range to cover ~70% of data (mean ± 1σ → ~30% out of range)
        let values = generatedReadings.map(\.value)
        let actualMean = values.reduce(0, +) / Double(values.count)
        let actualSigma = sqrt(values.map { pow($0 - actualMean, 2) }.reduce(0, +) / Double(values.count))
        lowTarget  = (max(0, actualMean - actualSigma) * 10).rounded() / 10
        highTarget = ((actualMean + actualSigma) * 10).rounded() / 10

        try? modelContext.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func deleteAllData() {
        readings.forEach    { modelContext.delete($0) }
        doseEntries.forEach { modelContext.delete($0) }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func makeExportURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let filename = "sanguine_export_\(formatter.string(from: Date())).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        let csv = CSVImporter.exportCSV(readings: Array(readings), doseEntries: Array(doseEntries))
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private extension TimeZone {
    var displayLabel: String {
        let abbr = abbreviation(for: Date()) ?? ""
        let city = identifier.split(separator: "/").last.map(String.init) ?? identifier
        return "\(city) (\(abbr))"
    }
}

import UIKit
struct ActivityView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}
