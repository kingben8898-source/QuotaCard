import Foundation
@testable import QuotaCardCore

enum PayloadParserTests {
    static var all: [TestCase] {
        [
            TestCase(suite: "PayloadParserTests", name: "parseClaudeCodeStatuslineJSON") {
                let now = Date(timeIntervalSince1970: 1_764_000_000)
                let fiveReset = Int(now.addingTimeInterval(7200).timeIntervalSince1970)
                let sevenReset = Int(now.addingTimeInterval(300_000).timeIntervalSince1970)
                let json = """
                {
                  "session_id": "sess-abc",
                  "model": { "display_name": "Opus 4.6" },
                  "context_window": {
                    "total_input_tokens": 910000,
                    "total_output_tokens": 210000
                  },
                  "rate_limits": {
                    "five_hour": { "used_percentage": 32.0, "resets_at": \(fiveReset) },
                    "seven_day": { "used_percentage": 42.0, "resets_at": \(sevenReset) }
                  }
                }
                """
                let update = try expectNotNil(PayloadParser.parse(providerId: "claude", data: Data(json.utf8), now: now))
                try expectEqual(update.id, "claude")
                try expectEqual(update.shortName, "Claude")
                let pools = try expectNotNil(update.pools)
                try expectEqual(pools.count, 1)
                try expectEqual(pools[0].fiveHour?.remainingPercent, 68.0)
                try expectEqual(pools[0].weekly?.remainingPercent, 58.0)
                let sample = try expectNotNil(update.sessionTokenSample)
                try expectEqual(sample.sessionId, "sess-abc")
                try expectEqual(sample.inputTokens, 910_000)
                try expectEqual(sample.outputTokens, 210_000)
            },
            TestCase(suite: "PayloadParserTests", name: "parseAntigravityDefensiveVariants") {
                let now = Date(timeIntervalSince1970: 1_764_000_000)
                let json = """
                {
                  "session_id": "agy-1",
                  "usage": {
                    "input_tokens": 1540000,
                    "output_tokens": 480000
                  },
                  "groups": [
                    {
                      "id": "gemini",
                      "name": "Gemini",
                      "remaining_fraction": 0.78,
                      "reset_time": "2026-11-25T12:57:00Z",
                      "weekly_remaining_fraction": 0.65,
                      "weekly_reset_time": "2026-11-29T00:00:00Z",
                      "tokens_used": 1070000
                    },
                    {
                      "id": "claude-gpt",
                      "name": "Claude / GPT",
                      "remainingFraction": 0.32,
                      "resetTime": "2026-11-25T12:24:00Z",
                      "weekly": { "remainingPercent": 48, "resetAt": "2026-11-29T00:00:00Z" }
                    },
                    {
                      "id": "gemini-4-argon",
                      "name": "Gemini 4 Argon",
                      "weekly": { "remaining_fraction": 0.94, "reset_time": "2026-11-29T00:00:00Z" }
                    }
                  ]
                }
                """
                let update = try expectNotNil(PayloadParser.parse(providerId: "antigravity", data: Data(json.utf8), now: now))
                try expectEqual(update.shortName, "AGY")
                let pools = try expectNotNil(update.pools)
                try expectEqual(pools.count, 3)
                try expectEqual(pools[0].name, "Gemini")
                try expectEqual(pools[0].fiveHour?.remainingPercent, 78.0)
                try expectEqual(pools[0].weekly?.remainingPercent, 65.0)
                try expectEqual(pools[0].tokensUsed, 1_070_000)
                try expectEqual(pools[1].fiveHour?.remainingPercent, 32.0)
                try expectEqual(pools[1].weekly?.remainingPercent, 48.0)
                try expectNil(pools[2].fiveHour)
                try expectEqual(pools[2].weekly?.remainingPercent, 94.0)
                let sample = try expectNotNil(update.sessionTokenSample)
                try expectEqual(sample.inputTokens, 1_540_000)
                try expectEqual(sample.outputTokens, 480_000)
            },
            TestCase(suite: "PayloadParserTests", name: "parseCodexRateLimitsJSON") {
                let now = Date(timeIntervalSince1970: 1_764_000_000)
                let json = """
                {
                  "rateLimits": {
                    "limitId": "codex",
                    "primary": { "usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1764014400 },
                    "secondary": { "usedPercent": 18, "windowDurationMins": 10080, "resetsAt": 1764500000 }
                  }
                }
                """
                let update = try expectNotNil(PayloadParser.parse(providerId: "codex", data: Data(json.utf8), now: now))
                let pools = try expectNotNil(update.pools)
                try expectEqual(pools.count, 1)
                try expectEqual(pools[0].fiveHour?.remainingPercent, 75.0)
                try expectEqual(pools[0].weekly?.remainingPercent, 82.0)
            },
            TestCase(suite: "PayloadParserTests", name: "parseGenericProviderSnapshotJSON") {
                let now = Date(timeIntervalSince1970: 1_764_000_000)
                let json = """
                {
                  "displayName": "Gemini Web",
                  "shortName": "Gemini",
                  "source": "chrome-extension",
                  "pools": [
                    {
                      "id": "gemini-web-main",
                      "name": "Gemini Web",
                      "fiveHour": { "remainingPercent": 85, "resetAt": "2026-11-25T15:00:00Z" }
                    }
                  ]
                }
                """
                let update = try expectNotNil(PayloadParser.parse(providerId: "gemini-web", data: Data(json.utf8), now: now))
                try expectEqual(update.displayName, "Gemini Web")
                try expectEqual(update.shortName, "Gemini")
                try expectEqual(update.pools?.first?.fiveHour?.remainingPercent, 85.0)
            },
            TestCase(suite: "PayloadParserTests", name: "malformedAndEmptyJSONReturnsNilGracefully") {
                let now = Date()
                try expectNil(PayloadParser.parse(providerId: "antigravity", data: Data(), now: now))
                try expectNil(PayloadParser.parse(providerId: "antigravity", data: Data("hello world".utf8), now: now))
                try expectNil(PayloadParser.parse(providerId: "antigravity", data: Data("{broken".utf8), now: now))
            },
            TestCase(suite: "PayloadParserTests", name: "redactSchemaSummaryNeverLeaksValues") {
                let json = """
                {"prompt":"TOP_SECRET_PASSWORD_123","rate_limits":{"five_hour":{"used_percentage":15.5}}}
                """
                let summary = try expectNotNil(PayloadParser.redactSchemaSummary(from: Data(json.utf8)))
                try expect(!summary.contains("TOP_SECRET_PASSWORD_123"))
                try expect(summary.contains("rate_limits"))
                try expect(summary.contains("used_percentage"))
            },
            TestCase(suite: "PayloadParserTests", name: "parseRealAgyHeadlessUsageCommandJSON") {
                let now = Date(timeIntervalSince1970: 1_764_045_600)
                let json = """
                {
                  "conversation_id": "",
                  "status": "SUCCESS",
                  "duration_seconds": 0,
                  "num_turns": 0,
                  "usage": {"input_tokens": 0, "output_tokens": 0, "thinking_tokens": 0, "cache_read_tokens": 0, "total_tokens": 0},
                  "command": {
                    "name": "usage",
                    "data": {
                      "groups": [
                        {
                          "name": "Gemini Models",
                          "buckets": [
                            {"id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.931046, "reset_time": "2026-12-02T01:34:35Z"},
                            {"id": "gemini-5h", "window": "5h", "remaining_fraction": 0.744184, "reset_time": "2026-11-25T06:34:35Z"}
                          ]
                        },
                        {
                          "name": "Claude and GPT models",
                          "buckets": [
                            {"id": "3p-weekly", "window": "weekly", "remaining_fraction": 0.003573, "reset_time": "2026-11-27T14:43:12Z"},
                            {"id": "3p-5h", "window": "5h", "remaining_fraction": 1, "reset_time": "2026-11-25T09:41:36Z"}
                          ]
                        }
                      ]
                    }
                  }
                }
                """
                let update = try expectNotNil(PayloadParser.parse(providerId: "antigravity", data: Data(json.utf8), now: now))
                try expectEqual(update.id, "antigravity")
                try expectEqual(update.shortName, "AGY")
                try expectNil(update.sessionTokenSample) // all-zero usage from headless /usage must NOT emit token sample
                let pools = try expectNotNil(update.pools)
                try expectEqual(pools.count, 2)
                try expectEqual(pools[0].name, "Gemini")
                try expect(abs((pools[0].fiveHour?.remainingPercent ?? 0) - 74.4184) < 0.01)
                try expect(abs((pools[0].weekly?.remainingPercent ?? 0) - 93.1046) < 0.01)
                _ = try expectNotNil(pools[0].fiveHour?.resetAt)
                _ = try expectNotNil(pools[0].weekly?.resetAt)

                try expectEqual(pools[1].name, "Claude / GPT")
                try expectEqual(pools[1].fiveHour?.remainingPercent, 100.0)
                try expect(abs((pools[1].weekly?.remainingPercent ?? 0) - 0.3573) < 0.01)
            }
        ]
    }
}
