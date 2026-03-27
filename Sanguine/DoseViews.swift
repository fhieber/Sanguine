import SwiftUI
import SwiftData
import Charts
import WidgetKit

// MARK: - Dose Range

enum DoseRange: String, CaseIterable {
    case last7Days  = "7D"
    case last2Weeks = "2W"
    case lastMonth  = "1M"
    case last3Months = "3M"
    case allTime    = "All"

    func cutoff() -> Date? {
        let cal = Calendar.current
        switch self {
        case .last7Days:   return cal.date(byAdding: .day,   value: -7,  to: .now)
        case .last2Weeks:  return cal.date(byAdding: .day,   value: -14, to: .now)
        case .lastMonth:   return cal.date(byAdding: .month, value: -1,  to: .now)
        case .last3Months: return cal.date(byAdding: .month, value: -3,  to: .now)
        case .allTime:     return nil
        }
    }
}

// MARK: - Dose Tab

struct DoseTab: View {
    @Query(sort: \DoseEntry.date, order: .reverse) private var allEntries: [DoseEntry]
    @Environment(\.modelContext) private var modelContext

    @AppStorage("doseTimeHour", store: .appGroup) private var doseHour: Int = 18
    @AppStorage("doseTimeMinute", store: .appGroup) private var doseMinute: Int = 0
    @AppStorage("doseTimezone", store: .appGroup) private var doseTimezoneID: String = "Europe/Berlin"
    @AppStorage("doseReminderEnabled", store: .appGroup) private var doseReminderEnabled: Bool = true

    @State private var selectedRange: DoseRange = .last2Weeks
    @State private var customRange: (start: Date, end: Date)? = nil
    @State private var showingCustomPicker = false
    @State private var visibleCount = 5
    @State private var showingAdd = false
    @State private var deepLinkEntry: DoseEntry? = nil

    private var plannedTimeLabel: String {
        doseTimeLabel(hour: doseHour, minute: doseMinute, timezoneID: doseTimezoneID)
    }

    private var today: Date { Calendar.current.startOfDay(for: .now) }

    private var todaysDose: [DoseEntry] {
        allEntries.filter { $0.isPlanned != false && Calendar.current.isDateInToday($0.date) }
                  .sorted { $0.date < $1.date }
    }

    private var upcoming: [DoseEntry] {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        return allEntries.filter { $0.isPlanned != false && $0.date >= tomorrow }
                         .sorted { $0.date < $1.date }
    }

    private var historical: [DoseEntry] {
        allEntries.filter { $0.isPlanned == false || $0.date < today }
    }

    private var filtered: [DoseEntry] {
        if let custom = customRange {
            return historical.filter { $0.date >= custom.start && $0.date <= custom.end }
        }
        guard let cutoff = selectedRange.cutoff() else { return historical }
        return historical.filter { $0.date >= cutoff }
    }

    private var stats: DoseStats { DoseStats(entries: filtered) }

    private var historyRows: [DoseEntry] {
        Array(filtered.prefix(visibleCount))
    }

