import Foundation
@testable import QuotaCardCore

enum IngestCLIIntegrationTests {
    static func ingestBinaryURL() -> URL {
        URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("quota-card-ingest")
    }

    static func runIngest(args: [String], stdin: String) throws -> (exitCode: Int32, stdout: String) {
        let proc = Process()
        proc.executableURL = ingestBinaryURL()
        proc.arguments = args

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = Pipe()

        try proc.run()
        let writeHandle = inPipe.fileHandleForWriting
        let inputBytes = Data(stdin.utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            if !inputBytes.isEmpty {
                try? writeHandle.write(contentsOf: inputBytes)
            }
            try? writeHandle.close()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        return (proc.terminationStatus, stdout)
    }

    static var all: [TestCase] {
        [
            TestCase(suite: "IngestCLIIntegrationTests", name: "ingestValidClaudePayloadUpdatesStateAndPrintsStatusline") {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quotacard-ingest-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }

                let resetEpoch = Int(Date().addingTimeInterval(7200).timeIntervalSince1970)
                let payload = """
                {"session_id":"s-int","context_window":{"total_input_tokens":50000,"total_output_tokens":10000},"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":\(resetEpoch)}}}
                """
                let (code, stdout) = try runIngest(
                    args: ["--provider", "claude", "--quota-dir", dir.path, "--print-statusline"],
                    stdin: payload
                )
                try expectEqual(code, 0)
                try expect(stdout.contains("80%"), "Expected stdout to include 80%, got: \(stdout)")

                let state = StateStore(baseDirectory: dir).load()
                let claude = try expectNotNil(state.providers["claude"])
                try expectEqual(claude.pools.first?.fiveHour?.remainingPercent, 80.0)
                try expectEqual(claude.tokens?.total, 60_000)
            },
            TestCase(suite: "IngestCLIIntegrationTests", name: "ingestMalformedInputExitsZeroWithoutCrashing") {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quotacard-ingest-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }

                let (code, _) = try runIngest(
                    args: ["--provider", "antigravity", "--quota-dir", dir.path, "--print-statusline"],
                    stdin: "not valid json at all"
                )
                try expectEqual(code, 0)
            },
            TestCase(suite: "IngestCLIIntegrationTests", name: "ingestForwardsStdinToChainedCommand") {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quotacard-ingest-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }

                // Write chain.json pointing claude to /bin/cat
                let chainURL = dir.appendingPathComponent("chain.json")
                try Data(#"{"claude":"/bin/cat"}"#.utf8).write(to: chainURL)

                let rawInput = #"{"session_id":"s-chain","context_window":{"total_input_tokens":123,"total_output_tokens":45}}"#
                let (code, stdout) = try runIngest(
                    args: ["--provider", "claude", "--quota-dir", dir.path, "--print-statusline"],
                    stdin: rawInput
                )
                try expectEqual(code, 0)
                try expectEqual(stdout, rawInput)
                try expectEqual(StateStore(baseDirectory: dir).load().providers["claude"]?.tokens?.total, 168)
            },
            TestCase(suite: "IngestCLIIntegrationTests", name: "ingestChainedCommandFastExitAndLargeStdoutDoNotCrashOrDeadlock") {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quotacard-ingest-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }

                let chainURL = dir.appendingPathComponent("chain.json")
                // 1) Fast-exit command ignoring large stdin (> 100KB) to test SIGPIPE / EPIPE safety
                try Data(#"{"claude":"echo fast-exit"}"#.utf8).write(to: chainURL)
                let largePayload = "{\"session_id\":\"s-big\",\"padding\":\"" + String(repeating: "a", count: 120_000) + "\",\"context_window\":{\"total_input_tokens\":10,\"total_output_tokens\":5}}"
                let (code1, out1) = try runIngest(
                    args: ["--provider", "claude", "--quota-dir", dir.path, "--print-statusline"],
                    stdin: largePayload
                )
                try expectEqual(code1, 0)
                try expectEqual(out1.trimmingCharacters(in: .whitespacesAndNewlines), "fast-exit")

                // 2) Chained command emitting > 100KB stdout to test pipe deadlock safety
                try Data(#"{"claude":"head -c 100000 /dev/zero | tr '\\0' 'x'"}"#.utf8).write(to: chainURL)
                let (code2, out2) = try runIngest(
                    args: ["--provider", "claude", "--quota-dir", dir.path, "--print-statusline"],
                    stdin: "{}"
                )
                try expectEqual(code2, 0)
                try expectEqual(out2.count, 100_000)
            },
            TestCase(suite: "IngestCLIIntegrationTests", name: "ingestHonorsDebugSchemaMarkerFile") {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quotacard-ingest-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }

                let marker = dir.appendingPathComponent("debug-schema-enabled")
                try Data("1".utf8).write(to: marker)

                let (code, _) = try runIngest(
                    args: ["--provider", "antigravity", "--quota-dir", dir.path],
                    stdin: #"{"secret_prompt":"DO_NOT_LEAK","groups":[{"name":"Gemini","remaining_fraction":0.9}]}"#
                )
                try expectEqual(code, 0)
                let logURL = dir.appendingPathComponent("debug-schema.log")
                try expect(FileManager.default.fileExists(atPath: logURL.path), "Expected debug-schema.log to be written when marker exists")
                let logText = try String(contentsOf: logURL, encoding: .utf8)
                try expect(logText.contains("remaining_fraction"))
                try expect(!logText.contains("DO_NOT_LEAK"))
            }
        ]
    }
}
