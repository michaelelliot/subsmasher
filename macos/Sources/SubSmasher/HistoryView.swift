import AppKit
import Charts
import SubSmasherCore
import SwiftUI

/// Every profile's weekly usage over the chosen range on one chart, in a window opened from the menu.
struct HistoryView: View {
    let model: UsageModel
    /// A time to show the readout at whenever the pointer isn't over the plot, for the README's screenshots.
    var pointer: Date? = nil
    @AppStorage(HistoryView.rangeKey) private var range = HistoryRange.week

    static let rangeKey = "historyRange"

    var body: some View {
        let now = Date.now
        let start = now.addingTimeInterval(-range.span)
        let accounts = model.reports.map { report in
            ChartAccount(
                id: report.id, name: report.displayName,
                color: Color(hex: model.historyColors[report.id]) ?? .accentColor,
                // About a point per pixel at the window's usual width.
                lines: model.history.lines(
                    for: report.id, since: start, resolution: range.span / 500, gap: range.gap.seconds))
        }
        VStack(alignment: .leading, spacing: 12) {
            Picker("Range", selection: $range) {
                ForEach(HistoryRange.allCases) { range in
                    Text(range.rawValue).tag(range).help(range.title)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            HistoryChart(
                accounts: accounts.filter { !model.hiddenFromHistory.contains($0.id) }, history: model.history,
                range: range, start: start, now: now, pointer: pointer
            )
            .overlay {
                if accounts.allSatisfy(\.lines.isEmpty) {
                    Text("No usage recorded in this period")
                        .foregroundStyle(.secondary)
                }
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), spacing: 12, alignment: .leading)], alignment: .leading,
                spacing: 6
            ) {
                ForEach(accounts) { account in
                    legendItem(account)
                }
            }
            Text(
                "Each account's weekly limit across all models, saved at every refresh. Grey dashes join readings "
                    + "more than \(range.gap.text) apart, where there's no data."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(minWidth: 460)
    }

    private func legendItem(_ account: ChartAccount) -> some View {
        HStack(spacing: 6) {
            ColorPicker(
                "Line colour for \(account.name)",
                selection: Binding(
                    get: { account.color },
                    set: { color in
                        if let hex = color.hex { model.setHistoryColor(hex, for: account.id) }
                    }),
                supportsOpacity: false
            )
            .labelsHidden()
            .controlSize(.small)
            .help("Change \(account.name)'s colour")
            Toggle(
                account.name,
                isOn: Binding(
                    get: { !model.hiddenFromHistory.contains(account.id) },
                    set: { model.setShownInHistory($0, for: account.id) })
            )
            .toggleStyle(.checkbox)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(account.lines.isEmpty ? "No usage recorded in this period" : account.name)
            .accessibilityHint(account.lines.isEmpty ? "No usage recorded in this period" : "")
        }
        .foregroundStyle(account.lines.isEmpty ? .secondary : .primary)
    }
}

/// How far back the chart goes.
enum HistoryRange: String, CaseIterable, Identifiable {
    case day = "1d", threeDays = "3d", week = "7d", month = "30d", threeMonths = "3m", sixMonths = "6m", year = "1y"

    var id: Self { self }

    var title: String {
        switch self {
        case .day: "1 day"
        case .threeDays: "3 days"
        case .week: "7 days"
        case .month: "30 days"
        case .threeMonths: "3 months"
        case .sixMonths: "6 months"
        case .year: "1 year"
        }
    }

    var span: TimeInterval {
        let days: Double =
            switch self {
            case .day: 1
            case .threeDays: 3
            case .week: 7
            case .month: 30
            case .threeMonths: 91
            case .sixMonths: 182
            case .year: 365
            }
        return days * 24 * 60 * 60
    }

    /// Readings further apart than this are joined by grey dashes: an hour, or longer on charts where shorter gaps
    /// wouldn't show, and would break the lines every night the Mac sleeps.
    var gap: (seconds: TimeInterval, text: String) {
        switch self {
        case .day, .threeDays, .week, .month: (UsageHistory.hour, "an hour")
        case .threeMonths, .sixMonths: (12 * UsageHistory.hour, "12 hours")
        case .year: (24 * UsageHistory.hour, "a day")
        }
    }

    /// Gridlines at the start of every `unit` whose number is a multiple of `count`: midnight, 6 am, noon and 6 pm, or
    /// every day, week or month.
    var grid: (unit: Calendar.Component, count: Int, label: Date.FormatStyle) {
        switch self {
        case .day: (.hour, 6, .dateTime.hour())
        case .threeDays, .week: (.day, 1, .dateTime.weekday(.abbreviated).day())
        case .month: (.weekOfYear, 1, .dateTime.day().month(.abbreviated))
        case .threeMonths, .sixMonths, .year: (.month, 1, .dateTime.month(.abbreviated))
        }
    }
}

/// One profile's lines on the chart.
private struct ChartAccount: Identifiable {
    let id: String
    let name: String
    let color: Color
    let lines: [UsageHistory.Line]
}

private struct HistoryChart: View {
    let accounts: [ChartAccount]
    let history: UsageHistory
    let range: HistoryRange
    let start: Date
    let now: Date
    let pointer: Date?