    var body: some View {
        NavigationStack {
            List {
                // Today's planned dose
                if !todaysDose.isEmpty {
                    Section("Today") {
                        ForEach(todaysDose) { entry in
                            NavigationLink(destination: DoseDetailView(entry: entry)) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(plannedTimeLabel)
                                            .font(.headline)
                                        Text("Planned")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(entry.dose.doseFormatted)
                                        .foregroundStyle(.orange)
                                        .fontWeight(.medium)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { modelContext.delete(todaysDose[i]) }
                            WidgetCenter.shared.reloadAllTimelines()
                        }
                    }
                }

                // Upcoming planned doses (tomorrow and beyond)
                if !upcoming.isEmpty {
                    Section("Upcoming") {
                        ForEach(upcoming) { entry in
                            NavigationLink(destination: DoseDetailView(entry: entry)) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                            .font(.headline)
                                        Text("Planned")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(entry.dose.doseFormatted)
                                        .foregroundStyle(.orange)
                                        .fontWeight(.medium)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { modelContext.delete(upcoming[i]) }
                            WidgetCenter.shared.reloadAllTimelines()
                        }
                    }
                }

                // Dose chart
                if filtered.count >= 2 {
                    Section {
                        DoseChartView(entries: filtered)
                            .frame(height: 220)
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    } header: {
                        rangePicker
                    }
                }

                // Statistics
                if !allEntries.isEmpty {
                    Section("Statistics") {
                        DoseStatsGrid(stats: stats)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    }
                }

                // History
                Section {
                    if allEntries.isEmpty {
                        ContentUnavailableView(
                            "No Dose Data",
                            systemImage: "calendar.badge.checkmark",
                            description: Text("Import a CSV file in Settings to load dose history.")
                        )
                    } else {
                        ForEach(historyRows) { entry in
                            NavigationLink(destination: DoseDetailView(entry: entry)) {
                                DoseRowView(entry: entry)
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { modelContext.delete(historyRows[i]) }
                            WidgetCenter.shared.reloadAllTimelines()
                        }
                        if visibleCount < filtered.count {
                            Button("Load 5 more (\(filtered.count - visibleCount) remaining)") {
                                visibleCount += 5
                            }
                            .foregroundStyle(.blue)
                        }
                    }
                } header: {
                    HStack {
                        Text("History")
                        Spacer()
                        EditButton()
                            .textCase(nil)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Doses")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingAdd) { AddDosePlanView() }
            .sheet(isPresented: $showingCustomPicker) {
                DateRangePickerSheet(customRange: $customRange)
            }
            .navigationDestination(item: $deepLinkEntry) { entry in
                DoseDetailView(entry: entry)
            }
            .onAppear(perform: handleDeepLinkIfNeeded)
            .onReceive(NotificationCenter.default.publisher(for: .navigateToDoseDetail)) { _ in
                handleDeepLinkIfNeeded()
            }
            .onChange(of: todaysDose) { scheduleTodayNotification() }
            .onAppear(perform: scheduleTodayNotification)
        }
    }

    private func handleDeepLinkIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "navigateToDoseDetail") else { return }
        UserDefaults.standard.removeObject(forKey: "navigateToDoseDetail")
        deepLinkEntry = todaysDose.first
    }

    private func scheduleTodayNotification() {
        if let dose = todaysDose.first, doseReminderEnabled {
            NotificationManager.shared.schedulePlannedDoseNotification(
                dose: dose.dose, hour: doseHour, minute: doseMinute, timezoneID: doseTimezoneID
            )
        } else {
            NotificationManager.shared.cancelPlannedDoseNotification()
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 6) {
            Text("Trend")
            Spacer()
            if let custom = customRange {
                HStack(spacing: 4) {
                    Text("\(custom.start.formatted(date: .abbreviated, time: .omitted)) – \(custom.end.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundStyle(.primary)
                    Button { customRange = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .textCase(nil)
            } else {
                Picker("Range", selection: $selectedRange) {
                    ForEach(DoseRange.allCases, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .textCase(nil)
                .onChange(of: selectedRange) { visibleCount = 5 }
            }
            Button { showingCustomPicker = true } label: {
                Image(systemName: "calendar")
                    .foregroundStyle(customRange != nil ? .blue : .secondary)
            }
            .textCase(nil)
        }
    }
}

// MARK: - Dose Chart

struct DoseChartView: View {
    let entries: [DoseEntry]

    private var sorted: [DoseEntry] { entries.sorted { $0.date < $1.date } }

    var body: some View {
        Chart {
            ForEach(sorted) { e in
                PointMark(
                    x: .value("Date", e.date),
                    y: .value("Dose", e.dose)
                )
                .foregroundStyle(Color.orange)
                .symbolSize(50)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
    }

    private var yDomain: ClosedRange<Double> {
        let values = entries.map(\.dose)
        let lo = max(0, (values.min() ?? 0) - 0.5)
        let hi = (values.max() ?? 2) + 0.5
        return lo...hi
    }
}

// MARK: - Dose Stats Grid

struct DoseStatsGrid: View {
    let stats: DoseStats

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatCard(
                title: "Average",
                value: stats.average.map { String(format: "%.2f", $0) } ?? "—",
                subtitle: {
                    if let lo = stats.minimum, let hi = stats.maximum {
                        return "\(lo.doseFormatted) – \(hi.doseFormatted)"
                    }
                    return nil
                }()
            )
            StatCard(
                title: "Avg Weekly Total",
                value: stats.averageWeeklyTotal.map { String(format: "%.2f", $0) } ?? "—",
                subtitle: stats.completeWeekCount > 0 ? "over \(stats.completeWeekCount) weeks" : nil
            )
        }
    }
}

// MARK: - Dose Detail

struct DoseDetailView: View {
    @Bindable var entry: DoseEntry
    @Query(sort: \Reading.recordedAt) private var allReadings: [Reading]
    @Environment(\.dismiss) private var dismiss
    @AppStorage("doseTimeHour", store: .appGroup) private var doseHour: Int = 18
    @AppStorage("doseTimeMinute", store: .appGroup) private var doseMinute: Int = 0
    @AppStorage("doseTimezone", store: .appGroup) private var doseTimezoneID: String = "Europe/Berlin"
    @State private var doseText: String = ""
    @FocusState private var amountFocused: Bool

    private var nextReading: Reading? {
        allReadings.first { $0.recordedAt > entry.date }
    }

    private var isPlannedToday: Bool {
        entry.isPlanned != false && Calendar.current.isDateInToday(entry.date)
    }

    var body: some View {
        Form {
            Section("Dose") {
                HStack {
                    Text("Amount")
                    Spacer()
                    TextField("e.g. 1.25", text: $doseText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .focused($amountFocused)
                        .onChange(of: doseText) {
                            if let v = Double(doseText.replacingOccurrences(of: ",", with: ".")) {
                                entry.dose = v
                            }
                        }
                }
                LabeledContent("Date", value: entry.date.formatted(date: .long, time: .omitted))
                if entry.isPlanned != false {
                    LabeledContent("Time", value: doseTimeLabel(hour: doseHour, minute: doseMinute, timezoneID: doseTimezoneID))
                } else {
                    LabeledContent("Time", value: entry.date.formatted(date: .omitted, time: .shortened))
                }
            }

            if let reading = nextReading {
                let days = Calendar.current.dateComponents([.day], from: entry.date, to: reading.recordedAt).day ?? 0
                Section {
                    LabeledContent("Reading", value: String(format: "%.1f", reading.value))
                    LabeledContent("Recorded", value: reading.recordedAt.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("Days after dose", value: "\(days)")
                    if !reading.note.isEmpty {
                        LabeledContent("Note", value: reading.note)
                    }
                } header: {
                    Text("Next Reading")
                } footer: {
                    Text("The first reading recorded after this dose")
                        .font(.caption2)
                }
            }

            Section("Notes") {
                TextField("Notes", text: $entry.note, axis: .vertical)
                    .lineLimit(2...5)
            }

            if isPlannedToday {
                Section {
                    Button {
                        entry.isPlanned = false
                        entry.date = .now
                        NotificationManager.shared.cancelPlannedDoseNotification()
                        WidgetCenter.shared.reloadAllTimelines()
                        dismiss()
                    } label: {
                        Text("Applied")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .foregroundStyle(.white)
                    .listRowBackground(Color.blue)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { amountFocused = false }
            }
        }
        .navigationTitle("Dose Detail")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            doseText = entry.dose.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(entry.dose))
                : String(entry.dose)
        }
    }
}

// MARK: - Dose Row

struct DoseRowView: View {
    let entry: DoseEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.headline)
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(entry.dose.doseFormatted)
                .foregroundStyle(.orange)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Add Dose Plan

struct AddDosePlanView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \DoseEntry.date) private var allDoses: [DoseEntry]

    @State private var days: [PlannedDay] = []
    @FocusState private var focusedIndex: Int?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(days.indices, id: \.self) { i in
                        HStack {
                            Text(days[i].date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                                .foregroundStyle(existingDose(for: days[i].date, in: allDoses) != nil ? .secondary : .primary)
                            Spacer()
                            TextField("—", text: $days[i].doseText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 60)
                                .focused($focusedIndex, equals: i)
                                .submitLabel(.next)
                                .onSubmit { addNextDay(after: i) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { focusedIndex = i }
                    }
                } header: {
                    Text("Plan Doses")
                } footer: {
                    Text("Press Next after each day to add the following day.")
                }
            }
            .navigationTitle("Plan Doses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Previous") {
                        if let i = focusedIndex, i > 0 {
                            focusedIndex = i - 1
                        }
                    }
                    .disabled((focusedIndex ?? 0) == 0)
                    Spacer()
                    Button("Next") {
                        if let i = focusedIndex {
                            addNextDay(after: i)
                        }
                    }
                }
            }
            .onAppear {
                setupDays()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    focusedIndex = 0
                }
            }
        }
    }

    private func setupDays() {
        days = buildPlannedDays(startingAt: Calendar.current.startOfDay(for: .now), in: allDoses)
    }

    private func addNextDay(after index: Int) {
        let next = appendNextDayIfNeeded(after: index, days: &days, doses: allDoses)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focusedIndex = next }
    }

    private func save() {
        upsertPlannedDays(days, doses: allDoses, into: modelContext)
        WidgetCenter.shared.reloadAllTimelines()
        dismiss()
    }
}
