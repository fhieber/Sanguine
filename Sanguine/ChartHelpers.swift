import SwiftUI
import Charts

// MARK: - Range protocol

/// Any enum that can produce a cutoff date gets `windowDuration` for free.
protocol ChartRange {
    func cutoff() -> Date?
}

extension ChartRange {
    var windowDuration: TimeInterval? {
        guard let cutoff = cutoff() else { return nil }
        return Date.now.timeIntervalSince(cutoff)
    }
}

// MARK: - Shared chart scroll + x-axis helpers

extension View {
    /// Applies horizontal scroll modifiers and lifecycle handlers shared by all sliding-window charts.
    func chartScrollWindow(
        windowDuration: TimeInterval?,
        visibleSpan: TimeInterval,
        scrollDate: Binding<Date>,
        anchorDate: Date?
    ) -> some View {
        self
            .chartScrollableAxes(windowDuration != nil ? .horizontal : [])
            .chartXVisibleDomain(length: windowDuration ?? visibleSpan)
            .chartScrollPosition(x: scrollDate)
            .onAppear {
                guard let windowDuration else { return }
                scrollDate.wrappedValue = anchorDate ?? Date.now.addingTimeInterval(-windowDuration)
            }
            .onChange(of: anchorDate) { _, new in
                if let new { scrollDate.wrappedValue = new }
            }
            .onChange(of: windowDuration) { old, new in
                guard let new, anchorDate == nil else { return }
                let center = scrollDate.wrappedValue.addingTimeInterval((old ?? new) / 2)
                scrollDate.wrappedValue = center.addingTimeInterval(-new / 2)
            }
    }

    /// Applies a boundary x-axis: always labels the left and right visible edges so the
    /// current range is immediately obvious, plus unlabeled intermediate gridlines for context.
    func smartChartXAxis(visibleStart: Date, visibleEnd: Date, visibleSpan: TimeInterval) -> some View {
        let days = visibleSpan / 86400
        let spansYears = Calendar.current.component(.year, from: visibleStart) !=
                         Calendar.current.component(.year, from: visibleEnd)
        let fmt: Date.FormatStyle = spansYears
            ? .dateTime.month(.abbreviated).day().year()
            : .dateTime.month(.abbreviated).day()
        // Intermediate stride — gridlines only, no labels
        let stride: Calendar.Component = days > 60 ? .month : days > 14 ? .weekOfYear : .day
        return self.chartXAxis {
            AxisMarks(values: [visibleStart, visibleEnd]) { value in
                AxisGridLine()
                AxisValueLabel(anchor: (value.as(Date.self) ?? .distantFuture) <= visibleStart ? .topLeading : .topTrailing) {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(fmt)).font(.caption2)
                    }
                }
            }
            // Intermediate gridlines for visual reference; skip for ≤2d where boundaries are close enough
            if days > 2 {
                AxisMarks(values: .stride(by: stride)) {
                    AxisGridLine()
                }
            }
        }
    }
}
