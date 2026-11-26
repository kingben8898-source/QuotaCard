import Foundation

public struct CodexSessionReport: Equatable, Sendable {
    public var pools: [QuotaPool]
    public var usage: TokenUsage?
    public var rateLimitsUpdatedAt: Date?

    public init(pools: [QuotaPool], usage: TokenUsage?, rateLimitsUpdatedAt: Date?) {
        self.pools = pools
        self.usage = usage
        self.rateLimitsUpdatedAt = rateLimitsUpdatedAt
    }
}

public enum CodexSessionScanner {
    public static func defaultSessionsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    public static func hasSessionLogs(sessionsDirectory: URL = defaultSessionsDirectory()) -> Bool {
        !collectRecentSessionFiles(in: sessionsDirectory, limit: 1).isEmpty
    }

    /// Lightweight metadata-only fingerprint of recent Codex session files (stat only, zero file reads).
    /// Used in Smart Power-Saving mode to detect new Codex conversation activity without parsing JSONL files while idle.
    public static func sessionsFingerprint(sessionsDirectory: URL = defaultSessionsDirectory()) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var items: [(path: String, mtime: TimeInterval, size: Int)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true
            else {
                continue
            }
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = values.fileSize ?? 0
            items.append((path: fileURL.lastPathComponent, mtime: mtime, size: size))
        }
        guard !items.isEmpty else { return nil }