    var body: some View {
        let peak = accounts.flatMap { $0.lines.flatMap(\.samples) }.map(\.percent).max() ?? 0
        Chart {
            ForEach(accounts) { account in
                ForEach(Array(account.lines.enumerated()), id: \.offset) { index, line in
                    ForEach(line.samples, id: \.date) { sample in
                        LineMark(
                            x: .value("Time", sample.date), y: .value("Usage", sample.percent),
                            series: .value("Line", "\(account.id)\n\(index)"))
                        .foregroundStyle(line.isGap ? Color.secondary : account.color)
                        .lineStyle(
                            line.isGap
                                ? StrokeStyle(lineWidth: 1, dash: [3, 3])
                                : StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                        .accessibilityLabel(
                            "\(account.name), \(sample.date.formatted(.dateTime.day().month().hour().minute()))")
                        .accessibilityValue("\(Int(sample.percent.rounded()))%")
                        .accessibilityHidden(line.isGap)
                    }
                    // A lone reading between two gaps has no line of its own.
                    if !line.isGap, line.samples.count == 1, let sample = line.samples.first {
                        PointMark(x: .value("Time", sample.date), y: .value("Usage", sample.percent))
                            .foregroundStyle(account.color)
                            .symbolSize(16)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .chartXScale(domain: start...now)
        .chartYScale(domain: 0...max(100, peak))
        .chartXAxis {
            AxisMarks(values: marks) { _ in
                // Solid, so they aren't taken for the grey dashes across gaps.
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisTick()
                // Drops a label that doesn't fit, as at the ends, rather than cutting it short.
                AxisValueLabel(format: range.grid.label, collisionResolution: .greedy)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Int.self) { Text("\(percent)%") }
                }
            }
        }
        .chartOverlay { proxy in
            HoverReadout(proxy: proxy, accounts: accounts, history: history, range: range, pointer: pointer)
        }
        .frame(minHeight: 180)
    }

    /// Stepping one unit at a time and checking the number on the clock keeps the 6-hourly lines on the hour across a
    /// daylight saving change.
    private var marks: [Date] {
        let calendar = Calendar.current
        let grid = range.grid
        guard let first = calendar.dateInterval(of: grid.unit, for: start)?.end else { return [] }
        return sequence(first: first) { calendar.date(byAdding: grid.unit, value: 1, to: $0) }
            .prefix { $0 < now }
            .filter { calendar.component(grid.unit, from: $0) % grid.count == 0 }
    }
}

/// A line under the pointer, with each shown account's usage at that time beside it. Its own view, so moving the
/// pointer doesn't redraw the chart.
private struct HoverReadout: View {
    let proxy: ChartProxy
    let accounts: [ChartAccount]
    let history: UsageHistory
    let range: HistoryRange
    let pointer: Date?
    @State private var location: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                let plot = geometry[anchor]
                // Drawn in an overlay so the readout can't resize, and so move, the area that tracks the pointer.
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case let .active(point) = phase, plot.contains(point) {
                            location = point
                        } else {
                            location = nil
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        let shown =
                            location ?? pointer.flatMap { proxy.position(forX: $0) }
                            .map { CGPoint(x: plot.minX + $0, y: plot.midY) }
                        if let location = shown, !accounts.isEmpty,
                            let date = proxy.value(atX: location.x - plot.minX, as: Date.self)
                        {
                            ZStack(alignment: .topLeading) {
                                Rectangle()
                                    .fill(.secondary)
                                    .frame(width: 1, height: plot.height)
                                    .offset(x: location.x, y: plot.minY)
                                // Beside the pointer, on whichever side has more room, and inside the plot.
                                // Names are cut short enough for it to fit on either side.
                                readout(at: date, nameWidth: min(160, plot.width / 2 - 90))
                                    .alignmentGuide(.leading) { size in
                                        let x = location.x > plot.midX ? location.x - 10 - size.width : location.x + 10
                                        return -min(max(x, plot.minX), plot.maxX - size.width)
                                    }
                                    .alignmentGuide(.top) { _ in -(plot.minY + 4) }
                            }
                            .allowsHitTesting(false)
                        }
                    }
            }
        }
    }

    private func readout(at date: Date, nameWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
                ForEach(accounts) { account in
                    // About 3 points either side of a reading at the window's usual width.
                    let percent = history.percent(
                        for: account.id, at: date, gap: range.gap.seconds, tolerance: range.span / 200)
                    GridRow {
                        Circle().fill(account.color).frame(width: 7, height: 7)
                        Text(account.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: nameWidth, alignment: .leading)
                        Text(percent.map { "\(Int($0.rounded()))%" } ?? "No data")
                            .monospacedDigit()
                            .foregroundStyle(percent == nil ? .secondary : .primary)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
        .font(.caption)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .fixedSize()
    }
}

/// The history window, made the first time it's opened and kept for the next.
@MainActor
enum HistoryWindow {
    private static var window: NSWindow?

    static func show(model: UsageModel) {
        let window = window ?? makeWindow(model: model)
        Self.window = window
        // A menu bar app isn't active while its menu is open, so its windows would open behind others'.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private static func makeWindow(model: UsageModel) -> NSWindow {
        let controller = NSHostingController(rootView: HistoryView(model: model))
        controller.sizingOptions = .minSize
        let window = NSWindow(contentViewController: controller)
        window.title = "Usage History"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 420))
        window.center()
        window.setFrameAutosaveName("UsageHistory")
        return window
    }
}

extension Color {
    /// From "#RRGGBB".
    init?(hex: String?) {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else {
            return nil
        }
        self.init(
            .sRGB, red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }

    /// As "#RRGGBB" in sRGB.
    var hex: String? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let byte = { (component: CGFloat) in Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X", byte(color.redComponent), byte(color.greenComponent), byte(color.blueComponent))
    }
}
