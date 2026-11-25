import Foundation

public struct QuotaState: Codable, Equatable, Sendable {
    public var version: Int
    public var updatedAt: Date
    public var providers: [String: ProviderSnapshot]

    public init(version: Int = 1, updatedAt: Date = Date(), providers: [String: ProviderSnapshot] = [:]) {
        self.version = version
        self.updatedAt = updatedAt
        self.providers = providers
    }
}

public struct ProviderSnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var shortName: String
    public var source: String
    public var updatedAt: Date
    public var poolsUpdatedAt: Date?
    public var tokensUpdatedAt: Date?
    public var tokens: TokenUsage?
    public var pools: [QuotaPool]

    public init(
        id: String,
        displayName: String,
        shortName: String,
        source: String,
        updatedAt: Date,
        poolsUpdatedAt: Date? = nil,
        tokensUpdatedAt: Date? = nil,
        tokens: TokenUsage? = nil,
        pools: [QuotaPool] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.shortName = shortName
        self.source = source
        self.updatedAt = updatedAt
        self.poolsUpdatedAt = poolsUpdatedAt
        self.tokensUpdatedAt = tokensUpdatedAt
        self.tokens = tokens
        self.pools = pools
    }

    public func isPoolsStale(now: Date = Date(), threshold: TimeInterval = 30 * 60) -> Bool {
        let referenceDate = poolsUpdatedAt ?? updatedAt
        return now.timeIntervalSince(referenceDate) > threshold
    }

    public func soonestFiveHourReset(now: Date = Date()) -> Date? {
        pools
            .compactMap { $0.fiveHour?.resetAt }
            .filter { $0 > now }
            .min()
    }

    public var lowestRemainingPercent: Double? {
        let values = pools.flatMap { [$0.fiveHour?.remainingPercent, $0.weekly?.remainingPercent] }.compactMap { $0 }
        return values.min()
    }

    public func displayTokens(for now: Date = Date(), timeZone: TimeZone = .current) -> TokenUsage? {
        guard let tokens else { return nil }
        let today = QuotaFormatters.dayKey(for: now, timeZone: timeZone)
        if tokens.periodLabel == "今日 Token" && tokens.dayKey != today {
            return TokenUsage(periodLabel: tokens.periodLabel, dayKey: today, total: 0, input: nil, output: nil)
        }
        return tokens
    }
}

public struct QuotaPool: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var subtitle: String?
    public var tokensUsed: Int?
    public var fiveHour: QuotaWindow?
    public var weekly: QuotaWindow?

    public init(
        id: String,
        name: String,
        subtitle: String? = nil,
        tokensUsed: Int? = nil,
        fiveHour: QuotaWindow? = nil,
        weekly: QuotaWindow? = nil
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.tokensUsed = tokensUsed
        self.fiveHour = fiveHour
        self.weekly = weekly
    }
}

public struct QuotaWindow: Codable, Equatable, Sendable {
    public var remainingPercent: Double
    public var resetAt: Date?

    public init(remainingPercent: Double, resetAt: Date? = nil) {
        self.remainingPercent = QuotaFormatters.clampPercent(remainingPercent)
        self.resetAt = resetAt
    }
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public var periodLabel: String
    public var dayKey: String
    public var total: Int
    public var input: Int?
    public var output: Int?

    public init(
        periodLabel: String = "今日 Token",
        dayKey: String,
        total: Int,
        input: Int? = nil,
        output: Int? = nil
    ) {
        self.periodLabel = periodLabel
        self.dayKey = dayKey
        self.total = max(0, total)
        self.input = input.map { max(0, $0) }
        self.output = output.map { max(0, $0) }
    }
}

public enum QuotaJSONCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let timestamp = try? container.decode(Double.self) {
                return timestamp > 1_000_000_000_000
                    ? Date(timeIntervalSince1970: timestamp / 1000.0)
                    : Date(timeIntervalSince1970: timestamp)
            }
            let str = try container.decode(String.self)
            if let parsed = QuotaFormatters.parseISO8601Date(str) {
                return parsed
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(str)")
        }
        return decoder
    }
}