        items.sort { $0.mtime > $1.mtime }
        return items.prefix(10)
            .map { "\($0.path):\(Int($0.mtime.rounded())):\($0.size)" }
            .joined(separator: "|")
    }

    public static func scan(
        sessionsDirectory: URL = defaultSessionsDirectory(),
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> CodexSessionReport {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfToday = calendar.startOfDay(for: now)
        let todayKey = QuotaFormatters.dayKey(for: now, timeZone: timeZone)

        let recentFiles = collectRecentSessionFiles(in: sessionsDirectory, limit: 25)
        guard !recentFiles.isEmpty else {
            return CodexSessionReport(pools: [], usage: nil, rateLimitsUpdatedAt: nil)
        }

        // Latest rate_limits event per limit_id
        var latestByLimitId: [String: (timestamp: Date, pool: QuotaPool)] = [:]
        var totalInput = 0
        var totalOutput = 0

        for entry in recentFiles {
            let needTokens = entry.modDate >= startOfToday
            let needRateLimits = latestByLimitId.isEmpty || entry.index < 15
            guard needTokens || needRateLimits else { continue }

            guard let data = try? Data(contentsOf: entry.url),
                  let content = String(data: data, encoding: .utf8)
            else {
                continue
            }

            var prevTotalTokens: Int?
            var prevInputTokens = 0
            var prevOutputTokens = 0

            content.enumerateLines { line, _ in
                guard line.contains("\"token_count\""),
                      let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      (obj["type"] as? String) == "event_msg",
                      let payload = obj["payload"] as? [String: Any],
                      (payload["type"] as? String) == "token_count"
                else {
                    return
                }

                let eventDate = (obj["timestamp"] as? String)
                    .flatMap(QuotaFormatters.parseISO8601Date) ?? entry.modDate

                // 1. Aggregate today's token usage
                if needTokens, let info = payload["info"] as? [String: Any] {
                    let totalUsage = info["total_token_usage"] as? [String: Any]
                    let lastUsage = info["last_token_usage"] as? [String: Any]

                    let curTotal = intValue(totalUsage?["total_tokens"])
                    let curInput = intValue(totalUsage?["input_tokens"])
                    let curOutput = intValue(totalUsage?["output_tokens"])

                    let isDuplicate = (curTotal != nil && curTotal == prevTotalTokens)
                    defer {
                        if let curTotal { prevTotalTokens = curTotal }
                        if let curInput { prevInputTokens = curInput }
                        if let curOutput { prevOutputTokens = curOutput }
                    }

                    if !isDuplicate,
                       QuotaFormatters.dayKey(for: eventDate, timeZone: timeZone) == todayKey {
                        if let lastUsage {
                            let stepIn = max(0, intValue(lastUsage["input_tokens"]) ?? 0)
                            let stepOut = max(0, intValue(lastUsage["output_tokens"]) ?? 0)
                            if stepIn + stepOut > 0 {
                                totalInput += stepIn
                                totalOutput += stepOut
                            }
                        } else if let curInput, let curOutput {
                            let deltaIn = max(0, curInput - prevInputTokens)
                            let deltaOut = max(0, curOutput - prevOutputTokens)
                            if deltaIn + deltaOut > 0 {
                                totalInput += deltaIn
                                totalOutput += deltaOut
                            }
                        }
                    }
                }

                // 2. Capture latest rate_limits per limit_id
                if let rl = payload["rate_limits"] as? [String: Any],
                   let parsed = parseRateLimitsPool(rl) {
                    let existing = latestByLimitId[parsed.id]
                    if existing == nil || eventDate >= existing!.timestamp {
                        latestByLimitId[parsed.id] = (timestamp: eventDate, pool: parsed)
                    }
                }
            }
        }

        let grandTotal = totalInput + totalOutput
        let usage: TokenUsage? = grandTotal > 0 ? TokenUsage(
            periodLabel: "今日 Token",
            dayKey: todayKey,
            total: grandTotal,
            input: totalInput,
            output: totalOutput
        ) : nil

        // Sort pools with primary "codex" first, then alphabetically by name
        var pools = latestByLimitId.values
            .sorted { lhs, rhs in
                if lhs.pool.id == "codex" && rhs.pool.id != "codex" { return true }
                if rhs.pool.id == "codex" && lhs.pool.id != "codex" { return false }
                return lhs.pool.name < rhs.pool.name
            }
            .map(\.pool)

        if grandTotal > 0, !pools.isEmpty {
            if let primaryIdx = pools.firstIndex(where: { $0.id == "codex" }) {
                pools[primaryIdx].tokensUsed = grandTotal
            } else {
                pools[0].tokensUsed = grandTotal
            }
        }

        let latestRateLimitsDate = latestByLimitId.values.map(\.timestamp).max()
        return CodexSessionReport(
            pools: pools,
            usage: usage,
            rateLimitsUpdatedAt: latestRateLimitsDate
        )
    }

    @discardableResult
    public static func syncToStore(
        _ store: StateStore,
        sessionsDirectory: URL = defaultSessionsDirectory(),
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> QuotaState? {
        let report = scan(sessionsDirectory: sessionsDirectory, now: now, timeZone: timeZone)
        guard !report.pools.isEmpty || report.usage != nil else { return nil }

        let current = store.load()
        if let existing = current.providers["codex"] {
            let samePools = existing.pools == report.pools
            let sameTokens = existing.tokens == report.usage
            let samePoolTime: Bool
            if let a = existing.poolsUpdatedAt, let b = report.rateLimitsUpdatedAt {
                samePoolTime = abs(a.timeIntervalSince(b)) < 1.0
            } else {
                samePoolTime = (existing.poolsUpdatedAt == nil && report.rateLimitsUpdatedAt == nil)
            }
            if samePools && sameTokens && samePoolTime {
                return nil
            }
        }

        let update = ProviderUpdate(
            id: "codex",
            displayName: "OpenAI Codex",
            shortName: "Codex",
            source: "codex sessions",
            pools: report.pools.isEmpty ? nil : report.pools,
            tokens: report.usage,
            sessionTokenSample: nil,
            timestamp: now,
            poolsTimestamp: report.rateLimitsUpdatedAt ?? now
        )
        return try? store.applyUpdate(update, timeZone: timeZone)
    }

    // MARK: - Private Helpers

    private struct SessionFileEntry {
        let url: URL
        let modDate: Date
        var index: Int
    }

    private static func collectRecentSessionFiles(in directory: URL, limit: Int) -> [SessionFileEntry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var entries: [SessionFileEntry] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true
            else {
                continue
            }
            entries.append(SessionFileEntry(
                url: fileURL,
                modDate: values.contentModificationDate ?? .distantPast,
                index: 0
            ))
        }

        entries.sort { $0.modDate > $1.modDate }
        let capped = Array(entries.prefix(limit))
        return capped.enumerated().map { idx, item in
            SessionFileEntry(url: item.url, modDate: item.modDate, index: idx)
        }
    }

    private static func parseRateLimitsPool(_ rl: [String: Any]) -> QuotaPool? {
        let primaryDict = rl["primary"] as? [String: Any]
        let secondaryDict = rl["secondary"] as? [String: Any]

        var fiveHour: QuotaWindow?
        var weekly: QuotaWindow?

        for (isPrimary, dict) in [(true, primaryDict), (false, secondaryDict)] {
            guard let dict, let win = parseRateLimitWindow(dict) else { continue }
            if let mins = intValue(dict["window_minutes"]) {
                if mins > 1440 {
                    weekly = win
                } else {
                    fiveHour = win
                }
            } else if isPrimary {
                fiveHour = win
            } else {
                weekly = win
            }
        }

        guard fiveHour != nil || weekly != nil else { return nil }

        let rawId = (rl["limit_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = (rawId?.isEmpty == false ? rawId! : "codex")
        let rawLimitName = (rl["limit_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let displayName: String
        let subtitle: String?
        if let rawLimitName, !rawLimitName.isEmpty {
            displayName = rawLimitName
            subtitle = nil
        } else if id.lowercased() == "codex" {
            displayName = "Codex"
            subtitle = "GPT-5 / Codex"
        } else {
            displayName = id
            subtitle = nil
        }

        return QuotaPool(
            id: id,
            name: displayName,
            subtitle: subtitle,
            tokensUsed: nil,
            fiveHour: fiveHour,
            weekly: weekly
        )
    }

    private static func parseRateLimitWindow(_ dict: [String: Any]) -> QuotaWindow? {
        guard let used = doubleValue(dict["used_percent"]) else { return nil }
        let remaining = QuotaFormatters.clampPercent(100.0 - used)
        var resetAt: Date?
        if let epoch = doubleValue(dict["resets_at"]) {
            resetAt = Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000.0 : epoch)
        }
        return QuotaWindow(remainingPercent: remaining, resetAt: resetAt)
    }

    private static func intValue(_ raw: Any?) -> Int? {
        guard let num = raw as? NSNumber else { return nil }
        if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
        return num.intValue
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        guard let num = raw as? NSNumber else { return nil }
        if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
        let v = num.doubleValue
        return v.isFinite ? v : nil
    }
}
