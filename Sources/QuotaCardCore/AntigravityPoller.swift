import Darwin
import Foundation

public enum AntigravityPollResult: Sendable {
    case updated(QuotaState)
    case skippedAlreadyRunning
    case binaryNotFound
    case failed(String)
}

public final class AntigravityPoller: @unchecked Sendable {
    private let store: StateStore
    private let configurator: CLIConfigurator
    private let lock = NSLock()
    private var isRunning = false

    public init(store: StateStore, configurator: CLIConfigurator) {
        self.store = store
        self.configurator = configurator
    }

    public func pollNow(timeoutSeconds: TimeInterval = 35) async -> AntigravityPollResult {
        guard let agyPath = configurator.detectStatus(for: .antigravity).binaryPath else {
            return .binaryNotFound
        }

        let acquired: Bool = lock.withLock {
            if isRunning { return false }
            isRunning = true
            return true
        }
        guard acquired else { return .skippedAlreadyRunning }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .failed("poller_deallocated"))
                    return
                }
                defer {
                    self.lock.withLock { self.isRunning = false }
                }

                let result = self.executeAgyUsage(binaryPath: agyPath, timeoutSeconds: timeoutSeconds)
                continuation.resume(returning: result)
            }
        }
    }

    /// Lightweight local-only refresh of today's Antigravity token totals from documented transcript logs.
    @discardableResult
    public func refreshLocalTokensOnly(now: Date = Date()) -> QuotaState? {
        let tokenReport = TranscriptTokenScanner.scanAntigravityToday(now: now)
        guard let usage = tokenReport.usage else { return nil }

        let current = store.load()
        guard let existing = current.providers["antigravity"] else { return nil }

        // Only write if token total actually changed
        if existing.tokens?.total == usage.total && existing.tokens?.dayKey == usage.dayKey {
            return nil
        }

        var updatedPools = existing.pools
        for idx in updatedPools.indices {
            let key = updatedPools[idx].name.lowercased().contains("claude") || updatedPools[idx].name.lowercased().contains("gpt")
                ? "claude-gpt"
                : "gemini"
            if let tok = tokenReport.poolTokens[key], tok > 0 {
                updatedPools[idx].tokensUsed = tok
            }
        }

        // Preserve existing poolsUpdatedAt by only sending tokens if pools didn't change,
        // or updating tokens cleanly via StateStore.
        let update = ProviderUpdate(
            id: "antigravity",
            displayName: existing.displayName,
            shortName: existing.shortName,
            source: existing.source,
            pools: nil,
            tokens: usage,
            sessionTokenSample: nil,
            timestamp: now
        )
        return try? store.applyUpdate(update)
    }

    private func executeAgyUsage(binaryPath: String, timeoutSeconds: TimeInterval) -> AntigravityPollResult {
        // Use a temporary output file instead of a Pipe() so any background descendant
        // spawned by `agy` (e.g. language_server) cannot inherit stdout and block EOF forever.
        let tempOutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotacard-agy-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: tempOutURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tempOutURL) }

        guard let outHandle = try? FileHandle(forWritingTo: tempOutURL) else {
            return .failed("无法创建临时输出文件")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["-p", "/usage", "--output-format", "json"]

        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            "/usr/bin",
            "/bin"
        ]
        let existingPath = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + [existingPath]).filter { !$0.isEmpty }.joined(separator: ":")
        proc.environment = env

        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = outHandle
        proc.standardError = FileHandle.nullDevice

        let timedOutFlag = NSLock()
        var didTimeout = false
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler {
            timedOutFlag.withLock { didTimeout = true }
            if proc.isRunning {
                proc.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
                    if proc.isRunning {
                        kill(proc.processIdentifier, SIGKILL)
                    }
                }
            }
        }

        do {
            try proc.run()
            timer.resume()
            proc.waitUntilExit()
            timer.cancel()
            try? outHandle.close()

            let wasTimeout = timedOutFlag.withLock { didTimeout }
            if wasTimeout {
                logPoll("timeout after \(Int(timeoutSeconds))s")
                return .failed("agy /usage 请求超时（>\(Int(timeoutSeconds))秒）")
            }

            let stdoutData = (try? Data(contentsOf: tempOutURL)) ?? Data()
            guard let jsonData = extractJSONPayload(from: stdoutData) else {
                logPoll("invalid JSON exit=\(proc.terminationStatus) bytes=\(stdoutData.count)")
                return .failed("agy /usage 未返回有效 JSON（退出码 \(proc.terminationStatus)）")
            }

            guard var update = PayloadParser.parse(providerId: "antigravity", data: jsonData, now: Date()) else {
                logPoll("parse failed")
                return .failed("无法解析 agy /usage 返回的额度数据")
            }

            // Enrich with real today's Antigravity token usage from documented local transcripts
            let tokenReport = TranscriptTokenScanner.scanAntigravityToday(now: update.timestamp)
            if let usage = tokenReport.usage {
                update.tokens = usage
            }
            if var pools = update.pools {
                for idx in pools.indices {
                    let key = pools[idx].name.lowercased().contains("claude") || pools[idx].name.lowercased().contains("gpt")
                        ? "claude-gpt"
                        : "gemini"
                    if let tok = tokenReport.poolTokens[key], tok > 0 {
                        pools[idx].tokensUsed = tok
                    }
                }
                update.pools = pools
            }

            let updatedState = try store.applyUpdate(update)
            logPoll("ok pools=\(update.pools?.count ?? 0) tokens=\(update.tokens?.total ?? 0)")
            return .updated(updatedState)
        } catch {
            timer.cancel()
            try? outHandle.close()
            logPoll("error=\(error.localizedDescription)")
            return .failed("执行 agy /usage 失败：\(error.localizedDescription)")
        }
    }

    private func extractJSONPayload(from data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        if (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: .newlines).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"), let candidate = trimmed.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: candidate)) != nil {
                return candidate
            }
        }
        return nil
    }

    private func logPoll(_ message: String) {
        let logURL = store.baseDirectory.appendingPathComponent("poller.log")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        try? FileManager.default.createDirectory(at: store.baseDirectory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }
}
