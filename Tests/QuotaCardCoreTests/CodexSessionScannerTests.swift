import Foundation
import QuotaCardCore

enum CodexSessionScannerTests {
    static let all: [TestCase] = [
        TestCase(suite: "CodexSessionScannerTests", name: "scansLatestRateLimitsAndTodayTokensIgnoringYesterday") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("quotacard-codex-test-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let tz = TimeZone(secondsFromGMT: 8 * 3600)!
            let yesterdayDir = root.appendingPathComponent("2026/11/25", isDirectory: true)
            let todayDir = root.appendingPathComponent("2026/11/26", isDirectory: true)
            try FileManager.default.createDirectory(at: yesterdayDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: todayDir, withIntermediateDirectories: true)

            // Yesterday file: should NOT be counted in today's tokens
            let yLine = #"{"timestamp":"2026-11-25T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50000,"output_tokens":500,"total_tokens":50500},"last_token_usage":{"input_tokens":50000,"output_tokens":500,"total_tokens":50500}},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":20.0,"window_minutes":300,"resets_at":1795600000},"secondary":{"used_percent":10.0,"window_minutes":10080,"resets_at":1795964055}}}}"#
            let yFile = yesterdayDir.appendingPathComponent("rollout-2026-11-25T18-00-00.jsonl")
            try Data((yLine + "\n").utf8).write(to: yFile)
            let yesterdayMod = ISO8601DateFormatter().date(from: "2026-11-25T10:00:00Z")!
            try FileManager.default.setAttributes([.modificationDate: yesterdayMod], ofItemAtPath: yFile.path)

            // Today file with 2 token_count events
            let tLines = [
                #"{"timestamp":"2026-11-26T02:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100000,"cached_input_tokens":80000,"output_tokens":500,"total_tokens":100500},"last_token_usage":{"input_tokens":100000,"cached_input_tokens":80000,"output_tokens":500,"total_tokens":100500}},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":93.0,"window_minutes":300,"resets_at":1795678288},"secondary":{"used_percent":39.0,"window_minutes":10080,"resets_at":1795964055}}}}"#,
                #"{"timestamp":"2026-11-26T03:55:23.763Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":180000,"cached_input_tokens":150000,"output_tokens":700,"total_tokens":180700},"last_token_usage":{"input_tokens":80000,"cached_input_tokens":70000,"output_tokens":200,"total_tokens":80200}},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":99.0,"window_minutes":300,"resets_at":1795678287},"secondary":{"used_percent":40.0,"window_minutes":10080,"resets_at":1795964055}}}}"#
            ].joined(separator: "\n") + "\n"
            let tFile = todayDir.appendingPathComponent("rollout-2026-11-26T10-00-00.jsonl")
            try Data(tLines.utf8).write(to: tFile)

            let now = ISO8601DateFormatter().date(from: "2026-11-26T07:20:00Z")!
            let report = CodexSessionScanner.scan(sessionsDirectory: root, now: now, timeZone: tz)

            try expectEqual(report.pools.count, 1)
            let pool = report.pools[0]
            try expectEqual(pool.id, "codex")
            try expectEqual(pool.name, "Codex")
            try expect(abs((pool.fiveHour?.remainingPercent ?? -1) - 1.0) < 0.01)
            try expectEqual(Int(pool.fiveHour?.resetAt?.timeIntervalSince1970 ?? 0), 1795678287)
            try expect(abs((pool.weekly?.remainingPercent ?? -1) - 60.0) < 0.01)
            try expectEqual(Int(pool.weekly?.resetAt?.timeIntervalSince1970 ?? 0), 1795964055)
            try expectEqual(pool.tokensUsed, 180_700)

            try expectEqual(report.usage?.total, 180_700)
            try expectEqual(report.usage?.input, 180_000)
            try expectEqual(report.usage?.output, 700)
            try expectEqual(report.usage?.dayKey, "2026-11-26")

            let expectedEventTime = QuotaFormatters.parseISO8601Date("2026-11-26T03:55:23.763Z")!
            let updatedAt = try expectNotNil(report.rateLimitsUpdatedAt)
            try expect(abs(updatedAt.timeIntervalSince1970 - expectedEventTime.timeIntervalSince1970) < 0.05)
        },

        TestCase(suite: "CodexSessionScannerTests", name: "deduplicatesRepeatedTotalTokenSnapshots") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("quotacard-codex-dedup-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let tz = TimeZone(secondsFromGMT: 8 * 3600)!
            let todayDir = root.appendingPathComponent("2026/11/26", isDirectory: true)
            try FileManager.default.createDirectory(at: todayDir, withIntermediateDirectories: true)

            let lines = [
                #"{"timestamp":"2026-11-26T02:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"output_tokens":100,"total_tokens":1100}}}}"#,
                #"{"timestamp":"2026-11-26T02:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"output_tokens":100,"total_tokens":1100}}}}"#,
                #"{"timestamp":"2026-11-26T02:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"output_tokens":150,"total_tokens":1650},"last_token_usage":{"input_tokens":500,"output_tokens":50,"total_tokens":550}}}}"#
            ].joined(separator: "\n") + "\n"
            try Data(lines.utf8).write(to: todayDir.appendingPathComponent("rollout-dup.jsonl"))

            let now = ISO8601DateFormatter().date(from: "2026-11-26T07:20:00Z")!
            let report = CodexSessionScanner.scan(sessionsDirectory: root, now: now, timeZone: tz)
            try expectEqual(report.usage?.total, 1650)
            try expectEqual(report.usage?.input, 1500)
            try expectEqual(report.usage?.output, 150)
        },

        TestCase(suite: "CodexSessionScannerTests", name: "supportsMultipleLimitIdsAndYesterdayFallbackWithoutStaleTokens") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("quotacard-codex-multi-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let tz = TimeZone(secondsFromGMT: 8 * 3600)!
            let yDir = root.appendingPathComponent("2026/11/25", isDirectory: true)
            try FileManager.default.createDirectory(at: yDir, withIntermediateDirectories: true)

            let lines = [
                #"{"timestamp":"2026-11-25T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5000,"output_tokens":200,"total_tokens":5200},"last_token_usage":{"input_tokens":5000,"output_tokens":200,"total_tokens":5200}},"rate_limits":{"limit_id":"codex_spark","limit_name":"GPT-5.3-Codex-Spark","primary":{"used_percent":25.0,"window_minutes":300,"resets_at":1795670000},"secondary":{"used_percent":12.0,"window_minutes":10080,"resets_at":1795960000}}}}"#,
                #"{"timestamp":"2026-11-25T13:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":8000,"output_tokens":300,"total_tokens":8300},"last_token_usage":{"input_tokens":3000,"output_tokens":100,"total_tokens":3100}},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":45.0,"window_minutes":300,"resets_at":1795675000},"secondary":{"used_percent":30.0,"window_minutes":10080,"resets_at":1795965000}}}}"#
            ].joined(separator: "\n") + "\n"
            let yFile = yDir.appendingPathComponent("rollout-2026-11-25.jsonl")
            try Data(lines.utf8).write(to: yFile)
            let yMod = ISO8601DateFormatter().date(from: "2026-11-25T13:00:00Z")!
            try FileManager.default.setAttributes([.modificationDate: yMod], ofItemAtPath: yFile.path)

            let now = ISO8601DateFormatter().date(from: "2026-11-26T07:20:00Z")!
            let report = CodexSessionScanner.scan(sessionsDirectory: root, now: now, timeZone: tz)

            // No tokens today, but both rate_limits pools from yesterday still surface cleanly
            try expectNil(report.usage)
            try expectEqual(report.pools.count, 2)
            try expectEqual(report.pools[0].id, "codex")
            try expect(abs((report.pools[0].fiveHour?.remainingPercent ?? -1) - 55.0) < 0.01)
            try expectEqual(report.pools[1].id, "codex_spark")
            try expectEqual(report.pools[1].name, "GPT-5.3-Codex-Spark")
            try expect(abs((report.pools[1].fiveHour?.remainingPercent ?? -1) - 75.0) < 0.01)
        },

        TestCase(suite: "CodexSessionScannerTests", name: "syncToStorePersistsCodexSnapshotWithAccuratePoolsTimestamp") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("quotacard-codex-sync-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let sessionsDir = root.appendingPathComponent("sessions/2026/11/26", isDirectory: true)
            let storeDir = root.appendingPathComponent("store", isDirectory: true)
            try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

            let line = #"{"timestamp":"2026-11-26T04:10:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":42000,"output_tokens":800,"total_tokens":42800},"last_token_usage":{"input_tokens":42000,"output_tokens":800,"total_tokens":42800}},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":62.5,"window_minutes":300,"resets_at":1795680000},"secondary":{"used_percent":18.0,"window_minutes":10080,"resets_at":1795964055}}}}"#
            try Data((line + "\n").utf8).write(to: sessionsDir.appendingPathComponent("rollout-sync.jsonl"))

            let store = StateStore(baseDirectory: storeDir)
            let tz = TimeZone(secondsFromGMT: 8 * 3600)!
            let now = ISO8601DateFormatter().date(from: "2026-11-26T07:20:00Z")!

            let first = try expectNotNil(
                CodexSessionScanner.syncToStore(store, sessionsDirectory: root.appendingPathComponent("sessions"), now: now, timeZone: tz)
            )
            let snap = try expectNotNil(first.providers["codex"])
            try expectEqual(snap.displayName, "OpenAI Codex")
            try expectEqual(snap.shortName, "Codex")
            try expectEqual(snap.source, "codex sessions")
            try expect(abs((snap.pools.first?.fiveHour?.remainingPercent ?? -1) - 37.5) < 0.01)
            try expectEqual(snap.tokens?.total, 42_800)

            let expectedPoolTime = ISO8601DateFormatter().date(from: "2026-11-26T04:10:00Z")!
            try expect(abs((snap.poolsUpdatedAt?.timeIntervalSince1970 ?? 0) - expectedPoolTime.timeIntervalSince1970) < 0.05)

            // Second sync without changes should be a no-op returning nil
            let second = CodexSessionScanner.syncToStore(store, sessionsDirectory: root.appendingPathComponent("sessions"), now: now, timeZone: tz)
            try expectNil(second)
        },

        TestCase(suite: "CodexSessionScannerTests", name: "sessionsFingerprintDetectsNewSessionActivityWithoutReadingContent") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("quotacard-codex-fp-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let dayDir = root.appendingPathComponent("2026/11/26", isDirectory: true)
            try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

            try expectNil(CodexSessionScanner.sessionsFingerprint(sessionsDirectory: root))

            let file = dayDir.appendingPathComponent("rollout-fp.jsonl")
            try Data("{\"a\":1}\n".utf8).write(to: file)
            let fp1 = try expectNotNil(CodexSessionScanner.sessionsFingerprint(sessionsDirectory: root))
            let fp2 = try expectNotNil(CodexSessionScanner.sessionsFingerprint(sessionsDirectory: root))
            try expectEqual(fp1, fp2)

            // Appending new turn data changes file size -> fingerprint changes immediately
            try Data("{\"a\":1}\n{\"b\":2}\n".utf8).write(to: file)
            let fp3 = try expectNotNil(CodexSessionScanner.sessionsFingerprint(sessionsDirectory: root))
            try expect(fp3 != fp1, "Fingerprint should change when new session data is appended")
        }
    ]
}
