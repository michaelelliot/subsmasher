import Foundation

/// Each account's weekly usage over the last 28 days. None of the APIs return past usage, so the app records it at
/// each refresh and keeps it in a file.
public struct UsageHistory: Sendable, Equatable, Codable {
    public struct Sample: Sendable, Equatable, Codable {
        public let date: Date
        public let percent: Double

        public init(date: Date, percent: Double) {
            self.date = date
            self.percent = percent
        }

        enum CodingKeys: String, CodingKey {
            case date = "t"
            case percent = "p"
        }
    }

    /// A stretch of one account's usage to draw: samples close enough together to join, or the gap between two that
    /// aren't, across which usage isn't known.
    public struct Line: Sendable, Equatable {
        public let samples: [Sample]
        public let isGap: Bool
    }

    public static let period: TimeInterval = 28 * 24 * 60 * 60
    /// The app refreshes every 5 minutes, and more often while the menu is open. Those in between aren't recorded.
    static let spacing: TimeInterval = 4 * 60
    /// Samples further apart than this have a gap between them, as when the Mac was asleep or the account couldn't be
    /// read.
    static let maxGap: TimeInterval = 60 * 60

    /// Oldest first, by profile id.
    public private(set) var samples: [String: [Sample]]

    public init(samples: [String: [Sample]] = [:]) {
        self.samples = samples
    }

    /// Adds each account's weekly usage, if it was read in this refresh, and forgets samples more than 28 days old.
    public mutating func record(_ reports: [ProfileReport], at now: Date) {
        let date = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded())
        for report in reports {
            // A setup-token account's values can be from an earlier check, which recorded them when it read them.
            guard case let .success(usage) = report.result, usage.checkedAt == nil, usage.refreshError == nil,
                let percent = usage.weeklyPercent
            else { continue }
            if let last = samples[report.id]?.last, date.timeIntervalSince(last.date) < Self.spacing { continue }
            samples[report.id, default: []].append(Sample(date: date, percent: percent))
        }
        let cutoff = now.addingTimeInterval(-Self.period)
        samples = samples.compactMapValues { samples in
            let kept = samples.drop { $0.date < cutoff }
            return kept.isEmpty ? nil : Array(kept)
        }
    }

    /// The account's samples from `start` on, as lines to draw. Each line keeps one sample per `resolution` and its
    /// last, so 28 days of refreshes don't become thousands of points.
    public func lines(for id: String, since start: Date, resolution: TimeInterval) -> [Line] {
        var lines: [Line] = []
        var run: [Sample] = []
        func endRun() {
            guard let last = run.last else { return }
            var kept: [Sample] = []
            for sample in run {
                if let previous = kept.last, sample.date.timeIntervalSince(previous.date) < resolution { continue }
                kept.append(sample)
            }
            if kept.last != last { kept.append(last) }
            lines.append(Line(samples: kept, isGap: false))
        }
        for sample in samples[id] ?? [] where sample.date >= start {
            if let last = run.last, sample.date.timeIntervalSince(last.date) > Self.maxGap {
                endRun()
                lines.append(Line(samples: [last, sample], isGap: true))
                run = []
            }
            run.append(sample)
        }
        endRun()
        return lines
    }

    /// The account's usage at `date`: the nearest sample's, unless that's more than half the longest gap away.
    public func percent(for id: String, at date: Date) -> Double? {
        let distance = { (sample: Sample) in abs(sample.date.timeIntervalSince(date)) }
        guard let nearest = samples[id]?.min(by: { distance($0) < distance($1) }), distance(nearest) <= Self.maxGap / 2
        else { return nil }
        return nearest.percent
    }

    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "SubSmasher/history.json")
    }

    /// Empty when the file is missing or can't be read.
    public static func load(from url: URL) -> UsageHistory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Self.self, from: $0) } ?? UsageHistory()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

extension ProfileUsage {
    /// The weekly limit across all models, which history records. The per-model weekly limits are left out, and so
    /// are 5-hour sessions, which come and go too often to read over 28 days.
    public var weeklyPercent: Double? {
        rows.first { $0.label == "Weekly" || $0.label == "Weekly (all models)" }?.percent
    }
}
