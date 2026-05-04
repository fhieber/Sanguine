# Dose Chart: Time-of-Day Secondary Axis — Investigation Summary

## Goal

Add a secondary Y-axis to the dose chart in `DoseViews.swift` (`DoseChartView`) that shows the time of day (0–24h clock) when each dose was taken. Orange dots already show dose amount on the primary Y-axis; teal diamond marks should show intake time on a secondary axis overlaid on the same chart.

The data is already there: every historical `DoseEntry` (`isPlanned != true`) has a full `Date` timestamp. Doses marked via "Applied" use `.now`; CSV date-only imports default to 08:00 CET (we also tried changing this to 18:00 to match the app's reminder default, but that was also reverted as part of the crash revert).

---

## Repository & Branch State

- **Repo**: `fhieber/Sanguine`
- **Main branch**: `master`
- **Current master**: Clean, with the feature fully reverted (PR #60 pending merge)
- **Relevant PRs**:
  - #56 — First attempt (merged, then reverted by user as #58 — crashed)
  - #59 — Second attempt with crash fix (merged, still crashed)
  - #60 — Revert of #59 (open, should be merged to restore stability)

---

## Key Files

| File | Role |
|------|------|
| `Sanguine/DoseViews.swift` | Contains `DoseChartView` — the chart to modify |
| `Sanguine/ChartHelpers.swift` | `chartScrollWindow` and `smartChartXAxis` shared extensions |
| `Sanguine/CSVImporter.swift` | `dateAt8amCET` sets default time for date-only CSV imports |
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

The time PointMarks in the chart body were kept:

```swift
ForEach(sorted) { e in
    // existing orange dose mark
    PointMark(x: .value("Date", e.date), y: .value("Dose", e.dose))
        .foregroundStyle(Color.orange).symbolSize(50)

    // new teal time mark
    PointMark(x: .value("Date", e.date), y: .value("Time", normalizedTimeY(hourOfDay(e.date))))
        .foregroundStyle(Color.teal.opacity(0.6))
        .symbol(.diamond).symbolSize(30)
}
```

**Result**: Still crashed on startup before any view rendered. The crash log was never obtained.

---

## Helper Code (verified correct, not the crash source)

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

private var yDomain: ClosedRange<Double> {
    let values = entries.map(\.dose)
    let lo = max(0, (values.min() ?? 0) - 0.5)
    let hi = (values.max() ?? 2) + 0.5
    return lo...hi
}
```

These helpers are mathematically safe: `yDomain` never produces a degenerate range (lo always < hi), `hourOfDay` always returns 0.0–23.99, `normalizedTimeY` maps strictly into yDomain.

---

## Crash Hypothesis

The crash is **not** in the helper logic. The most likely candidates:

### Primary suspect: Two `PointMark` series per `ForEach` iteration

Having two marks per iteration with different Y value names (`"Dose"` and `"Time"`) may cause SwiftUI Charts to attempt to build a legend or internal series grouping that fails at render time. SwiftUI Charts appears to be sensitive to having multiple named value series on the same axis from within a single `ForEach`.

### Secondary suspect: `chartOverlay` + `chartScrollWindow` interaction

The chart uses `chartScrollableAxes(.horizontal)` and `chartScrollPosition(x: scrollDate)` via the `chartScrollWindow` helper in `ChartHelpers.swift`. The `chartOverlay` proxy might have undefined behavior when the chart is in a scrollable configuration — specifically, `proxy.position(forY:)` in a scrollable chart context.

### Tertiary suspect: SwiftUI Charts version / iOS version sensitivity

The crash reproduces on the user's device but could not be reproduced in a build environment (no simulator available in this session). The combination may be hitting a known or unknown bug in a specific iOS/Charts framework version.

---

## Recommended Next Steps for Laptop Session

1. **Get the crash log first**: Build and run on device or simulator, capture the full stack trace. The top frame will immediately identify whether it's inside Charts rendering, a layout engine assertion, or the overlay.

2. **Isolate the two changes**:
   - Try adding ONLY the second `PointMark` (time marks) with NO `chartOverlay` and NO `timeAxisValues` — just the teal diamond marks at normalized positions. If this alone crashes, the issue is the dual-series approach.
   - If that works, add the `chartOverlay`. If that crashes, the issue is overlay + scrollable chart.

3. **Alternative approach if dual PointMark crashes**: Use a completely separate `Chart` view below the dose chart (in a `VStack`) with its own Y axis showing only time-of-day (0–24). This avoids all dual-axis complexity. The two charts share the same X axis data (dates) but have independent Y scales. The `DoseChartView` already has `onScrollSettled` callback infrastructure that could sync the scroll position between two charts.

4. **Alternative approach if overlay crashes**: Draw the time axis labels as a plain SwiftUI `VStack` with `Spacer()` separators positioned mathematically to approximate the chart's Y scale positions, placed to the right of the chart in an `HStack`. Avoids `ChartProxy` entirely.

---

## Chart Architecture Context

`DoseChartView` is used in `DoseTab` (`DoseViews.swift`) with:
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

The chart lives inside a `List` section. The `chartScrollWindow` helper (in `ChartHelpers.swift`) applies:
- `.chartScrollableAxes(.horizontal)` (when `windowDuration != nil`)
- `.chartXVisibleDomain(length: windowDuration)`
- `.chartScrollPosition(x: scrollDate)`

This scrollable context may be relevant to the crash.
