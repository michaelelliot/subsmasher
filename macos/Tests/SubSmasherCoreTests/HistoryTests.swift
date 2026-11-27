import Foundation
import Testing

@testable import SubSmasherCore

struct HistoryTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let minute: TimeInterval = 60
    static let hour = 60 * minute

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
        history.record([Self.report("a", Self.usage(weekly: 31.892770105605198))], at: Self.at(5))
        #expect(history.samples == ["a": Self.samples([(0, 10), (5, 31.9)]), "b": Self.samples([(0, 50)])])
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

    @Test func forgetsSamplesOlderThanAYear() {
        var history = UsageHistory()
        history.record(
            [Self.report("a", Self.usage(weekly: 10)), Self.report("b", Self.usage(weekly: 20))], at: Self.start)
        let later = 366 * 24 * 60 + 1.0
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

    @Test func thinsSamplesMoreThanAWeekOldToOneAnHourKeepingEveryGap() {
        let samples = Self.samples([(0, 1), (20, 2), (40, 3), (55, 4), (70, 5), (90, 6), (250, 7), (260, 8), (300, 9)])
            + Self.samples([(400, 10), (405, 11)])
        let thinned = UsageHistory.thinned(samples, before: Self.at(350))
        #expect(thinned == Self.samples([(0, 1), (55, 4), (90, 6), (250, 7), (300, 9), (400, 10), (405, 11)]))
        #expect(UsageHistory.thinned(thinned, before: Self.at(350)) == thinned)
        // The peak before a reset is kept.
        let reset = Self.samples([(0, 50), (20, 60), (40, 70), (50, 5), (70, 10), (400, 20)])
        #expect(
            UsageHistory.thinned(reset, before: Self.at(350)) == Self.samples([(0, 50), (40, 70), (70, 10), (400, 20)]))
    }

    @Test func linesKeepEachStretchsPeaksAndMarkTheGapsBetween() {
        let history = UsageHistory(samples: [
            "a": Self.samples([(0, 1), (5, 2), (10, 3), (15, 4), (20, 5), (120, 6), (125, 7), (300, 8)]),
            "b": Self.samples([(0, 50), (5, 80), (10, 0), (15, 5)]),
        ])
        let hour = Self.hour
        #expect(history.lines(for: "a", since: Self.start, resolution: 10 * Self.minute, gap: hour) == [
            UsageHistory.Line(samples: Self.samples([(0, 1), (5, 2), (15, 4), (20, 5)]), isGap: false),
            UsageHistory.Line(samples: Self.samples([(20, 5), (120, 6)]), isGap: true),
            UsageHistory.Line(samples: Self.samples([(120, 6), (125, 7)]), isGap: false),
            UsageHistory.Line(samples: Self.samples([(125, 7), (300, 8)]), isGap: true),
            UsageHistory.Line(samples: Self.samples([(300, 8)]), isGap: false),
        ])
        // The peak before a reset survives thinning.
        #expect(history.lines(for: "b", since: Self.start, resolution: 20 * Self.minute, gap: hour) == [
            UsageHistory.Line(samples: Self.samples([(0, 50), (5, 80), (15, 5)]), isGap: false)
        ])
        // Longer charts allow longer gaps.
        #expect(history.lines(for: "a", since: Self.start, resolution: 1, gap: 200 * Self.minute) == [
            UsageHistory.Line(samples: history.samples["a"]!, isGap: false)
        ])
        #expect(history.lines(for: "a", since: Self.at(200), resolution: 1, gap: hour) == [
            UsageHistory.Line(samples: Self.samples([(300, 8)]), isGap: false)
        ])
        #expect(history.lines(for: "c", since: Self.start, resolution: 1, gap: hour).isEmpty)
    }

    @Test func usageAtATimeIsTheNearerSampleOnALineOrOneWithinTolerance() {
        let history = UsageHistory(samples: ["a": Self.samples([(0, 10), (50, 20), (200, 30)])])
        func percent(at minutes: TimeInterval, gap: TimeInterval = Self.hour) -> Double? {
            history.percent(for: "a", at: Self.at(minutes), gap: gap, tolerance: 5 * Self.minute)
        }
        #expect(percent(at: 20) == 10)
        #expect(percent(at: 30) == 20)
        // In the gap from 50 to 200, except next to either end.
        #expect(percent(at: 120) == nil)
        #expect(percent(at: 175) == nil)
        #expect(percent(at: 54) == 20)
        #expect(percent(at: 197) == 30)
        #expect(percent(at: 120, gap: 160 * Self.minute) == 20)
        // Before the first sample and after the last.
        #expect(percent(at: -31) == nil)
        #expect(percent(at: -3) == 10)
        #expect(percent(at: 205) == 30)
        #expect(percent(at: 206) == nil)
        #expect(history.percent(for: "b", at: Self.start, gap: Self.hour, tolerance: Self.hour) == nil)
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