public enum QuotaFormatters {
    public static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(100.0, max(0.0, value))
    }

    public static func formatPercent(_ value: Double) -> String {
        let clamped = clampPercent(value)
        if clamped >= 99.95 {
            return "100%"
        }
        let rounded = clamped.rounded()
        if abs(clamped - rounded) < 0.05 {
            return "\(Int(rounded))%"
        }
        return String(format: "%.1f%%", clamped)
    }

    public static func formatTokens(_ count: Int) -> String {
        let value = max(0, count)
        if value >= 1_000_000_000 {
            return formatScaled(Double(value) / 1_000_000_000.0, suffix: "B")
        }
        if value >= 1_000_000 {
            return formatScaled(Double(value) / 1_000_000.0, suffix: "M")
        }
        if value >= 1_000 {
            return formatScaled(Double(value) / 1_000.0, suffix: "K")
        }
        return "\(value)"
    }

    private static func formatScaled(_ scaled: Double, suffix: String) -> String {
        if scaled >= 100 {
            return String(format: "%.0f%@", scaled, suffix)
        }
        if scaled >= 10 {
            let formatted = String(format: "%.1f", scaled)
            return formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) + suffix : formatted + suffix
        }
        return String(format: "%.2f%@", scaled, suffix)
    }

    public static func formatCountdown(to resetAt: Date?, now: Date = Date()) -> String {
        guard let resetAt else { return "—" }
        let remaining = Int(resetAt.timeIntervalSince(now))
        if remaining <= 0 {
            return "即将重置"
        }
        if remaining >= 86_400 {
            let days = remaining / 86_400
            let hours = (remaining % 86_400) / 3_600
            return "\(days)天 \(hours)时"
        }
        let hours = remaining / 3_600
        let minutes = (remaining % 3_600) / 60
        let seconds = remaining % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    public static func formatResetClock(_ resetAt: Date?, timeZone: TimeZone = .current) -> String {
        guard let resetAt else { return "未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "E HH:mm"
        return formatter.string(from: resetAt)
    }

    public static func formatRelativeSync(since date: Date, now: Date = Date()) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(date)))
        if elapsed < 45 { return "刚刚同步" }
        if elapsed < 3_600 { return "\(elapsed / 60)分钟前同步" }
        if elapsed < 86_400 { return "\(elapsed / 3_600)小时前同步" }
        return "\(elapsed / 86_400)天前同步"
    }

    public static func dayKey(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func parseISO8601Date(_ string: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFrac.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

public enum DemoData {
    public static func makeState(now: Date = Date(), timeZone: TimeZone = .current) -> QuotaState {
        let today = QuotaFormatters.dayKey(for: now, timeZone: timeZone)
        let weeklyReset = now.addingTimeInterval(310_920) // 3d 14h 22m
        let geminiFiveHour = now.addingTimeInterval(8_078) // 2h 14m 38s
        let claudeGptFiveHour = now.addingTimeInterval(6_130) // 1h 42m 10s
        let claudeFiveHour = now.addingTimeInterval(11_119) // 3h 05m 19s
        let claudeWeekly = now.addingTimeInterval(393_900) // 4d 13h 25m
        let codexFiveHour = now.addingTimeInterval(15_522) // 4h 18m 42s
        let codexWeekly = now.addingTimeInterval(511_800) // 5d 22h 10m

        let agy = ProviderSnapshot(
            id: "antigravity",
            displayName: "Antigravity",
            shortName: "AGY",
            source: "演示数据",
            updatedAt: now,
            poolsUpdatedAt: now,
            tokensUpdatedAt: now,
            tokens: TokenUsage(
                periodLabel: "今日 Token",
                dayKey: today,
                total: 2_020_000,
                input: 1_540_000,
                output: 480_000
            ),
            pools: [
                QuotaPool(
                    id: "gemini",
                    name: "Gemini",
                    tokensUsed: 1_070_000,
                    fiveHour: QuotaWindow(remainingPercent: 78, resetAt: geminiFiveHour),
                    weekly: QuotaWindow(remainingPercent: 65, resetAt: weeklyReset)
                ),
                QuotaPool(
                    id: "claude-gpt",
                    name: "Claude / GPT",
                    tokensUsed: 770_000,
                    fiveHour: QuotaWindow(remainingPercent: 32, resetAt: claudeGptFiveHour),
                    weekly: QuotaWindow(remainingPercent: 48, resetAt: weeklyReset)
                ),
                QuotaPool(
                    id: "gemini-4-argon",
                    name: "Gemini 4 Argon",
                    tokensUsed: 180_000,
                    fiveHour: nil,
                    weekly: QuotaWindow(remainingPercent: 94, resetAt: weeklyReset)
                )
            ]
        )

        let claude = ProviderSnapshot(
            id: "claude",
            displayName: "Claude Code",
            shortName: "Claude",
            source: "演示数据",
            updatedAt: now,
            poolsUpdatedAt: now,
            tokensUpdatedAt: now,
            tokens: TokenUsage(
                periodLabel: "今日 Token",
                dayKey: today,
                total: 1_120_000,
                input: 910_000,
                output: 210_000
            ),
            pools: [
                QuotaPool(
                    id: "claude-code",
                    name: "Claude Code",
                    tokensUsed: 1_120_000,
                    fiveHour: QuotaWindow(remainingPercent: 68, resetAt: claudeFiveHour),
                    weekly: QuotaWindow(remainingPercent: 58, resetAt: claudeWeekly)
                )
            ]
        )

        let codex = ProviderSnapshot(
            id: "codex",
            displayName: "OpenAI Codex",
            shortName: "Codex",
            source: "演示数据",
            updatedAt: now,
            poolsUpdatedAt: now,
            tokensUpdatedAt: now,
            tokens: TokenUsage(
                periodLabel: "今日 Token",
                dayKey: today,
                total: 740_000,
                input: 590_000,
                output: 150_000
            ),
            pools: [
                QuotaPool(
                    id: "openai-codex",
                    name: "OpenAI Codex",
                    tokensUsed: 740_000,
                    fiveHour: QuotaWindow(remainingPercent: 75, resetAt: codexFiveHour),
                    weekly: QuotaWindow(remainingPercent: 82, resetAt: codexWeekly)
                )
            ]
        )

        return QuotaState(version: 1, updatedAt: now, providers: [
            agy.id: agy,
            claude.id: claude,
            codex.id: codex
        ])
    }
}
