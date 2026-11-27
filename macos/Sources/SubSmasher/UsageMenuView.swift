import SubSmasherCore
import AppKit
import SwiftUI

struct UsageMenuView: View {
    let model: UsageModel

    // Drag to reorder: the picked-up account follows the pointer while the others slide aside as it
    // passes their midpoints. Layout only changes when the order is committed, after it settles.
    @State private var rowHeights: [String: Double] = [:]
    @State private var drag: AccountDrag?
    @State private var dragOffset: CGFloat = 0
    @State private var dropTarget = 0
    @State private var liftedID: String?
    @State private var separatorsHidden = false
    @State private var isSettling = false
    @GestureState private var isGestureActive = false

    private static let rowPadding: CGFloat = 10
    private static let space = "accounts"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.configError {
                ErrorText(message: error)
            }
            if !model.reports.isEmpty {
                accounts
            } else if model.configError == nil {
                Text("Loading…").foregroundStyle(.secondary)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.refreshIfStale() }
        .onChange(of: isGestureActive) { _, isActive in
            if !isActive { endDrag() }
        }
    }

    private var accounts: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.reports.enumerated()), id: \.element.id) { index, report in
                let isLifted = liftedID == report.id
                ProfileSection(report: report)
                    .padding(.vertical, Self.rowPadding)
                    .contentShape(Rectangle())
                    .onGeometryChange(for: Double.self) { Double($0.size.height) } action: {
                        rowHeights[report.id] = $0
                    }
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Divider().opacity(separatorsHidden ? 0 : 1)
                        }
                    }
                    .background {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.background)
                            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
                            .padding(.horizontal, -8)
                            .opacity(isLifted ? 1 : 0)
                    }
                    .scaleEffect(isLifted ? 1.02 : 1)
                    .offset(y: offset(forRowAt: index, id: report.id))
                    .zIndex(drag?.id == report.id ? 1 : 0)
                    .gesture(reorderGesture(for: report.id))
                    .grabCursor(isDragging: drag?.id == report.id)
            }
        }
        // Rows carry their own spacing; don't add it above the first or below the last.
        .padding(.vertical, -Self.rowPadding)
        .coordinateSpace(.named(Self.space))
    }

    private func offset(forRowAt index: Int, id: String) -> CGFloat {
        guard let drag else { return 0 }
        if id == drag.id { return dragOffset }
        let height = drag.heights[drag.index]
        if drag.index < index, index <= dropTarget { return -height }
        if dropTarget <= index, index < drag.index { return height }
        return 0
    }

    private func reorderGesture(for id: String) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .updating($isGestureActive) { _, isActive, _ in isActive = true }
            .onChanged { value in
                guard !isSettling, let drag = drag ?? beginDrag(id), drag.id == id else { return }
                let above = drag.heights[..<drag.index].reduce(0, +)
                let below = drag.heights[(drag.index + 1)...].reduce(0, +)
                let offset = min(max(Double(value.translation.height), -above), below)
                dragOffset = offset
                let target = dropIndex(heights: drag.heights, dragging: drag.index, offset: offset)
                if target != dropTarget {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    withAnimation(.snappy(duration: 0.22)) { dropTarget = target }
                }
            }
    }

    private func beginDrag(_ id: String) -> AccountDrag? {
        let ids = model.reports.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return nil }
        let newDrag = AccountDrag(id: id, ids: ids, index: index, heights: ids.map { rowHeights[$0] ?? 0 })
        drag = newDrag
        dragOffset = 0
        dropTarget = index
        withAnimation(.snappy(duration: 0.2)) {
            liftedID = id
            separatorsHidden = true
        }
        return newDrag
    }

    /// Springs the account into its new slot, then commits the order without animation so nothing jumps.
    private func endDrag() {
        guard let drag, !isSettling else { return }
        isSettling = true
        let target = dropTarget
        withAnimation(.snappy(duration: 0.25)) {
            dragOffset = slotOffset(heights: drag.heights, from: drag.index, to: target)
            liftedID = nil
        } completion: {
            withTransaction(Transaction(animation: nil)) {
                if target != drag.index {
                    model.move(drag.id, to: drag.ids[target])
                }
                self.drag = nil
                dragOffset = 0
            }
            withAnimation(.easeOut(duration: 0.2)) { separatorsHidden = false }
            isSettling = false
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            } else if let lastUpdated = model.lastUpdated {
                Text("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))")
            }
            Spacer()
            Button {
                HistoryWindow.show(model: model)
            } label: {
                Image(systemName: "chart.xyaxis.line")
            }
            .help("Usage history")
            Button {
                Task { await model.refresh(.manual) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            .disabled(model.isRefreshing)
            Button(action: model.openConfig) {
                Image(systemName: "gearshape")
            }
            .help("Open \(model.configURL.path)")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// Snapshot taken when an account is picked up.
private struct AccountDrag {
    let id: String
    let ids: [String]
    let index: Int
    let heights: [Double]
}

private struct ProfileSection: View {
    let report: ProfileReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(report.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if case let .success(profile) = report.result, let plan = profile.subscriptionType {
                    Text(plan.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
            }
            switch report.result {
            case let .success(profile):
                let rows = profile.rows
                if rows.isEmpty && profile.extraUsage == nil && profile.credits == nil && profile.resets == nil
                    && profile.status == nil
                {
                    Text("No plan usage limits reported").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    UsageRowView(row: row)
                }
                if let extra = profile.extraUsage {
                    ExtraUsageView(summary: extra)
                }
                if let status = profile.status {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Status")
                        Spacer()
                        Text(status).foregroundStyle(.red)
                    }
                    .font(.callout)
                }
                if let credits = profile.credits {
                    DetailRow(label: "Credits", value: credits.balance) {
                        if credits.isInUse { Text("In use until the limit resets") }
                    }
                }
                if let resets = profile.resets {
                    DetailRow(label: "Limit resets", value: "\(resets.available) available") {
                        if let nextExpiry = resets.nextExpiry { Countdown(prefix: "Next expires in", date: nextExpiry) }
                    }
                }
                if let checkedAt = profile.checkedAt {
                    Age(prefix: "Checked", date: checkedAt)
                        .help(
                            "Setup-token accounts are checked every 10 minutes while a 5-hour session is running, "
                                + "and otherwise only when you refresh.")
                }
                if let refreshError = profile.refreshError {
                    Text("Couldn't refresh: \(refreshError)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case let .failure(error):
                ErrorText(message: error.message)
            }
        }
    }
}

private struct UsageRowView: View {
    let row: UsageRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.label)
                Spacer()
                Text("\(Int(row.percent.rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(row.level.color)
            }
            UsageBar(percent: row.percent, color: row.level.color)
            if let resetsAt = row.resetsAt {
                Countdown(prefix: "Resets in", date: resetsAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

private struct ExtraUsageView: View {
    let summary: ExtraUsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Extra usage")
                Spacer()
                Text(summary.amount).monospacedDigit()
                if let percent = summary.percent {
                    Text("(\(Int(percent.rounded()))%)")
                        .monospacedDigit()
                        .foregroundStyle(Level(percent: percent).color)
                }
            }
            if !summary.isEnabled {
                Text(summary.disabledReason.map { "Disabled (\($0))" } ?? "Disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

/// "Resets in 2h 13m", kept current every minute. Computing it in a parent's body instead goes stale,
/// because SwiftUI only re-renders when the usage data changes, and a maxed-out limit doesn't.
private struct Countdown: View {
    let prefix: String
    let date: Date

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text("\(prefix) \(formatDuration(date.timeIntervalSince(context.date)))")
        }
        .help(date.formatted(date: .abbreviated, time: .shortened))
    }
}

/// "Checked 12m ago", kept current every minute.
private struct Age: View {
    let prefix: String
    let date: Date

    var body: some View {
        // Ticks a whole number of minutes after `date`, where `.everyMinute` would read up to a minute low.
        TimelineView(.periodic(from: date, by: 60)) { context in
            Text("\(prefix) \(formatDuration(context.date.timeIntervalSince(date))) ago")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// A label and value with an optional caption below, like the extra usage row.
private struct DetailRow<Caption: View>: View {
    let label: String
    let value: String
    @ViewBuilder var caption: Caption

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                Spacer()
                Text(value).monospacedDigit()
            }
            caption
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

private struct UsageBar: View {
    let percent: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * min(max(percent, 0), 100) / 100)
            }
        }
        .frame(height: 6)
    }
}

private struct ErrorText: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension Level {
    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

extension View {
    /// Open hand over draggable rows, closed while dragging (macOS 15+).
    @ViewBuilder
    fileprivate func grabCursor(isDragging: Bool) -> some View {
        if #available(macOS 15, *) {
            pointerStyle(isDragging ? .grabActive : .grabIdle)
        } else {
            self
        }
    }
}
