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
        let raw = Date.now.timeIntervalSince(cutoff)
        // Round to the nearest day so that sub-second drift in Date.now doesn't produce
        // a different Double on every render frame. Without this, onChange(of: windowDuration)
        // in chartScrollWindow fires every frame during panning and re-sets scrollDate,
        // causing jitter.
        return (raw / 86400).rounded() * 86400
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
        let midpoint: Date? = days > 2 ? visibleStart.addingTimeInterval(visibleSpan / 2) : nil
        let flanking: [Date] = days > 2 ? [
            visibleStart.addingTimeInterval(visibleSpan / 4),
            visibleStart.addingTimeInterval(visibleSpan * 3 / 4)
        ] : []
        return self.chartXAxis {
            AxisMarks(values: [visibleStart, visibleEnd]) { value in
                AxisGridLine()
                AxisValueLabel(anchor: (value.as(Date.self) ?? .distantFuture) <= visibleStart ? .topLeading : .topTrailing) {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(fmt)).font(.caption2)
                    }
                }
            }
            if let midpoint {
                AxisMarks(values: [midpoint]) { _ in
                    AxisGridLine()
                    AxisValueLabel(anchor: .top) {
                        Text(midpoint.formatted(fmt)).font(.caption2)
                    }
                }
            }
            if !flanking.isEmpty {
                AxisMarks(values: flanking) {
                    AxisGridLine()
                }
            }
        }
    }
}
