import Foundation
@testable import QuotaCardCore

enum StateStoreTests {
    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quotacard-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var all: [TestCase] {
        [
            TestCase(suite: "StateStoreTests", name: "loadReturnsEmptyStateWhenMissingOrCorrupt") {
                let dir = try makeTempDir()
                defer { try? FileManager.default.removeItem(at: dir) }
                let store = StateStore(baseDirectory: dir)

                try expectEqual(store.load().providers.count, 0)

                // Zero-byte file
                FileManager.default.createFile(atPath: store.stateFileURL.path, contents: Data())
                try expectEqual(store.load().providers.count, 0)

                // Corrupt JSON
                try Data("{broken json".utf8).write(to: store.stateFileURL)
                try expectEqual(store.load().providers.count, 0)

                // Recovers cleanly on next write
                let now = Date(timeIntervalSince1970: 1_764_000_000)
                let update = ProviderUpdate(
                    id: "antigravity",
                    displayName: "Antigravity",
                    shortName: "AGY",
                    source: "agy-statusline",
                    pools: [QuotaPool(id: "gemini", name: "Gemini", fiveHour: QuotaWindow(remainingPercent: 80, resetAt: now.addingTimeInterval(3600)))],
                    tokens: nil,
                    sessionTokenSample: nil,
                    timestamp: now
                )
                _ = try store.applyUpdate(update, timeZone: TimeZone(secondsFromGMT: 0)!)
                try expectEqual(store.load().providers["antigravity"]?.pools.count, 1)
            },
            TestCase(suite: "StateStoreTests", name: "partialMergePreservesPoolsAndTracksStalenessSeparately") {
                let dir = try makeTempDir()
                defer { try? FileManager.default.removeItem(at: dir) }
                let store = StateStore(baseDirectory: dir)
                let tz = TimeZone(secondsFromGMT: 0)!
                let t0 = Date(timeIntervalSince1970: 1_764_000_000)

                _ = try store.applyUpdate(
                    ProviderUpdate(
                        id: "antigravity",
                        displayName: "Antigravity",
                        shortName: "AGY",
                        source: "agy-statusline",
                        pools: [QuotaPool(id: "gemini", name: "Gemini", fiveHour: QuotaWindow(remainingPercent: 78, resetAt: t0.addingTimeInterval(7200)))],
                        tokens: nil,
                        sessionTokenSample: nil,
                        timestamp: t0
                    ),
                    timeZone: tz
                )

                let t1 = t0.addingTimeInterval(40 * 60)
                let merged = try store.applyUpdate(
                    ProviderUpdate(
                        id: "antigravity",
                        displayName: "Antigravity",
                        shortName: "AGY",
                        source: "agy-statusline",
                        pools: nil,
                        tokens: TokenUsage(periodLabel: "今日 Token", dayKey: "2025-11-24", total: 50_000, input: 40_000, output: 10_000),
                        sessionTokenSample: nil,
                        timestamp: t1
                    ),
                    timeZone: tz
                )

                let agy = try expectNotNil(merged.providers["antigravity"])
                try expectEqual(agy.pools.count, 1)
                try expectEqual(agy.pools[0].fiveHour?.remainingPercent, 78)
                try expectEqual(agy.tokens?.total, 50_000)
                try expectEqual(agy.poolsUpdatedAt, t0)
                try expectEqual(agy.tokensUpdatedAt, t1)
                try expectEqual(agy.isPoolsStale(now: t1, threshold: 30 * 60), true)
            },
            TestCase(suite: "StateStoreTests", name: "partialMergePreservesTokensWhenPoolsOnlyUpdateArrives") {
                let dir = try makeTempDir()
                defer { try? FileManager.default.removeItem(at: dir) }
                let store = StateStore(baseDirectory: dir)
                let tz = TimeZone(secondsFromGMT: 0)!
                let t0 = Date(timeIntervalSince1970: 1_764_000_000)

                _ = try store.applyUpdate(
                    ProviderUpdate(
                        id: "claude",
                        displayName: "Claude Code",
                        shortName: "Claude",
                        source: "claude-statusline",
                        pools: nil,
                        tokens: TokenUsage(periodLabel: "今日 Token", dayKey: "2025-11-24", total: 120_000, input: 100_000, output: 20_000),
                        sessionTokenSample: nil,
                        timestamp: t0
                    ),
                    timeZone: tz
                )

                let t1 = t0.addingTimeInterval(600)
                let merged = try store.applyUpdate(
                    ProviderUpdate(
                        id: "claude",
                        displayName: "Claude Code",
                        shortName: "Claude",
                        source: "claude-statusline",
                        pools: [QuotaPool(id: "claude-code", name: "Claude Code", fiveHour: QuotaWindow(remainingPercent: 68, resetAt: t1.addingTimeInterval(3600)))],
                        tokens: nil,
                        sessionTokenSample: nil,
                        timestamp: t1
                    ),
                    timeZone: tz
                )

                let claude = try expectNotNil(merged.providers["claude"])
                try expectEqual(claude.tokens?.total, 120_000)
                try expectEqual(claude.tokensUpdatedAt, t0)
                try expectEqual(claude.poolsUpdatedAt, t1)
                try expectEqual(claude.pools.count, 1)
            },
            TestCase(suite: "StateStoreTests", name: "sessionTokenHighWaterAggregationDeduplicatesAndRollsOverDay") {
                let dir = try makeTempDir()
                defer { try? FileManager.default.removeItem(at: dir) }
                let store = StateStore(baseDirectory: dir)
                let tz = TimeZone(secondsFromGMT: 0)!
                let day1 = Date(timeIntervalSince1970: 1_764_000_000)

                _ = try store.applyUpdate(
                    ProviderUpdate(
                        id: "claude",
                        displayName: "Claude Code",
                        shortName: "Claude",
                        source: "claude-statusline",
                        pools: nil,
                        tokens: nil,
                        sessionTokenSample: SessionTokenSample(sessionId: "s1", inputTokens: 1_000, outputTokens: 200, totalTokens: nil),
                        timestamp: day1
                    ),
                    timeZone: tz
                )

                _ = try store.applyUpdate(
                    ProviderUpdate(
                        id: "claude",
                        displayName: "Claude Code",
                        shortName: "Claude",
                        source: "claude-statusline",
                        pools: nil,
                        tokens: nil,
                        sessionTokenSample: SessionTokenSample(sessionId: "s1", inputTokens: 2_500, outputTokens: 500, totalTokens: nil),
                        timestamp: day1.addingTimeInterval(60)
                    ),
                    timeZone: tz
                )

                let afterS2 = try store.applyUpdate(
                    ProviderUpdate(
                        id: "claude",
                        displayName: "Claude Code",
                        shortName: "Claude",
                        source: "claude-statusline",
                        pools: nil,
                        tokens: nil,
                        sessionTokenSample: SessionTokenSample(sessionId: "s2", inputTokens: 400, outputTokens: 100, totalTokens: nil),
                        timestamp: day1.addingTimeInterval(120)
                    ),
                    timeZone: tz
                )

                try expectEqual(afterS2.providers["claude"]?.tokens?.total, 3_500)
                try expectEqual(afterS2.providers["claude"]?.tokens?.input, 2_900)
                try expectEqual(afterS2.providers["claude"]?.tokens?.output, 600)

                // Next day resets daily total
                let day2 = day1.addingTimeInterval(86_400)
                let afterDay2 = try store.applyUpdate(
                    ProviderUpdate(
                        id: "claude",
                        displayName: "Claude Code",
                        shortName: "Claude",
                        source: "claude-statusline",
                        pools: nil,
                        tokens: nil,
                        sessionTokenSample: SessionTokenSample(sessionId: "s3", inputTokens: 100, outputTokens: 50, totalTokens: nil),
                        timestamp: day2
                    ),
                    timeZone: tz
                )
                try expectEqual(afterDay2.providers["claude"]?.tokens?.total, 150)
                try expectEqual(afterDay2.providers["claude"]?.tokens?.input, 100)
                try expectEqual(afterDay2.providers["claude"]?.tokens?.output, 50)
            },
            TestCase(suite: "StateStoreTests", name: "concurrentUpdatesDoNotCorruptStateJSON") {
                let dir = try makeTempDir()
                defer { try? FileManager.default.removeItem(at: dir) }
                let store = StateStore(baseDirectory: dir)
                let tz = TimeZone(secondsFromGMT: 0)!
                let now = Date(timeIntervalSince1970: 1_764_000_000)

                try await withThrowingTaskGroup(of: Void.self) { group in
                    for i in 0..<12 {
                        let pid = ["antigravity", "claude", "codex"][i % 3]
                        group.addTask {
                            _ = try store.applyUpdate(
                                ProviderUpdate(
                                    id: pid,
                                    displayName: pid,
                                    shortName: pid,
                                    source: "test",
                                    pools: [QuotaPool(id: "p1", name: "Pool", fiveHour: QuotaWindow(remainingPercent: Double(50 + i), resetAt: now.addingTimeInterval(3600)))],
                                    tokens: nil,
                                    sessionTokenSample: nil,
                                    timestamp: now.addingTimeInterval(Double(i))
                                ),
                                timeZone: tz
                            )
                        }
                    }
                    try await group.waitForAll()
                }

                let finalState = store.load()
                try expectEqual(finalState.providers.count, 3)
                _ = try expectNotNil(finalState.providers["antigravity"])
                _ = try expectNotNil(finalState.providers["claude"])
                _ = try expectNotNil(finalState.providers["codex"])
            }
        ]
    }
}
