import Foundation
import Testing

@testable import SubSmasherCore

struct HistoryTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let minute: TimeInterval = 60

    static func at(_ minutes: TimeInterval) -> Date {
        start.addingTimeInterval(minutes * minute)
    }

    static func usage(weekly: Double?) -> ProfileUsage {
        var rows = [UsageRow(label: "Session (5h)", percent: 40, resetsAt: nil)]
        if let weekly { rows.append(UsageRow(label: "Weekly", percent: weekly, resetsAt: nil)) }
        return ProfileUsage(subscriptionType: nil, rows: rows, extraUsage: nil, credits: nil, resets: nil)
    }

    static func report(_ id: String, _ usage: ProfileUsage) -> ProfileReport {
        ProfileReport(id: id, displayName: id, result: .success(usage))
    }

    static func samples(_ points: [(TimeInterval, Double)]) -> [UsageHistory.Sample] {
        points.map { UsageHistory.Sample(date: at($0.0), percent: $0.1) }
    }

    @Test func recordsEachAccountsWeeklyUsageAtMostEveryFewMinutes() {
        var history = UsageHistory()
        history.record(
            [Self.report("a", Self.usage(weekly: 10)), Self.report("b", Self.usage(weekly: 50))], at: Self.start)
        history.record([Self.report("a", Self.usage(weekly: 11))], at: Self.at(1))
        history.record([Self.report("a", Self.usage(weekly: 12))], at: Self.at(5))
        #expect(history.samples == ["a": Self.samples([(0, 10), (5, 12)]), "b": Self.samples([(0, 50)])])
    }

    @Test func recordsOnlyWeeklyUsageReadInThisRefresh() {
        var earlier = Self.usage(weekly: 91)
        earlier.checkedAt = Self.at(-6)
        var failed = Self.usage(weekly: 30)
        failed.refreshError = "HTTP 500: overloaded"
        var history = UsageHistory()
        history.record(
            [
                Self.report("earlier check", earlier), Self.report("failed refresh", failed),
                Self.report("session only", Self.usage(weekly: nil)),
                ProfileReport(id: "error", displayName: "error", result: .failure(UsageError("no login"))),
            ], at: Self.start)
        #expect(history.samples.isEmpty)
    }

    @Test func forgetsSamplesOlderThan28Days() {
        var history = UsageHistory()
        history.record(
            [Self.report("a", Self.usage(weekly: 10)), Self.report("b", Self.usage(weekly: 20))], at: Self.start)
        let later = 28 * 24 * 60 + 1.0
        history.record([Self.report("a", Self.usage(weekly: 30))], at: Self.at(later))
        #expect(history.samples == ["a": Self.samples([(later, 30)])])
    }

    @Test func weeklyUsageIsTheLimitAcrossAllModels() throws {
        let claude = try Usage.decode(Data(UsageTests.response.utf8))
        #expect(ProfileUsage(claude: claude, subscriptionType: nil).weeklyPercent == 8)
        let headers = [
            "anthropic-ratelimit-unified-5h-utilization": "0.07", "anthropic-ratelimit-unified-7d-utilization": "0.91",
        ]
        #expect(ProfileUsage(setupToken: UnifiedLimits(headers: headers)!, now: Self.start).weeklyPercent == 91)
        let codex = try CodexUsage.decode(Data(CodexTests.response.utf8))
        #expect(ProfileUsage(codex: codex, resetCredits: []).weeklyPercent == 100)
        let grok = try GrokTests.decode(GrokTests.response)
        #expect(ProfileUsage(grok: grok, bankedResets: []).weeklyPercent == 31.892770105605198)
        #expect(Self.usage(weekly: nil).weeklyPercent == nil)
    }

    @Test func linesJoinNearbySamplesThinnedAndMarkTheGapsBetween() {
        let history = UsageHistory(samples: [
            "a": Self.samples([(0, 1), (5, 2), (10, 3), (15, 4), (20, 5), (120, 6), (125, 7), (300, 8)])
        ])
        #expect(history.lines(for: "a", since: Self.start, resolution: 10 * Self.minute) == [
            UsageHistory.Line(samples: Self.samples([(0, 1), (10, 3), (20, 5)]), isGap: false),
            UsageHistory.Line(samples: Self.samples([(20, 5), (120, 6)]), isGap: true),
            UsageHistory.Line(samples: Self.samples([(120, 6), (125, 7)]), isGap: false),
            UsageHistory.Line(samples: Self.samples([(125, 7), (300, 8)]), isGap: true),
            UsageHistory.Line(samples: Self.samples([(300, 8)]), isGap: false),
        ])
        #expect(history.lines(for: "a", since: Self.at(200), resolution: 0) == [
            UsageHistory.Line(samples: Self.samples([(300, 8)]), isGap: false)
        ])
        #expect(history.lines(for: "b", since: Self.start, resolution: 0).isEmpty)
    }

    @Test func usageAtATimeIsTheNearestSampleWithinHalfTheLongestGap() {
        let history = UsageHistory(samples: ["a": Self.samples([(0, 10), (50, 20), (200, 30)])])
        #expect(history.percent(for: "a", at: Self.at(20)) == 10)
        #expect(history.percent(for: "a", at: Self.at(30)) == 20)
        #expect(history.percent(for: "a", at: Self.at(125)) == nil)
        #expect(history.percent(for: "a", at: Self.at(175)) == 30)
        #expect(history.percent(for: "a", at: Self.at(-31)) == nil)
        #expect(history.percent(for: "b", at: Self.start) == nil)
    }

    @Test func savesAndLoads() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "subsmasher-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "history.json")
        let history = UsageHistory(samples: ["a": Self.samples([(0, 10.5), (5, 12)])])
        try history.save(to: url)
        #expect(UsageHistory.load(from: url) == history)
        #expect(UsageHistory.load(from: directory.appending(path: "missing.json")) == UsageHistory())
    }
}
