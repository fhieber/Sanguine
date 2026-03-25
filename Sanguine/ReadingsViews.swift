import SwiftUI
import SwiftData
import Charts
import WidgetKit

// MARK: - Stats Range

enum StatsRange: String, CaseIterable {
    case lastMonth   = "1M"
    case last3Months = "3M"
    case last6Months = "6M"
    case lastYear    = "1Y"
    case yearToDate  = "YTD"
    case allTime     = "All"

    func cutoff() -> Date? {
        let cal = Calendar.current
        switch self {
        case .lastMonth:   return cal.date(byAdding: .month, value: -1, to: .now)
        case .last3Months: return cal.date(byAdding: .month, value: -3, to: .now)
        case .last6Months: return cal.date(byAdding: .month, value: -6, to: .now)
        case .lastYear:    return cal.date(byAdding: .year,  value: -1, to: .now)
        case .yearToDate:  return cal.startOfYear(for: .now)
        case .allTime:     return nil
        }
    }
}

private extension Calendar {
    func startOfYear(for date: Date) -> Date {
        let comps = dateComponents([.year], from: date)
        return self.date(from: comps) ?? date
    }
}

// MARK: - Readings Tab

struct ReadingsTab: View {
    @Query(sort: \Reading.recordedAt, order: .reverse) private var readings: [Reading]
    @Environment(\.modelContext) private var modelContext
    @State private var showingAdd = false
    @State private var visibleCount = 5
    @State private var selectedRange: StatsRange = .last6Months
    @State private var customRange: (start: Date, end: Date)? = nil
    @State private var showingCustomPicker = false
    @AppStorage("readingLowTarget", store: .appGroup) private var lowTarget: Double = 2.0
    @AppStorage("readingHighTarget", store: .appGroup) private var highTarget: Double = 3.0

    private var filtered: [Reading] {
        if let custom = customRange {
            return readings.filter { $0.recordedAt >= custom.start && $0.recordedAt <= custom.end }
        }
        guard let cutoff = selectedRange.cutoff() else { return readings }
        return readings.filter { $0.recordedAt >= cutoff }
    }

    private var stats: ReadingStats { ReadingStats(readings: filtered, lowTarget: lowTarget, highTarget: highTarget) }

    private var historyRows: [Reading] {
        Array(filtered.prefix(visibleCount))
    }

