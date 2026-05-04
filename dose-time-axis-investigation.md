# Dose Chart: Time-of-Day Secondary Axis — Investigation Summary

## Goal

Add a secondary Y-axis to the dose chart in `DoseViews.swift` (`DoseChartView`) that shows the time of day (0–24h clock) when each dose was taken. Orange dots already show dose amount on the primary Y-axis; teal diamond marks should show intake time on a secondary axis overlaid on the same chart.

The data is already there: every historical `DoseEntry` (`isPlanned != true`) has a full `Date` timestamp. Doses marked via "Applied" use `.now`; CSV date-only imports default to 18:00 CET (changed from 08:00 to match the app's reminder default — this change is on master).

---

## Repository & Branch State

- **Repo**: `fhieber/Sanguine`
- **Main branch**: `master`
- **Relevant PRs**:
  - #56 — First attempt (merged, then reverted by user as #58 — crashed)
  - #59 — Second attempt with crash fix (merged, still crashed)
  - #60 — Revert of #59 (merged, master is clean again)
- **What's on master now**: Original `DoseChartView` (no secondary axis), CSV default time updated to 18:00 CET

---

## Key Files

| File | Role |
|------|------|
| `Sanguine/DoseViews.swift` | Contains `DoseChartView` — the chart to modify |
| `Sanguine/ChartHelpers.swift` | `chartScrollWindow` and `smartChartXAxis` shared extensions |
| `Sanguine/CSVImporter.swift` | `dateAt6pmCET` sets default time for date-only CSV imports (18:00) |
| `Sanguine/Models.swift` | `DoseEntry` model — `date: Date`, `dose: Double`, `isPlanned: Bool?` |

---

## What Was Attempted

### Attempt 1 — Dual `AxisMarks` in `chartYAxis` (crashed immediately)

```swift
.chartYAxis {
    AxisMarks(position: .leading, values: .automatic) { _ in
        AxisGridLine(); AxisTick(); AxisValueLabel()
    }
    AxisMarks(position: .trailing, values: timeAxisValues) { value in
        AxisTick()
        AxisValueLabel {
            // label computation here
        }
    }
}
```

**Result**: Hard crash on app startup before any view rendered. Diagnosis: SwiftUI Charts does not support mixing `AxisMarks(position: .leading)` and `AxisMarks(position: .trailing)` in the same `chartYAxis` block at runtime (even though it compiles).

---

### Attempt 2 — `chartOverlay` for trailing labels (also crashed)

Replaced the dual `AxisMarks` with:

```swift
.chartYAxis {
    AxisMarks(position: .leading)   // restored to original
}
.chartOverlay { proxy in
    GeometryReader { geo in
        ZStack(alignment: .topLeading) {
            ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                let yVal = normalizedTimeY(Double(hour))
                if let y = proxy.position(forY: yVal) {
                    Text("\(hour):00")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .position(x: geo.size.width - 16, y: y)
                }
            }
        }
    }
}
```

The time PointMarks in the chart body were kept alongside the existing dose marks:

```swift
ForEach(sorted) { e in
    // existing orange dose mark
    PointMark(x: .value("Date", e.date), y: .value("Dose", e.dose))
        .foregroundStyle(Color.orange).symbolSize(50)

    // new teal time mark (normalized to dose Y scale)
    PointMark(x: .value("Date", e.date), y: .value("Time", normalizedTimeY(hourOfDay(e.date))))
        .foregroundStyle(Color.teal.opacity(0.6))
        .symbol(.diamond).symbolSize(30)
}
```

**Result**: Still crashed on startup before any view rendered. Crash log was never captured.

---

## Helper Code (mathematically safe, not the crash source)

```swift
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

// existing yDomain — never degenerate (lo always < hi)
private var yDomain: ClosedRange<Double> {
    let values = entries.map(\.dose)
    let lo = max(0, (values.min() ?? 0) - 0.5)
    let hi = (values.max() ?? 2) + 0.5
    return lo...hi
}
```

---

## Crash Hypothesis

The crash is **not** in the helper logic. Most likely cause:

### Primary suspect: Two `PointMark` series per `ForEach` iteration

Having two marks per iteration with different Y value names (`"Dose"` and `"Time"`) may cause SwiftUI Charts to attempt building a legend or internal series grouping that fails at render time. SwiftUI Charts appears sensitive to multiple named value series on the same axis within a single `ForEach`.

### Secondary suspect: `chartOverlay` + `chartScrollWindow` interaction

The chart uses `chartScrollableAxes(.horizontal)` and `chartScrollPosition(x: scrollDate)` via the `chartScrollWindow` helper in `ChartHelpers.swift`. The `chartOverlay` proxy may have undefined behaviour in a scrollable chart context — `proxy.position(forY:)` may not be valid during the initial render pass of a scrollable chart.

### Tertiary suspect: iOS/Charts framework version bug

The combination may be hitting a known or unknown bug in a specific iOS/Charts version. No simulator was available in this session to test.

---

## Recommended Next Steps (for laptop session with Xcode)

1. **Get the crash log first** — build and run on device or simulator, capture the full stack trace. The top frame will immediately identify whether it's inside Charts' rendering engine, a layout assertion, or the overlay proxy.

2. **Isolate the two changes**:
   - Try adding ONLY the second `PointMark` (time marks) with NO `chartOverlay` — just teal diamonds. If this crashes, the dual-series approach is the problem.
   - If that works, add the `chartOverlay`. If that crashes, the issue is overlay + scrollable chart.

3. **Alternative if dual PointMark crashes**: Use a completely separate `Chart` view below the dose chart (in a `VStack`) with its own Y axis showing only time-of-day (0–24). This avoids all dual-axis complexity entirely. The `onScrollSettled` callback already exists and could be used to sync the X scroll position between the two charts.

4. **Alternative if overlay crashes**: Draw the time axis labels as a plain `VStack` with `Spacer()` separators placed to the right of the chart in an `HStack`, avoiding `ChartProxy` entirely. Positions won't be pixel-perfect but will be close enough for a 0/6/12/18/24 scale.

---

## Chart Architecture Context

`DoseChartView` lives inside a `List` section in `DoseTab`:

```swift
DoseChartView(
    entries: historical,          // [DoseEntry] where isPlanned != true
    windowDuration: chartWindowDuration,
    anchorDate: customRange?.start,
    onScrollSettled: { date in statsScrollDate = date }
)
.frame(height: 220)
.listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
```

The `chartScrollWindow` helper (`ChartHelpers.swift`) applies:
- `.chartScrollableAxes(.horizontal)` (when `windowDuration != nil`)
- `.chartXVisibleDomain(length: windowDuration)`
- `.chartScrollPosition(x: scrollDate)`

This scrollable + List context may be relevant to the crash.
