import SubSmasherCore
import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class UsageModel {
    private(set) var reports: [ProfileReport] = []
    private(set) var configError: String?
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    private(set) var history = UsageHistory()
    /// Profiles left off the history chart, and their lines' colours there as "#RRGGBB". Kept in UserDefaults, like
    /// the order.
    private(set) var hiddenFromHistory: Set<String> = []
    private(set) var historyColors: [String: String] = [:]

    var configURL: URL { ConfigFile.defaultURL }

    private static let refreshInterval: Duration = .seconds(300)
    private static let staleAfter: TimeInterval = 60
    private static let orderKey = "profileOrder"
    private static let hiddenFromHistoryKey = "hiddenFromHistory"
    private static let historyColorsKey = "historyColors"
    /// Given out in turn to profiles without a colour. Mid-tones that read on light and dark backgrounds.
    private static let historyPalette = [
        "#0A84FF", "#FF9F0A", "#30D158", "#BF5AF2", "#FF375F", "#30B0C7", "#5E5CE6", "#AC8E68",
    ]
    private static let configTemplate = """
        # SubSmasher profiles: one [section] per account.
        # Keys: name (optional label), and setup_token, claude_config_dir, oauth_token, codex_home or cursor_dir.

        [default]
        claude_config_dir = ~/.claude

        """

    init() {
        Self.adoptAgentUsageDefaults()
        let defaults = UserDefaults.standard
        history = UsageHistory.load(from: UsageHistory.defaultURL)
        hiddenFromHistory = Set(defaults.stringArray(forKey: Self.hiddenFromHistoryKey) ?? [])
        historyColors = defaults.dictionary(forKey: Self.historyColorsKey) as? [String: String] ?? [:]
        Task { await refreshLoop() }
    }

    /// Takes over the saved order, setup-token check state and menu bar position the app had as Agent Usage, before it
    /// was renamed. Only in the app itself: an unbundled `swift run` or a test runner keeps its defaults elsewhere.
    private static func adoptAgentUsageDefaults() {
        let agentUsage = "local.agent-account-usage.AgentUsage"
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier == "local.subsmasher.SubSmasher",
            let saved = defaults.persistentDomain(forName: agentUsage)
        else { return }
        for (key, value) in saved where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.removePersistentDomain(forName: agentUsage)
    }

    /// Shows `reports` and `history` as just fetched, without reading the config or refreshing. For the README's
    /// screenshots.
    init(reports: [ProfileReport], history: UsageHistory = UsageHistory()) {
        self.reports = reports
        self.history = history
        historyColors = Self.assigningColors(to: reports.map(\.id), in: [:])
        lastUpdated = .now
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await refresh(.timer)
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    func refresh(_ trigger: RefreshTrigger) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let profiles = try ConfigFile.load(from: configURL)
            configError = profiles.isEmpty ? "no profiles in \(configURL.path)" : nil
            let fetched = await fetchReports(for: profiles, trigger: trigger)
            // Read the order after fetching so a drag made during the refresh isn't undone.
            reports = ordered(fetched, by: savedOrder)
            record(fetched)
        } catch {
            configError = error.localizedDescription
            reports = []
        }
        lastUpdated = .now
    }

    /// The display order the user dragged the profiles into. Kept in UserDefaults, not the shared config.
    private var savedOrder: [String] {
        UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []
    }

    /// Moves a profile into another's position. Returns false if either isn't shown.
    @discardableResult
    func move(_ id: String, to target: String) -> Bool {
        let ids = reports.map(\.id)
        guard ids.contains(id), ids.contains(target) else { return false }
        let newOrder = moving(id, to: target, in: ids)
        reports = ordered(reports, by: newOrder)
        UserDefaults.standard.set(newOrder, forKey: Self.orderKey)
        return true
    }

    /// Adds the refresh to the history, and gives profiles new to the history chart a colour there.
    private func record(_ fetched: [ProfileReport]) {
        var updated = history
        updated.record(fetched, at: .now)
        if updated != history {
            history = updated
            try? history.save(to: UsageHistory.defaultURL)
        }
        let colors = Self.assigningColors(to: fetched.map(\.id), in: historyColors)
        if colors != historyColors {
            historyColors = colors
            UserDefaults.standard.set(colors, forKey: Self.historyColorsKey)
        }
    }

    /// `colors` plus one for each of `ids` without one: the first in the palette that none of them has, so a profile
    /// keeps its colour when the profiles are reordered or one is added.
    private static func assigningColors(to ids: [String], in colors: [String: String]) -> [String: String] {
        var colors = colors
        for id in ids where colors[id] == nil {
            let used = Set(ids.compactMap { colors[$0] })
            colors[id] =
                historyPalette.first { !used.contains($0) } ?? historyPalette[used.count % historyPalette.count]
        }
        return colors
    }

    func setHistoryColor(_ hex: String, for id: String) {
        historyColors[id] = hex
        UserDefaults.standard.set(historyColors, forKey: Self.historyColorsKey)
    }

    func setShownInHistory(_ shown: Bool, for id: String) {
        if shown { hiddenFromHistory.remove(id) } else { hiddenFromHistory.insert(id) }
        UserDefaults.standard.set(hiddenFromHistory.sorted(), forKey: Self.hiddenFromHistoryKey)
    }

    func refreshIfStale() {
        if let lastUpdated, Date.now.timeIntervalSince(lastUpdated) < Self.staleAfter { return }
        Task { await refresh(.menuOpened) }
    }

    /// Opens the config in the default text editor, creating a starter file if there isn't one.
    func openConfig() {
        let files = FileManager.default
        if !files.fileExists(atPath: configURL.path) {
            try? files.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Self.configTemplate.write(to: configURL, atomically: true, encoding: .utf8)
        }
        let workspace = NSWorkspace.shared
        if let editor = workspace.urlForApplication(toOpen: .plainText) {
            workspace.open([configURL], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            workspace.open(configURL)
        }
    }

    /// The profile summarised in the menu bar: whichever is at the top of the list.
    private var primaryReport: ProfileReport? { reports.first }

    /// Highest utilization across the primary profile's windows.
    var peakPercent: Double? {
        guard case let .success(profile)? = primaryReport?.result else { return nil }
        return profile.rows.map(\.percent).max()
    }

    var menuBarText: String? {
        peakPercent.map { "\(Int($0.rounded()))%" }
    }

    /// The plush toy hugging a gauge whose needle shows the top account's usage, in the menu bar's own colour while
    /// there's plenty left, then yellow from 60%, orange from 70% and red from 90%, as the menu's bars turn orange and
    /// red. A warning triangle when the config can't be read or the top account has no usage to show. Uses the rounded
    /// percentage so the icon agrees with the number beside it.
    var menuBarImage: NSImage {
        guard let peak = peakPercent?.rounded() else {
            guard configError == nil, primaryReport == nil else {
                return NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "SubSmasher")
                    ?? NSImage()
            }
            return MenuBarIcon.image(percent: nil, color: nil)
        }
        let color: NSColor? =
            switch peak {
            case ..<60: nil
            case ..<70: MenuBarIcon.yellow
            case ..<90: .systemOrange
            default: .systemRed
            }
        return MenuBarIcon.image(percent: peak, color: color)
    }
}