    var body: some View {
        NavigationStack {
            List {
                if filtered.count >= 2 {
                    Section {
                        ReadingChartView(readings: filtered, lowTarget: lowTarget, highTarget: highTarget)
                            .frame(height: 220)
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    } header: {
                        rangePicker
                    }
                }

                if !readings.isEmpty {
                    Section {
                        ReadingStatsGrid(stats: stats)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    } header: {
                        Text("Statistics")
                    }
                }

                Section {
                    if readings.isEmpty {
                        ContentUnavailableView(
                            "No Measurements",
                            systemImage: "chart.xyaxis.line",
                            description: Text("Tap + to record your first reading.")
                        )
                    } else {
                        ForEach(historyRows) { r in
                            NavigationLink(destination: ReadingDetailView(reading: r)) {
                                ReadingRowView(reading: r, stats: stats)
                            }
                        }
                        .onDelete(perform: delete)
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
            .navigationTitle("Readings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingAdd) { AddReadingView() }
            .onAppear {
                if UserDefaults.standard.bool(forKey: "navigateToAddReading") {
                    UserDefaults.standard.removeObject(forKey: "navigateToAddReading")
                    showingAdd = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToAddReading)) { _ in
                showingAdd = true
            }
            .sheet(isPresented: $showingCustomPicker) {
                DateRangePickerSheet(customRange: $customRange)
            }
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
                    ForEach(StatsRange.allCases, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
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

    private func delete(at offsets: IndexSet) {
        for i in offsets { modelContext.delete(historyRows[i]) }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - Reading Row

struct ReadingRowView: View {
    let reading: Reading
    let stats: ReadingStats

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(stats.isInRange(reading) ? Color.green : Color.red)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.1f", reading.value))
                    .font(.headline)
                Text(reading.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !reading.note.isEmpty {
                    Text(reading.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(stats.isInRange(reading) ? "In range" : "Out of range")
                .font(.caption)
                .foregroundStyle(stats.isInRange(reading) ? .green : .red)
        }
    }
}

// MARK: - Reading Detail / Edit

struct ReadingDetailView: View {
    @Bindable var reading: Reading
    @Query(sort: \DoseEntry.date, order: .reverse) private var allDoses: [DoseEntry]

    private var priorDoses: [DoseEntry] {
        Array(allDoses.filter { $0.date < reading.recordedAt }.prefix(6).reversed())
    }

    var body: some View {
        Form {
            Section("Value") {
                LabeledContent("Reading", value: String(format: "%.1f", reading.value))
                LabeledContent("Date", value: reading.recordedAt.formatted(date: .long, time: .shortened))
            }
            if !priorDoses.isEmpty {
                Section {
                    ForEach(priorDoses) { entry in
                        HStack {
                            Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.dose.doseFormatted)
                                .fontWeight(.medium)
                            if !entry.note.isEmpty {
                                Text("· \(entry.note)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                } header: {
                    Text("Prior 6 Doses")
                } footer: {
                    Text("Doses taken before this reading")
                        .font(.caption2)
                }
            }
            Section("Notes") {
                TextField("Notes", text: $reading.note, axis: .vertical)
                    .lineLimit(3...8)
            }
        }
        .navigationTitle("Reading Detail")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Add Reading & Plan

struct AddReadingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \DoseEntry.date) private var allDoses: [DoseEntry]

    @State private var valueText = ""
    @State private var date = Date()
    @State private var note = ""
    @State private var days: [PlannedDay] = []
    @FocusState private var focusedDayIndex: Int?
    @FocusState private var valueFieldFocused: Bool

    private var parsedValue: Double? {
        Double(valueText.replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reading Value") {
                    TextField("e.g. 2.5", text: $valueText)
                        .keyboardType(.decimalPad)
                        .font(.title2.monospacedDigit())
                        .focused($valueFieldFocused)
                }
                Section("Date & Time") {
                    DatePicker("Recorded", selection: $date, in: ...Date.now, displayedComponents: [.date, .hourAndMinute])
                }
                Section("Notes (optional)") {
                    TextField("Any notes...", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }
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
                                .focused($focusedDayIndex, equals: i)
                                .submitLabel(.next)
                                .onSubmit { addNextDay(after: i) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { focusedDayIndex = i }
                    }
                } header: {
                    Text("Plan Doses")
                } footer: {
                    Text("Pre-filled days have an existing dose. Press Next to add the following day.")
                }
            }
            .navigationTitle("Add Reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(parsedValue == nil)
                        .fontWeight(.semibold)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if valueFieldFocused {
                        Spacer()
                        Button("Done") { valueFieldFocused = false }
                    } else {
                        Button("Previous") {
                            if let i = focusedDayIndex, i > 0 {
                                focusedDayIndex = i - 1
                            }
                        }
                        .disabled((focusedDayIndex ?? 0) == 0)
                        Spacer()
                        Button("Next") {
                            if let i = focusedDayIndex {
                                addNextDay(after: i)
                            }
                        }
                    }
                }
            }
            .onAppear { setupDays() }
            .onChange(of: date) { setupDays() }
        }
    }

    private func setupDays() {
        days = buildPlannedDays(startingAt: Calendar.current.startOfDay(for: date), in: allDoses)
    }

    private func addNextDay(after index: Int) {
        let next = appendNextDayIfNeeded(after: index, days: &days, doses: allDoses)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focusedDayIndex = next }
    }

    private func save() {
        guard let v = parsedValue else { return }
        modelContext.insert(Reading(value: v, recordedAt: date, note: note))
        upsertPlannedDays(days, doses: allDoses, into: modelContext)
        WidgetCenter.shared.reloadAllTimelines()
        dismiss()
    }
}

// MARK: - Reading Chart

struct ReadingChartView: View {
    let readings: [Reading]
    let lowTarget: Double
    let highTarget: Double

    private var sorted: [Reading] { readings.sorted { $0.recordedAt < $1.recordedAt } }

    var body: some View {
        Chart {
            // Target range band
            if let first = sorted.first, let last = sorted.last {
                RectangleMark(
                    xStart: .value("Start", first.recordedAt),
                    xEnd: .value("End", last.recordedAt),
                    yStart: .value("Low", lowTarget),
                    yEnd: .value("High", highTarget)
                )
                .foregroundStyle(Color.green.opacity(0.08))
            }

            // Target range lines
            RuleMark(y: .value("Low", lowTarget))
                .foregroundStyle(Color.green.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .annotation(position: .trailing, alignment: .leading) {
                    Text(String(format: "%.1f", lowTarget))
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                }

            RuleMark(y: .value("High", highTarget))
                .foregroundStyle(Color.green.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .annotation(position: .trailing, alignment: .leading) {
                    Text(String(format: "%.1f", highTarget))
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                }

            // Line
            ForEach(sorted) { r in
                LineMark(
                    x: .value("Date", r.recordedAt),
                    y: .value("Reading", r.value)
                )
                .foregroundStyle(Color.blue.opacity(0.6))
                .interpolationMethod(.catmullRom)
            }

            // Points
            ForEach(sorted) { r in
                PointMark(
                    x: .value("Date", r.recordedAt),
                    y: .value("Reading", r.value)
                )
                .foregroundStyle(r.value >= lowTarget && r.value <= highTarget ? Color.green : Color.red)
                .symbolSize(40)
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
        let values = readings.map(\.value) + [lowTarget, highTarget]
        let lo = (values.min() ?? 1.0) - 0.5
        let hi = (values.max() ?? 4.0) + 0.5
        return lo...hi
    }
}

// MARK: - Statistics Grid

struct ReadingStatsGrid: View {
    let stats: ReadingStats

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatCard(
                title: "Latest",
                value: stats.latest.map { String(format: "%.1f", $0.value) } ?? "—",
                subtitle: stats.latest.map { $0.recordedAt.formatted(date: .abbreviated, time: .omitted) }
            )
            StatCard(
                title: "Average",
                value: stats.average.map { String(format: "%.2f", $0) } ?? "—",
                subtitle: stats.stdDev.map { "±\(String(format: "%.2f", $0))" }
            )
            StatCard(
                title: "Min",
                value: stats.minimum.map { String(format: "%.1f", $0) } ?? "—"
            )
            StatCard(
                title: "Max",
                value: stats.maximum.map { String(format: "%.1f", $0) } ?? "—"
            )
            StatCard(
                title: "Time in Range",
                value: stats.timeInRangePercent.map { String(format: "%.0f%%", $0) } ?? "—",
                valueColor: timeInRangeColor
            )
            StatCard(
                title: "Readings",
                value: "\(stats.count)"
            )
        }
    }

    private var timeInRangeColor: Color {
        guard let pct = stats.timeInRangePercent else { return .primary }
        return pct >= 70 ? .green : (pct >= 50 ? .orange : .red)
    }
}

// MARK: - Date Range Picker Sheet

struct DateRangePickerSheet: View {
    @Binding var customRange: (start: Date, end: Date)?
    @Environment(\.dismiss) private var dismiss

    @State private var start: Date = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var end: Date = .now

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("From", selection: $start, in: ...end, displayedComponents: .date)
                    DatePicker("To",   selection: $end,   in: start..., displayedComponents: .date)
                }
            }
            .navigationTitle("Custom Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") {
                        customRange = (start: start, end: end)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            if let existing = customRange {
                start = existing.start
                end   = existing.end
            }
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var valueColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.monospacedDigit())
                .fontWeight(.semibold)
                .foregroundStyle(valueColor)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
