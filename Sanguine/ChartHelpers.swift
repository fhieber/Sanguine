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

    /// Applies a smart date x-axis: weekly ticks for ≤60d, monthly for >60d,
    /// month+year when the visible window crosses a calendar year boundary.
    func smartChartXAxis(scrollDate: Date, visibleEnd: Date, visibleSpan: TimeInterval) -> some View {
        let days = visibleSpan / 86400
        let spansYears = Calendar.current.component(.year, from: scrollDate) !=
                         Calendar.current.component(.year, from: visibleEnd)
        return self.chartXAxis {
            if spansYears {
                AxisMarks(values: .stride(by: .month)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.month(.abbreviated).year())).font(.caption2)
                        }
                    }
                }
            } else if days > 60 {
                AxisMarks(values: .stride(by: .month)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.month(.abbreviated))).font(.caption2)
                        }
                    }
                }
            } else if days > 7 {
                AxisMarks(values: .stride(by: .weekOfYear)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.month(.abbreviated).day())).font(.caption2)
                        }
                    }
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.month(.abbreviated).day())).font(.caption2)
                        }
                    }
                }
            }
        }
    }
}
