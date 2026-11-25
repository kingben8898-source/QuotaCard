import Darwin
import Foundation

public struct SessionTokenSample: Codable, Equatable, Sendable {
    public var sessionId: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int?

    public init(sessionId: String, inputTokens: Int, outputTokens: Int, totalTokens: Int? = nil) {
        self.sessionId = sessionId
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.totalTokens = totalTokens.map { max(0, $0) }
    }

    public var resolvedTotal: Int {
        if let totalTokens {
            return max(totalTokens, inputTokens + outputTokens)
        }
        return inputTokens + outputTokens
    }
}

public struct ProviderUpdate: Sendable {
    public var id: String
    public var displayName: String
    public var shortName: String
    public var source: String
    public var pools: [QuotaPool]?
    public var tokens: TokenUsage?
    public var sessionTokenSample: SessionTokenSample?
    public var timestamp: Date

    public init(
        id: String,
        displayName: String,
        shortName: String,
        source: String,
        pools: [QuotaPool]? = nil,
        tokens: TokenUsage? = nil,
        sessionTokenSample: SessionTokenSample? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.shortName = shortName
        self.source = source
        self.pools = pools
        self.tokens = tokens
        self.sessionTokenSample = sessionTokenSample
        self.timestamp = timestamp
    }
}

private struct DailySessionLedger: Codable {
    // providerId -> dayKey -> sessionId -> high-water mark sample
    var providers: [String: [String: [String: SessionTokenSample]]] = [:]
}

public final class StateStore: @unchecked Sendable {
    public let baseDirectory: URL
    public let stateFileURL: URL
    public let dailySessionsFileURL: URL
    private let lockFileURL: URL
    private let processLock = NSLock()

    public init(baseDirectory: URL = StateStore.defaultDirectory()) {
        self.baseDirectory = baseDirectory
        self.stateFileURL = baseDirectory.appendingPathComponent("state.json")
        self.dailySessionsFileURL = baseDirectory.appendingPathComponent("daily-sessions.json")
        self.lockFileURL = baseDirectory.appendingPathComponent(".state.lock")
    }

    public static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".quota-card", isDirectory: true)
    }

    public func load() -> QuotaState {
        guard let data = try? Data(contentsOf: stateFileURL), !data.isEmpty else {
            return QuotaState(version: 1, updatedAt: Date(), providers: [:])
        }
        let decoder = QuotaJSONCoding.makeDecoder()
        if let decoded = try? decoder.decode(QuotaState.self, from: data) {
            return decoded
        }
        return QuotaState(version: 1, updatedAt: Date(), providers: [:])
    }

    @discardableResult
    public func applyUpdate(_ update: ProviderUpdate, timeZone: TimeZone = .current) throws -> QuotaState {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        return try withExclusiveLock {
            var state = load()
            let existing = state.providers[update.id]
            let todayKey = QuotaFormatters.dayKey(for: update.timestamp, timeZone: timeZone)

            var mergedPools = existing?.pools ?? []
            var mergedPoolsUpdatedAt = existing?.poolsUpdatedAt
            if let incomingPools = update.pools {
                mergedPools = incomingPools
                mergedPoolsUpdatedAt = update.timestamp
            }

            var mergedTokens = existing?.tokens
            var mergedTokensUpdatedAt = existing?.tokensUpdatedAt

            if let sample = update.sessionTokenSample {
                let aggregated = try recordSessionSample(
                    providerId: update.id,
                    dayKey: todayKey,
                    sample: sample
                )
                mergedTokens = aggregated
                mergedTokensUpdatedAt = update.timestamp
            } else if let incomingTokens = update.tokens {
                mergedTokens = incomingTokens
                mergedTokensUpdatedAt = update.timestamp
            }

            let resolvedUpdatedAt = [existing?.updatedAt, mergedPoolsUpdatedAt, mergedTokensUpdatedAt, update.timestamp]
                .compactMap { $0 }
                .max() ?? update.timestamp

            let snapshot = ProviderSnapshot(
                id: update.id,
                displayName: update.displayName.isEmpty ? (existing?.displayName ?? update.id) : update.displayName,
                shortName: update.shortName.isEmpty ? (existing?.shortName ?? update.id) : update.shortName,
                source: update.source.isEmpty ? (existing?.source ?? "unknown") : update.source,
                updatedAt: resolvedUpdatedAt,
                poolsUpdatedAt: mergedPoolsUpdatedAt,
                tokensUpdatedAt: mergedTokensUpdatedAt,
                tokens: mergedTokens,
                pools: mergedPools
            )

            state.version = 1
            state.updatedAt = max(state.updatedAt, resolvedUpdatedAt)
            state.providers[update.id] = snapshot

            try writeAtomicJSON(state, to: stateFileURL)
            return state
        }
    }

    private func recordSessionSample(providerId: String, dayKey: String, sample: SessionTokenSample) throws -> TokenUsage {
        var ledger = loadDailySessionLedger()
        var providerDays = ledger.providers[providerId] ?? [:]

        // Keep only the active day to prevent unbounded growth and ensure clean rollover
        var daySessions = providerDays[dayKey] ?? [:]
        if let prev = daySessions[sample.sessionId] {
            let maxIn = max(prev.inputTokens, sample.inputTokens)
            let maxOut = max(prev.outputTokens, sample.outputTokens)
            let maxTotal = max(prev.resolvedTotal, sample.resolvedTotal)
            daySessions[sample.sessionId] = SessionTokenSample(
                sessionId: sample.sessionId,
                inputTokens: maxIn,
                outputTokens: maxOut,
                totalTokens: maxTotal
            )
        } else {
            daySessions[sample.sessionId] = sample
        }

        providerDays = [dayKey: daySessions]
        ledger.providers[providerId] = providerDays
        try writeAtomicJSON(ledger, to: dailySessionsFileURL)

        let totalInput = daySessions.values.reduce(0) { $0 + $1.inputTokens }
        let totalOutput = daySessions.values.reduce(0) { $0 + $1.outputTokens }
        let totalAll = daySessions.values.reduce(0) { $0 + $1.resolvedTotal }

        return TokenUsage(
            periodLabel: "今日 Token",
            dayKey: dayKey,
            total: totalAll,
            input: totalInput,
            output: totalOutput
        )
    }

    private func loadDailySessionLedger() -> DailySessionLedger {
        guard let data = try? Data(contentsOf: dailySessionsFileURL), !data.isEmpty else {
            return DailySessionLedger()
        }
        return (try? QuotaJSONCoding.makeDecoder().decode(DailySessionLedger.self, from: data)) ?? DailySessionLedger()
    }

    private func writeAtomicJSON<T: Encodable>(_ value: T, to destination: URL) throws {
        let encoder = QuotaJSONCoding.makeEncoder()
        let data = try encoder.encode(value)
        let tempURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        }
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }

        let fd = open(lockFileURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        if fd < 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "Unable to open lock file at \(lockFileURL.path)"
            ])
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        if flock(fd, LOCK_EX) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "Unable to acquire exclusive file lock"
            ])
        }
        return try body()
    }
}
