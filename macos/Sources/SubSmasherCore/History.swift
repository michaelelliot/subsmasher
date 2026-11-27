import Foundation

/// Each account's weekly usage over the last year. None of the APIs return past usage, so the app records it at each
/// refresh and keeps it in a file.
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

    /// A year, and a day to spare.
    public static let retention: TimeInterval = 366 * 24 * 60 * 60
    /// Samples newer than this are all kept. Older ones are thinned to one an hour, so a year of refreshes isn't
    /// 100,000 samples an account.
    static let fullDetail: TimeInterval = 7 * 24 * 60 * 60
    /// The app refreshes every 5 minutes, and more often while the menu is open. Those in between aren't recorded.
    static let spacing: TimeInterval = 4 * 60
    /// The shortest gap: samples further apart than this, as when the Mac was asleep or the account couldn't be read,
    /// have unknown usage between them.
    public static let hour: TimeInterval = 60 * 60

    /// Oldest first, by profile id.
    public private(set) var samples: [String: [Sample]]

    public init(samples: [String: [Sample]] = [:]) {
        self.samples = samples
    }

    /// Adds each account's weekly usage, if it was read in this refresh, forgets samples more than a year old, and
    /// thins those more than a week old.
    public mutating func record(_ reports: [ProfileReport], at now: Date) {
        let date = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded())
        for report in reports {
            // A setup-token account's values can be from an earlier check, which recorded them when it read them.
            guard case let .success(usage) = report.result, usage.checkedAt == nil, usage.refreshError == nil,
                let percent = usage.weeklyPercent
            else { continue }
            if let last = samples[report.id]?.last, date.timeIntervalSince(last.date) < Self.spacing { continue }
            samples[report.id, default: []].append(Sample(date: date, percent: (percent * 10).rounded() / 10))
        }
        let oldest = now.addingTimeInterval(-Self.retention)
        let detailed = now.addingTimeInterval(-Self.fullDetail)
        samples = samples.compactMapValues { samples in
            let kept = Self.thinned(Array(samples.drop { $0.date < oldest }), before: detailed)
            return kept.isEmpty ? nil : kept
        }
    }

    /// Drops samples from before `cutoff` that are less than an hour after the last one kept, unless the next one is
    /// more than an hour after it, so thinning never opens a gap and every gap keeps both ends, or is lower, so the
    /// peak before each weekly reset stays.
    static func thinned(_ samples: [Sample], before cutoff: Date) -> [Sample] {
        var kept: [Sample] = []
        for (index, sample) in samples.enumerated() {
            if sample.date < cutoff, let previous = kept.last, index + 1 < samples.count,
                sample.date.timeIntervalSince(previous.date) < hour,
                samples[index + 1].date.timeIntervalSince(previous.date) <= hour,
                samples[index + 1].percent >= sample.percent
            {
                continue
            }
            kept.append(sample)
        }
        return kept
    }

    /// The account's samples from `start` on, as lines to draw, with a gap wherever two are more than `gap` apart.
    /// Between its first and last samples, each line keeps the highest in every `resolution` from `start`, so a long
    /// chart isn't thousands of points and still shows each peak.
    public func lines(for id: String, since start: Date, resolution: TimeInterval, gap: TimeInterval) -> [Line] {
        var lines: [Line] = []
        var run: [Sample] = []
        func endRun() {
            guard let first = run.first, let last = run.last else { return }
            var kept = [first]
            var bucket: Int?
            for sample in run.dropFirst().dropLast() {
                let index = Int(sample.date.timeIntervalSince(start) / max(resolution, 1))
                if index == bucket {
                    if sample.percent > kept[kept.count - 1].percent { kept[kept.count - 1] = sample }
                } else {
                    kept.append(sample)
                    bucket = index
                }
            }
            if run.count > 1 { kept.append(last) }
            lines.append(Line(samples: kept, isGap: false))
        }
        for sample in samples[id] ?? [] where sample.date >= start {
            if let last = run.last, sample.date.timeIntervalSince(last.date) > gap {
                endRun()
                lines.append(Line(samples: [last, sample], isGap: true))
                run = []
            }
            run.append(sample)
        }
        endRun()
        return lines
    }

    /// The account's usage at `date`, agreeing with `lines`: the nearer sample's of those either side, if they're no
    /// more than `gap` apart, or else of one within `tolerance`, so a lone reading or the end of a line can be pointed
    /// at.
    public func percent(for id: String, at date: Date, gap: TimeInterval, tolerance: TimeInterval) -> Double? {
        guard let samples = samples[id] else { return nil }
        let index = samples.firstIndex { $0.date > date } ?? samples.endIndex
        let before = index > 0 ? samples[index - 1] : nil
        let after = index < samples.endIndex ? samples[index] : nil
        let distance = { (sample: Sample) in abs(sample.date.timeIntervalSince(date)) }
        guard let nearest = [before, after].compactMap({ $0 }).min(by: { distance($0) < distance($1) }) else {
            return nil
        }
        if let before, let after, after.date.timeIntervalSince(before.date) <= gap { return nearest.percent }
        return distance(nearest) <= tolerance ? nearest.percent : nil
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
    /// are 5-hour sessions, which come and go too often to read over days or weeks.
    public var weeklyPercent: Double? {
        rows.first { $0.label == "Weekly" || $0.label == "Weekly (all models)" }?.percent
    }
}
