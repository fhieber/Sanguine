import SwiftUI
import SwiftData
import Charts
import WidgetKit

// MARK: - Stats Range

enum StatsRange: String, CaseIterable, ChartRange {
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
    /// Updated ~300ms after panning stops via ReadingChartView.onScrollSettled.
    /// All stats, history, and trend computation use this to avoid re-rendering on every scroll frame.
    @State private var statsScrollDate: Date = .now
    @State private var showTrend = false
    @State private var trendPoints: [TrendPoint] = []
    @State private var trendDegree: Int? = nil
    @AppStorage("readingLowTarget", store: .appGroup) private var lowTarget: Double = 2.0
    @AppStorage("readingHighTarget", store: .appGroup) private var highTarget: Double = 3.0

    private var chartWindowDuration: TimeInterval? {
        customRange.map { $0.end.timeIntervalSince($0.start) } ?? selectedRange.windowDuration
    }

    /// Non-nil for custom ranges and YTD, which have a fixed start date rather than a rolling offset.
    /// Passing an anchorDate to chartScrollWindow suppresses its onChange(of: windowDuration) handler,
    /// preventing a feedback loop where YTD's ever-growing windowDuration triggers scroll updates every frame.
    private var chartAnchorDate: Date? {
        if let start = customRange?.start { return start }
        if selectedRange == .yearToDate { return Calendar.current.startOfYear(for: .now) }
        return nil
    }

    private var filtered: [Reading] {
        if let wd = chartWindowDuration {
            let end = statsScrollDate.addingTimeInterval(wd)
            return readings.filter { $0.recordedAt >= statsScrollDate && $0.recordedAt <= end }
        }
        return Array(readings)
    }

    private var stats: ReadingStats { ReadingStats(readings: filtered, lowTarget: lowTarget, highTarget: highTarget) }

    private var dataRangeLabel: String {
        let start: Date
        let end: Date
        if let wd = chartWindowDuration {
            start = statsScrollDate
            end = statsScrollDate.addingTimeInterval(wd)
        } else {
            guard let s = readings.map(\.recordedAt).min(),
                  let e = readings.map(\.recordedAt).max() else { return "" }
            start = s; end = e
        }
        let cal = Calendar.current
        if cal.component(.year, from: start) == cal.component(.year, from: end) {
            return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
        } else {
            return "\(start.formatted(.dateTime.month(.abbreviated).year())) – \(end.formatted(.dateTime.month(.abbreviated).year()))"
        }
    }

    private var historyRows: [Reading] {
        Array(filtered.prefix(visibleCount))
    }

