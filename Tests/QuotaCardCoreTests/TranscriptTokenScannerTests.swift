import Foundation
@testable import QuotaCardCore

enum TranscriptTokenScannerTests {
    static var all: [TestCase] {
        [
            TestCase(suite: "TranscriptTokenScannerTests", name: "scansTodayTokensAndSplitsByPoolIgnoringYesterday") {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("quotacard-brain-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: root) }

                let conv1Logs = root
                    .appendingPathComponent("conv-1", isDirectory: true)
                    .appendingPathComponent(".system_generated/logs", isDirectory: true)
                let conv2Logs = root
                    .appendingPathComponent("conv-2", isDirectory: true)
                    .appendingPathComponent(".system_generated/logs", isDirectory: true)
                try FileManager.default.createDirectory(at: conv1Logs, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: conv2Logs, withIntermediateDirectories: true)

                let jsonl1 = """
                {"step_index":0,"type":"USER_INPUT","created_at":"2026-11-25T01:00:00Z","content":"hi"}
                {"step_index":1,"type":"PLANNER_RESPONSE","created_at":"2026-11-25T01:34:34Z","model":"gemini-4-neon-high","input_tokens":15000,"cache_read_tokens":5000,"output_tokens":500}
                {"step_index":2,"type":"PLANNER_RESPONSE","created_at":"2026-11-24T10:00:00Z","model":"gemini-4-neon-high","input_tokens":999999,"cache_read_tokens":0,"output_tokens":999}
                not-valid-json-line
                """
                let jsonl2 = """
                {"step_index":1,"type":"PLANNER_RESPONSE","created_at":"2026-11-25T04:10:00Z","model":"claude-sonnet-5-5","input_tokens":10000,"cache_read_tokens":2000,"output_tokens":1000}
                """
                try Data(jsonl1.utf8).write(to: conv1Logs.appendingPathComponent("transcript.jsonl"))
                try Data(jsonl2.utf8).write(to: conv2Logs.appendingPathComponent("transcript.jsonl"))

                let tz = TimeZone(secondsFromGMT: 8 * 3600)!
                let now = QuotaFormatters.parseISO8601Date("2026-11-25T05:00:00Z")! // 2026-11-25 13:00 +08
                let report = TranscriptTokenScanner.scanAntigravityToday(brainDirectory: root, now: now, timeZone: tz)

                let usage = try expectNotNil(report.usage)
                // conv1: in 15000+5000=20000, out 500; conv2: in 10000+2000=12000, out 1000 -> total in=32000, out=1500, total=33500
                try expectEqual(usage.input, 32_000)
                try expectEqual(usage.output, 1_500)
                try expectEqual(usage.total, 33_500)
                try expectEqual(report.poolTokens["gemini"], 20_500)
                try expectEqual(report.poolTokens["claude-gpt"], 13_000)
            }
        ]
    }
}
