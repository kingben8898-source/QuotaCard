import Foundation
@testable import QuotaCardCore

enum ModelsAndFormattingTests {
    static var all: [TestCase] {
        [
            TestCase(suite: "ModelsAndFormattingTests", name: "formatTokensScalesKMB") {
                try expectEqual(QuotaFormatters.formatTokens(0), "0")
                try expectEqual(QuotaFormatters.formatTokens(950), "950")
                try expectEqual(QuotaFormatters.formatTokens(12_400), "12.4K")
                try expectEqual(QuotaFormatters.formatTokens(480_000), "480K")
                try expectEqual(QuotaFormatters.formatTokens(2_020_000), "2.02M")
                try expectEqual(QuotaFormatters.formatTokens(1_500_000_000), "1.50B")
            },
            TestCase(suite: "ModelsAndFormattingTests", name: "formatCountdownUnder24Hours") {
                let now = Date(timeIntervalSince1970: 1_764_000_000)
                let resetAt = now.addingTimeInterval(8_078)
                try expectEqual(QuotaFormatters.formatCountdown(to: resetAt, now: now), "02:14:38")
            },
            TestCase(suite: "ModelsAndFormattingTests", name: "formatCountdownOver24Hours") {
                let now = Date(timeIntervalSince1970: 1_764_000_000)
                let resetAt = now.addingTimeInterval(310_920)
                try expectEqual(QuotaFormatters.formatCountdown(to: resetAt, now: now), "3天 14时")
            },
            TestCase(suite: "ModelsAndFormattingTests", name: "formatCountdownClampsPastAndZeroToSoon") {
                let now = Date(timeIntervalSince1970: 1_764_000_000)
                try expectEqual(QuotaFormatters.formatCountdown(to: now, now: now), "即将重置")
                try expectEqual(QuotaFormatters.formatCountdown(to: now.addingTimeInterval(-90), now: now), "即将重置")
                try expectEqual(QuotaFormatters.formatCountdown(to: nil, now: now), "—")
            },
            TestCase(suite: "ModelsAndFormattingTests", name: "clampPercentBounds") {
                try expectEqual(QuotaFormatters.clampPercent(-5), 0)
                try expectEqual(QuotaFormatters.clampPercent(120), 100)
                try expect(abs(QuotaFormatters.clampPercent(78.4) - 78.4) < 0.0001)
            },
            TestCase(suite: "ModelsAndFormattingTests", name: "poolsStalenessUsesPoolsUpdatedAt") {
                let t0 = Date(timeIntervalSince1970: 1_764_000_000)
                let snapshot = ProviderSnapshot(
                    id: "antigravity",
                    displayName: "Antigravity",
                    shortName: "AGY",
                    source: "agy-statusline",
                    updatedAt: t0.addingTimeInterval(39 * 60),
                    poolsUpdatedAt: t0,
                    tokensUpdatedAt: t0.addingTimeInterval(39 * 60),
                    tokens: TokenUsage(periodLabel: "今日 Token", dayKey: "2026-11-25", total: 1000, input: 800, output: 200),
                    pools: [
                        QuotaPool(
                            id: "gemini",
                            name: "Gemini",
                            tokensUsed: nil,
                            fiveHour: QuotaWindow(remainingPercent: 80, resetAt: t0.addingTimeInterval(3600)),
                            weekly: nil
                        )
                    ]
                )
                let now = t0.addingTimeInterval(40 * 60)
                try expectEqual(snapshot.isPoolsStale(now: now, threshold: 30 * 60), true)
                try expectEqual(snapshot.isPoolsStale(now: t0.addingTimeInterval(10 * 60), threshold: 30 * 60), false)
            },
            TestCase(suite: "ModelsAndFormattingTests", name: "demoDataContainsAntigravityThreePools") {
                let now = Date(timeIntervalSince1970: 1_764_000_000)
                let state = DemoData.makeState(now: now)
                let agy = try expectNotNil(state.providers["antigravity"])
                try expectEqual(agy.pools.map(\.name), ["Gemini", "Claude / GPT", "Gemini 4 Argon"])
                _ = try expectNotNil(agy.pools[0].fiveHour)
                _ = try expectNotNil(agy.pools[0].weekly)
                _ = try expectNotNil(agy.pools[1].fiveHour)
                _ = try expectNotNil(agy.pools[1].weekly)
                try expectNil(agy.pools[2].fiveHour)
                _ = try expectNotNil(agy.pools[2].weekly)
                try expectEqual(agy.tokens?.total, 2_020_000)
                _ = try expectNotNil(state.providers["claude"])
                _ = try expectNotNil(state.providers["codex"])
            },
            TestCase(suite: "ModelsAndFormattingTests", name: "displayTokensResetsToZeroAfterMidnightRollover") {
                let tz = TimeZone(secondsFromGMT: 0)!
                let day1 = Date(timeIntervalSince1970: 1_764_000_000)
                let day2 = day1.addingTimeInterval(86_400)
                let snapshot = ProviderSnapshot(
                    id: "antigravity",
                    displayName: "Antigravity",
                    shortName: "AGY",
                    source: "agy-statusline",
                    updatedAt: day1,
                    tokens: TokenUsage(
                        periodLabel: "今日 Token",
                        dayKey: QuotaFormatters.dayKey(for: day1, timeZone: tz),
                        total: 1_500_000,
                        input: 1_200_000,
                        output: 300_000
                    ),
                    pools: []
                )
                let sameDay = try expectNotNil(snapshot.displayTokens(for: day1, timeZone: tz))
                try expectEqual(sameDay.total, 1_500_000)
                try expectEqual(sameDay.input, 1_200_000)

                let nextDay = try expectNotNil(snapshot.displayTokens(for: day2, timeZone: tz))
                try expectEqual(nextDay.total, 0)
                try expectNil(nextDay.input)
                try expectNil(nextDay.output)
            }
        ]
    }
}