    var body: some View {
        NavigationStack {
            List {
                if readings.count >= 2 {
                    Section {
                        ReadingChartView(
                            readings: Array(readings),
                            lowTarget: lowTarget,
                            highTarget: highTarget,
                            windowDuration: chartWindowDuration,
                            anchorDate: chartAnchorDate,
                            trendPoints: trendPoints,
                            trendDegree: trendDegree,
                            showTrend: $showTrend,
                            onScrollSettled: { date in statsScrollDate = date }
                        )
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
            .onChange(of: statsScrollDate) { _, _ in
                if showTrend { recomputeTrend() }
            }
            .onChange(of: showTrend) { _, on in
                if on { recomputeTrend() } else { trendPoints = []; trendDegree = nil }
            }
        }
    }

    private func recomputeTrend() {
        guard let t = ReadingTrend.compute(from: filtered) else {
            trendPoints = []; trendDegree = nil; return
        }
        let steps = 40 // sufficient for smooth curve on iPhone; revisit for wider displays
        trendDegree = t.fit.degree
        trendPoints = (0 ..< steps).map { i in
            let fraction = Double(i) / Double(steps - 1)
            let date = t.t0.addingTimeInterval(t.tScale * fraction)
            return TrendPoint(id: i, date: date, value: t.evaluate(at: date))
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
                    Text("Doses applied before this reading")
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
        try? modelContext.save()
        WidgetCenter.shared.reloadAllTimelines()
        NotificationManager.shared.removeDeliveredReadingReminder()
        dismiss()
    }
}

// MARK: - Reading Chart

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in p.move(to: CGPoint(x: rect.minX, y: rect.midY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
    }
}

struct TrendPoint: Identifiable {
    let id: Int
    let date: Date
    let value: Double
}

struct ReadingChartView: View {
    let readings: [Reading]
    let lowTarget: Double
    let highTarget: Double
    let windowDuration: TimeInterval?
    var anchorDate: Date? = nil
    /// Precomputed by parent using debounced scroll position — empty when trend is hidden.
    let trendPoints: [TrendPoint]
    let trendDegree: Int?
    @Binding var showTrend: Bool
    /// Called once panning settles (~300ms after the user lifts their finger).
    var onScrollSettled: (Date) -> Void = { _ in }

    @State private var scrollDate: Date = .now
    /// Debounced copy of scrollDate — drives axis labels and the jump-to-now button
    /// so neither redraws on every scroll frame.
    @State private var axisDate: Date = .now
    @State private var debounceTask: Task<Void, Never>? = nil

    private var sorted: [Reading] { readings.sorted { $0.recordedAt < $1.recordedAt } }

    private var dataStart: Date { readings.min(by: { $0.recordedAt < $1.recordedAt })?.recordedAt ?? .now }
    private var dataEnd: Date   { readings.max(by: { $0.recordedAt < $1.recordedAt })?.recordedAt ?? .now }

    private var visibleStart: Date { windowDuration != nil ? axisDate : dataStart }
    private var visibleEnd: Date {
        guard let windowDuration else { return dataEnd }
        return axisDate.addingTimeInterval(windowDuration)
    }

    private var visibleSpan: TimeInterval { visibleEnd.timeIntervalSince(visibleStart) }

    // Extracted to its own property so the compiler can type-check body and chart
    // independently — the combined expression was too large for the type checker.
    private var chartView: some View {
        Chart {
            // Target range band
            RectangleMark(
                xStart: .value("Start", dataStart),
                xEnd:   .value("End",   dataEnd),
                yStart: .value("Low",   lowTarget),
                yEnd:   .value("High",  highTarget)
            )
            .foregroundStyle(Color.green.opacity(0.08))

            // Target range lines
            RuleMark(y: .value("Low", lowTarget))
                .foregroundStyle(Color.green.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))

            RuleMark(y: .value("High", highTarget))
                .foregroundStyle(Color.green.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))

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

            // Polynomial trendline — drawn last so it appears on top
            if !trendPoints.isEmpty {
                ForEach(trendPoints) { pt in
                    LineMark(
                        x: .value("Date", pt.date),
                        y: .value("Trend", pt.value),
                        series: .value("Series", "Trend")
                    )
                    .foregroundStyle(Color.orange.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .interpolationMethod(.linear)
                }
            }
        }
        .chartYScale(domain: yDomain)
        .smartChartXAxis(visibleStart: visibleStart, visibleEnd: visibleEnd, visibleSpan: visibleSpan)
        .chartYAxis {
            AxisMarks(position: .leading)
            // Target range labels pinned to the trailing axis — always visible
            // regardless of scroll position (unlike .annotation(position: .trailing)
            // on a RuleMark, which is placed at the data domain's trailing edge and
            // scrolls off-screen when the user pans left).
            AxisMarks(values: [lowTarget, highTarget], position: .trailing) { value in
                AxisValueLabel(anchor: .leading) {
                    if let v = value.as(Double.self) {
                        Text(String(format: "%.1f", v))
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                    }
                }
            }
        }
        .chartLegend(.hidden)
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
            // Snap axis labels immediately when the user switches range
            if let new { axisDate = new }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
        chartView

        HStack {
            HStack(spacing: 4) {
                Rectangle().fill(Color.blue.opacity(0.6)).frame(width: 16, height: 2)
                Text("Reading").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Line().stroke(Color.orange.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [4, 3])).frame(width: 16, height: 2)
                Text(trendDegree.map { trendLabel($0) } ?? "Trend").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showTrend.toggle()
            } label: {
                Label(showTrend ? "Hide Trend" : "Trend",
                      systemImage: showTrend ? "chart.line.uptrend.xyaxis.circle.fill" : "chart.line.uptrend.xyaxis.circle")
                    .font(.caption2)
                    .foregroundStyle(showTrend ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            if let wd = windowDuration, anchorDate == nil {
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

    private func trendLabel(_ degree: Int) -> String {
        switch degree {
        case 1: return "Linear trend"
        case 2: return "Quadratic trend"
        case 3: return "Cubic trend"
        default: return "Quartic trend"
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
                value: stats.minimum.map { String(format: "%.1f", $0) } ?? "—",
                subtitle: stats.minimumReading.map { $0.recordedAt.formatted(date: .abbreviated, time: .omitted) }
            )
            StatCard(
                title: "Max",
                value: stats.maximum.map { String(format: "%.1f", $0) } ?? "—",
                subtitle: stats.maximumReading.map { $0.recordedAt.formatted(date: .abbreviated, time: .omitted) }
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
