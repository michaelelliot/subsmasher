import AppKit
import Charts
import SubSmasherCore
import SwiftUI

/// The last 28 days of every profile's weekly usage on one chart, in a window opened from the menu.
struct HistoryView: View {
    let model: UsageModel
    /// A time to show the readout at whenever the pointer isn't over the plot, for the README's screenshots.
    var pointer: Date? = nil

    /// About a point per pixel at the window's usual width.
    private static let resolution: TimeInterval = 60 * 60

    var body: some View {
        let now = Date.now
        let start = now.addingTimeInterval(-UsageHistory.period)
        let accounts = model.reports.map { report in
            ChartAccount(
                id: report.id, name: report.displayName,
                color: Color(hex: model.historyColors[report.id]) ?? .accentColor,
                lines: model.history.lines(for: report.id, since: start, resolution: Self.resolution))
        }
        VStack(alignment: .leading, spacing: 12) {
            HistoryChart(
                accounts: accounts.filter { !model.hiddenFromHistory.contains($0.id) }, history: model.history,
                start: start, now: now, pointer: pointer
            )
            .overlay {
                if accounts.allSatisfy(\.lines.isEmpty) {
                    Text("No usage recorded yet")
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
                    + "more than an hour apart, where there's no data."
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
            .help(account.lines.isEmpty ? "No usage recorded in the last 28 days" : account.name)
            .accessibilityHint(account.lines.isEmpty ? "No usage recorded in the last 28 days" : "")
        }
        .foregroundStyle(account.lines.isEmpty ? .secondary : .primary)
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
            AxisMarks(values: weekMarks) { _ in
                // Solid, so they aren't taken for the grey dashes across gaps.
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
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
            HoverReadout(proxy: proxy, accounts: accounts, history: history, pointer: pointer)
        }
        .frame(minHeight: 180)
    }

    /// Midnight 7, 14 and 21 days before today's, splitting the 28 days into weeks.
    private var weekMarks: [Date] {
        let today = Calendar.current.startOfDay(for: now)
        return [21, 14, 7].compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: today) }
    }
}

/// A line under the pointer, with each shown account's usage at that time beside it. Its own view, so moving the
/// pointer doesn't redraw the chart.
private struct HoverReadout: View {
    let proxy: ChartProxy
    let accounts: [ChartAccount]
    let history: UsageHistory
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
                    let percent = history.percent(for: account.id, at: date)
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
        window.setContentSize(NSSize(width: 640, height: 380))
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
