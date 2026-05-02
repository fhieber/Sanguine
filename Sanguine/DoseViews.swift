import SwiftUI
import SwiftData
import Charts
import WidgetKit

// MARK: - Dose Range

enum DoseRange: String, CaseIterable, ChartRange {
    case last7Days   = "7D"
    case last2Weeks  = "2W"
    case lastMonth   = "1M"
    case last3Months = "3M"
    case last6Months = "6M"
    case lastYear    = "1Y"
    case allTime     = "All"

    func cutoff() -> Date? {
        let cal = Calendar.current
        switch self {
        case .last7Days:   return cal.date(byAdding: .day,   value: -7,  to: .now)
        case .last2Weeks:  return cal.date(byAdding: .day,   value: -14, to: .now)
        case .lastMonth:   return cal.date(byAdding: .month, value: -1,  to: .now)
        case .last3Months: return cal.date(byAdding: .month, value: -3,  to: .now)
        case .last6Months: return cal.date(byAdding: .month, value: -6,  to: .now)
        case .lastYear:    return cal.date(byAdding: .year,  value: -1,  to: .now)
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
    @State private var statsScrollDate: Date = .now

    private var chartWindowDuration: TimeInterval? {
        customRange.map { $0.end.timeIntervalSince($0.start) } ?? selectedRange.windowDuration
    }

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
        if let wd = chartWindowDuration {
            let end = statsScrollDate.addingTimeInterval(wd)
            return historical.filter { $0.date >= statsScrollDate && $0.date <= end }
        }
        return historical
    }

    private var stats: DoseStats { DoseStats(entries: filtered) }

    private var dataRangeLabel: String {
        let start: Date
        let end: Date
        if let wd = chartWindowDuration {
            start = statsScrollDate
            end = statsScrollDate.addingTimeInterval(wd)
        } else {
            guard let s = historical.map(\.date).min(),
                  let e = historical.map(\.date).max() else { return "" }
            start = s; end = e
        }
        let cal = Calendar.current
        if cal.component(.year, from: start) == cal.component(.year, from: end) {
            return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
        } else {
            return "\(start.formatted(.dateTime.month(.abbreviated).year())) – \(end.formatted(.dateTime.month(.abbreviated).year()))"
        }
    }

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
                if historical.count >= 2 {
                    Section {
                        DoseChartView(
                            entries: historical,
                            windowDuration: chartWindowDuration,
                            anchorDate: customRange?.start,
                            onScrollSettled: { date in statsScrollDate = date }
                        )
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

                // Data
                Section {
                    if allEntries.isEmpty {
                        ContentUnavailableView(
                            "No Dose Data",
                            systemImage: "calendar.badge.checkmark",
                            description: Text("Tap + to plan doses, or import a CSV file in Settings.")
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
                        Text("Data")
                        if !dataRangeLabel.isEmpty {
                            Text(dataRangeLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
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
            .task { scheduleDoseNotifications() }
            .onChange(of: allEntries) { scheduleDoseNotifications() }
        }
    }

    private func handleDeepLinkIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "navigateToDoseDetail") else { return }
        UserDefaults.standard.removeObject(forKey: "navigateToDoseDetail")
        let todaysTakenDose = allEntries.first(where: { $0.isPlanned == false && Calendar.current.isDateInToday($0.date) })
        deepLinkEntry = todaysTakenDose ?? todaysDose.first
    }

    private func scheduleDoseNotifications() {
        guard doseReminderEnabled else {
            NotificationManager.shared.cancelPlannedDoseNotification()
            return
        }
        let today = Calendar.current.startOfDay(for: .now)
        let planned = allEntries.filter { $0.isPlanned == true && $0.date >= today }
        if planned.isEmpty {
            NotificationManager.shared.cancelPlannedDoseNotification()
        } else {
            NotificationManager.shared.schedulePlannedDoseNotifications(
                plannedDoses: planned.map { ($0.date, $0.dose) },
                hour: doseHour, minute: doseMinute, timezoneID: doseTimezoneID
            )
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 6) {
            Text("Range")
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
                .frame(maxWidth: 280)
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
    let windowDuration: TimeInterval?
    var anchorDate: Date? = nil
    var onScrollSettled: (Date) -> Void = { _ in }

    @State private var scrollDate: Date = .now
    @State private var axisDate: Date = .now
    @State private var debounceTask: Task<Void, Never>? = nil

    private var sorted: [DoseEntry] { entries.sorted { $0.date < $1.date } }
    private var dataStart: Date { entries.min(by: { $0.date < $1.date })?.date ?? .now }
    private var dataEnd: Date   { entries.max(by: { $0.date < $1.date })?.date ?? .now }

    private var visibleStart: Date { windowDuration != nil ? axisDate : dataStart }
    private var visibleEnd: Date {
        guard let windowDuration else { return dataEnd }
        return axisDate.addingTimeInterval(windowDuration)
    }
    private var visibleSpan: TimeInterval { visibleEnd.timeIntervalSince(visibleStart) }

    private func hourOfDay(_ date: Date) -> Double {
        let cal = Calendar.current
        return Double(cal.component(.hour, from: date)) + Double(cal.component(.minute, from: date)) / 60.0
    }

    private func normalizedTimeY(_ hour: Double) -> Double {
        let lo = yDomain.lowerBound
        let hi = yDomain.upperBound
        return (hour / 24.0) * (hi - lo) + lo
    }

    private var timeAxisValues: [Double] {
        [0.0, 6.0, 12.0, 18.0, 24.0].map { normalizedTimeY($0) }
    }

    var body: some View {
        VStack(spacing: 4) {
            Chart {
                ForEach(sorted) { e in
                    PointMark(
                        x: .value("Date", e.date),
                        y: .value("Dose", e.dose)
                    )
                    .foregroundStyle(Color.orange)
                    .symbolSize(50)

                    PointMark(
                        x: .value("Date", e.date),
                        y: .value("Time", normalizedTimeY(hourOfDay(e.date)))
                    )
                    .foregroundStyle(Color.teal.opacity(0.6))
                    .symbol(.diamond)
                    .symbolSize(30)
                }
            }
            .chartYScale(domain: yDomain)
            .smartChartXAxis(visibleStart: visibleStart, visibleEnd: visibleEnd, visibleSpan: visibleSpan)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                }
                AxisMarks(position: .trailing, values: timeAxisValues) { value in
                    AxisTick()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            let lo = yDomain.lowerBound
                            let hi = yDomain.upperBound
                            let hour = Int(((v - lo) / (hi - lo) * 24).rounded())
                            Text(String(format: "%02d:00", hour))
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartScrollWindow(windowDuration: windowDuration, visibleSpan: visibleSpan, scrollDate: $scrollDate, anchorDate: anchorDate)
            .onChange(of: scrollDate) { _, new in
                debounceTask?.cancel()
                debounceTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    axisDate = new
                    onScrollSettled(new)
                }
            }
            .onChange(of: anchorDate) { _, new in
                if let new { axisDate = new }
            }

            if let wd = windowDuration, anchorDate == nil {
                HStack {
                    Spacer()
                    Button {
                        let target = Date.now.addingTimeInterval(-wd)
                        scrollDate = target
                        axisDate = target
                    } label: {
                        Image(systemName: "arrow.right.to.line")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
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
    @Environment(\.modelContext) private var modelContext
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
                    LabeledContent("Time", value: formattedDateTime(entry.date))
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
                        try? modelContext.save()
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
    @State private var weeklySchedule: WeeklySchedule = .empty
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
                    HStack(spacing: 16) {
                        if !weeklySchedule.isEmpty {
                            Button {
                                applyTemplate(weeklySchedule, to: &days)
                            } label: {
                                Image(systemName: "wand.and.stars")
                            }
                        }
                        Button("Save") { save() }
                            .fontWeight(.semibold)
                    }
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
                weeklySchedule = UserDefaults.appGroup.weeklySchedule
                setupDays()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    focusedIndex = 0
                }
            }
        }
    }

    private func setupDays() {
        days = buildPlannedDays(startingAt: Calendar.current.startOfDay(for: .now), in: allDoses)
        applyTemplate(weeklySchedule, to: &days)
    }

    private func addNextDay(after index: Int) {
        let next = appendNextDayIfNeeded(after: index, days: &days, doses: allDoses)
        applyTemplate(weeklySchedule, to: &days)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focusedIndex = next }
    }

    private func save() {
        upsertPlannedDays(days, doses: allDoses, into: modelContext)
        try? modelContext.save()
        WidgetCenter.shared.reloadAllTimelines()
        dismiss()
    }
}
