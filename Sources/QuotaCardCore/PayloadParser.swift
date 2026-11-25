import Foundation

public enum SupportedProvider: String, CaseIterable, Sendable {
    case antigravity
    case claude
    case codex
    case geminiWeb = "gemini-web"
    case chatgptWeb = "chatgpt-web"

    public var defaultDisplayName: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .claude: return "Claude Code"
        case .codex: return "OpenAI Codex"
        case .geminiWeb: return "Gemini Web"
        case .chatgptWeb: return "ChatGPT Web"
        }
    }

    public var defaultShortName: String {
        switch self {
        case .antigravity: return "AGY"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .geminiWeb: return "Gemini"
        case .chatgptWeb: return "GPT"
        }
    }
}

public enum PayloadParser {
    public static func parse(providerId rawId: String, data: Data, now: Date = Date()) -> ProviderUpdate? {
        guard !data.isEmpty,
              let rootObj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = rootObj as? [String: Any]
        else {
            return nil
        }

        let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let known = SupportedProvider(rawValue: id)
        let displayName = stringValue(dict, keys: ["displayName", "display_name"]) ?? known?.defaultDisplayName ?? rawId
        let shortName = stringValue(dict, keys: ["shortName", "short_name"]) ?? known?.defaultShortName ?? rawId
        let isUsageCommand = (dictValue(dict, keys: ["command"])?["name"] as? String) == "usage"
        let source = stringValue(dict, keys: ["source"]) ?? (isUsageCommand ? "agy /usage" : defaultSource(for: id))

        // 1. Direct v1 pools/tokens schema (used by HTTP POST /v1/providers/{id} or normalized payloads)
        let directPools = parsePoolArray(dict["pools"])
        let directTokens = parseDirectTokens(dict["tokens"], now: now)

        // 2. Provider-specific defensive parsing
        let parsedPools: [QuotaPool]?
        if let directPools {
            parsedPools = directPools
        } else {
            switch id {
            case "claude":
                parsedPools = parseClaudePools(dict)
            case "codex":
                parsedPools = parseCodexPools(dict)
            case "antigravity":
                parsedPools = parseAntigravityPools(dict)
            default:
                parsedPools = parseAntigravityPools(dict) ?? parseClaudePools(dict) ?? parseCodexPools(dict)
            }
        }

        let sessionSample = parseSessionTokenSample(dict)
        if parsedPools == nil && directTokens == nil && sessionSample == nil {
            return nil
        }

        return ProviderUpdate(
            id: id,
            displayName: displayName,
            shortName: shortName,
            source: source,
            pools: parsedPools,
            tokens: directTokens,
            sessionTokenSample: sessionSample,
            timestamp: now
        )
    }

    public static func redactSchemaSummary(from data: Data) -> String? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data, options: [])
        else {
            return nil
        }
        let redacted = redactValue(obj)
        guard let encoded = try? JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys]),
              let text = String(data: encoded, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

    public static func formatFallbackStatusLine(from update: ProviderUpdate, now: Date = Date()) -> String {
        var parts: [String] = [update.shortName]
        if let pools = update.pools, let first = pools.first {
            if let five = first.fiveHour {
                let cd = QuotaFormatters.formatCountdown(to: five.resetAt, now: now)
                parts.append("5h:\(QuotaFormatters.formatPercent(five.remainingPercent)) (\(cd))")
            } else if let wk = first.weekly {
                let cd = QuotaFormatters.formatCountdown(to: wk.resetAt, now: now)
                parts.append("周:\(QuotaFormatters.formatPercent(wk.remainingPercent)) (\(cd))")
            }
        }
        if let sample = update.sessionTokenSample {
            parts.append("tok:\(QuotaFormatters.formatTokens(sample.resolvedTotal))")
        } else if let tokens = update.tokens {
            parts.append("tok:\(QuotaFormatters.formatTokens(tokens.total))")
        }
        return parts.joined(separator: " | ")
    }

    // MARK: - Provider Parsers

    private static func defaultSource(for id: String) -> String {
        switch id {
        case "antigravity": return "agy-statusline"
        case "claude": return "claude-statusline"
        case "codex": return "codex-cli"
        default: return "local-http"
        }
    }

    private static func parseClaudePools(_ dict: [String: Any]) -> [QuotaPool]? {
        guard let rateLimits = dictValue(dict, keys: ["rate_limits", "rateLimits"]) else { return nil }
        let fiveHour = parseWindow(dictValue(rateLimits, keys: ["five_hour", "fiveHour"]))
        let weekly = parseWindow(dictValue(rateLimits, keys: ["seven_day", "sevenDay", "weekly"]))
        guard fiveHour != nil || weekly != nil else { return nil }
        return [
            QuotaPool(
                id: "claude-code",
                name: "Claude Code",
                tokensUsed: nil,
                fiveHour: fiveHour,
                weekly: weekly
            )
        ]
    }

    private static func parseCodexPools(_ dict: [String: Any]) -> [QuotaPool]? {
        let container = dictValue(dict, keys: ["rateLimits", "rate_limits"]) ?? dict
        let fiveHour = parseWindow(dictValue(container, keys: ["primary", "five_hour", "fiveHour"]))
        let weekly = parseWindow(dictValue(container, keys: ["secondary", "seven_day", "sevenDay", "weekly"]))
        guard fiveHour != nil || weekly != nil else { return nil }
        return [
            QuotaPool(
                id: "openai-codex",
                name: "OpenAI Codex",
                tokensUsed: nil,
                fiveHour: fiveHour,
                weekly: weekly
            )
        ]
    }

    private static func parseAntigravityPools(_ dict: [String: Any]) -> [QuotaPool]? {
        let commandData = dictValue(dict, keys: ["command"]).flatMap { dictValue($0, keys: ["data"]) }
        let quotaObj = dictValue(dict, keys: ["quota", "quotaSummary", "quota_summary"])

        let candidateArrays: [Any?] = [
            commandData?["groups"],
            commandData?["buckets"],
            dict["groups"],
            dict["buckets"],
            dict["quotas"],
            quotaObj?["groups"],
            quotaObj?["buckets"],
            quotaObj?["pools"]
        ]
        for raw in candidateArrays {
            if let pools = parsePoolArray(raw), !pools.isEmpty {
                return pools
            }
        }

        // Single-pool fallback if top-level remaining_fraction / rate_limits present
        if let topFive = parseWindow(dictValue(dict, keys: ["rate_limits", "rateLimits"])?["five_hour"] as? [String: Any])
            ?? parseWindow(dict) {
            let topWeekly = parseWindow(dictValue(dict, keys: ["rate_limits", "rateLimits"])?["seven_day"] as? [String: Any])
                ?? parseWeeklyFlat(dict)
            return [
                QuotaPool(
                    id: "antigravity-main",
                    name: stringValue(dict, keys: ["pool_name", "poolName"]) ?? "Antigravity",
                    tokensUsed: intValue(dict, keys: ["tokens_used", "tokensUsed"]),
                    fiveHour: topFive,
                    weekly: topWeekly
                )
            ]
        }

        return nil
    }

    private static func parsePoolArray(_ raw: Any?) -> [QuotaPool]? {
        guard let list = raw as? [[String: Any]] else { return nil }
        var result: [QuotaPool] = []
        for (idx, item) in list.enumerated() {
            let rawName = stringValue(item, keys: ["name", "displayName", "display_name", "label", "groupName", "group_name"]) ?? "Pool \(idx + 1)"
            let name = normalizePoolDisplayName(rawName)
            let subtitle = summarizePoolSubtitle(name: name, description: stringValue(item, keys: ["description"]))
            let id = stringValue(item, keys: ["id", "poolId", "pool_id"]) ?? slugify(name)
            let tokensUsed = intValue(item, keys: ["tokensUsed", "tokens_used"])

            // Handle official `agy -p "/usage"` nested `buckets: [{ window: "5h" | "weekly", remaining_fraction, reset_time }]`
            if let buckets = item["buckets"] as? [[String: Any]], !buckets.isEmpty {
                var fiveHourBucket: QuotaWindow?
                var weeklyBucket: QuotaWindow?
                for bucket in buckets {
                    guard let win = parseWindow(bucket) else { continue }
                    let winTag = (stringValue(bucket, keys: ["window", "windowLabel", "window_label", "id", "name"]) ?? "").lowercased()
                    if winTag.contains("week") || winTag.contains("7d") {
                        weeklyBucket = win
                    } else if winTag.contains("5h") || winTag.contains("five") || winTag.contains("hour") {
                        fiveHourBucket = win
                    } else if fiveHourBucket == nil {
                        fiveHourBucket = win
                    } else if weeklyBucket == nil {
                        weeklyBucket = win
                    }
                }
                if fiveHourBucket != nil || weeklyBucket != nil {
                    result.append(QuotaPool(
                        id: id,
                        name: name,
                        subtitle: subtitle,
                        tokensUsed: tokensUsed,
                        fiveHour: fiveHourBucket,
                        weekly: weeklyBucket
                    ))
                    continue
                }
            }

            let explicitFive = parseWindow(dictValue(item, keys: ["fiveHour", "five_hour", "rolling", "primary"]))
            let explicitWeekly = parseWindow(dictValue(item, keys: ["weekly", "seven_day", "sevenDay", "secondary"]))
                ?? parseWeeklyFlat(item)
            let flatPrimary = parseWindow(item)

            // If no explicit fiveHour/weekly sub-objects, check if flat item is weekly-only via windowLabel
            let windowLabel = stringValue(item, keys: ["windowLabel", "window_label", "window"])?.lowercased()
            let fiveHour: QuotaWindow?
            let weekly: QuotaWindow?
            if explicitFive != nil || explicitWeekly != nil {
                fiveHour = explicitFive ?? (windowLabel == "7d" || windowLabel == "weekly" ? nil : flatPrimary)
                weekly = explicitWeekly
            } else if windowLabel == "7d" || windowLabel == "weekly" {
                fiveHour = nil
                weekly = flatPrimary
            } else {
                fiveHour = flatPrimary
                weekly = nil
            }

            if fiveHour != nil || weekly != nil {
                result.append(QuotaPool(
                    id: id,
                    name: name,
                    tokensUsed: tokensUsed,
                    fiveHour: fiveHour,
                    weekly: weekly
                ))
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func normalizePoolDisplayName(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "gemini models":
            return "Gemini"
        case "claude and gpt models":
            return "Claude / GPT"
        default:
            return raw
        }
    }

    private static func summarizePoolSubtitle(name: String, description: String?) -> String? {
        guard let desc = description?.lowercased() else { return nil }
        if name == "Gemini" {
            var tags: [String] = []
            if desc.contains("neon") { tags.append("Neon") }
            if desc.contains("carbon") { tags.append("Carbon") }
            if desc.contains("argon") { tags.append("Argon") }
            if desc.contains("flash") { tags.append("Flash") }
            return tags.isEmpty ? nil : "含 " + tags.joined(separator: " / ")
        }
        if name == "Claude / GPT" {
            var tags: [String] = []
            if desc.contains("opus") { tags.append("Opus") }
            if desc.contains("sonnet") { tags.append("Sonnet") }
            if desc.contains("gpt") { tags.append("GPT") }
            return tags.isEmpty ? nil : "含 " + tags.joined(separator: " / ")
        }
        return nil
    }

    private static func parseWindow(_ dict: [String: Any]?) -> QuotaWindow? {
        guard let dict else { return nil }
        let remaining: Double?
        if let pct = doubleValue(dict, keys: ["remainingPercent", "remaining_percent"]) {
            remaining = pct
        } else if let frac = doubleValue(dict, keys: ["remainingFraction", "remaining_fraction"]) {
            remaining = frac <= 1.0 ? frac * 100.0 : frac
        } else if let used = doubleValue(dict, keys: ["used_percentage", "usedPercent", "used_percent"]) {
            remaining = 100.0 - used
        } else if let usedFrac = doubleValue(dict, keys: ["used_fraction", "usedFraction"]) {
            remaining = 100.0 - (usedFrac <= 1.0 ? usedFrac * 100.0 : usedFrac)
        } else {
            remaining = nil
        }

        guard let remaining else { return nil }
        let resetAt = dateValue(dict, keys: ["resetAt", "reset_at", "resetsAt", "resets_at", "resetTime", "reset_time"])
        return QuotaWindow(remainingPercent: remaining, resetAt: resetAt)
    }

    private static func parseWeeklyFlat(_ dict: [String: Any]) -> QuotaWindow? {
        let remaining: Double?
        if let pct = doubleValue(dict, keys: ["weeklyRemainingPercent", "weekly_remaining_percent"]) {
            remaining = pct
        } else if let frac = doubleValue(dict, keys: ["weeklyRemainingFraction", "weekly_remaining_fraction"]) {
            remaining = frac <= 1.0 ? frac * 100.0 : frac
        } else if let used = doubleValue(dict, keys: ["weekly_used_percentage", "weeklyUsedPercent"]) {
            remaining = 100.0 - used
        } else {
            remaining = nil
        }
        guard let remaining else { return nil }
        let resetAt = dateValue(dict, keys: ["weeklyResetAt", "weekly_reset_at", "weeklyResetTime", "weekly_reset_time"])
        return QuotaWindow(remainingPercent: remaining, resetAt: resetAt)
    }

    private static func parseDirectTokens(_ raw: Any?, now: Date) -> TokenUsage? {
        guard let dict = raw as? [String: Any] else { return nil }
        let input = intValue(dict, keys: ["input", "inputTokens", "input_tokens"])
        let output = intValue(dict, keys: ["output", "outputTokens", "output_tokens"])
        let total = intValue(dict, keys: ["total", "totalTokens", "total_tokens"]) ?? ((input ?? 0) + (output ?? 0))
        guard total > 0 || input != nil || output != nil else { return nil }
        return TokenUsage(
            periodLabel: stringValue(dict, keys: ["periodLabel", "period_label"]) ?? "今日 Token",
            dayKey: stringValue(dict, keys: ["dayKey", "day_key"]) ?? QuotaFormatters.dayKey(for: now),
            total: total,
            input: input,
            output: output
        )
    }

    private static func parseSessionTokenSample(_ dict: [String: Any]) -> SessionTokenSample? {
        let sessionId = stringValue(dict, keys: ["session_id", "sessionId", "conversation_id", "conversationId"]) ?? "default"
        let tokenSource = dictValue(dict, keys: ["context_window", "contextWindow", "usage", "token_usage", "tokenUsage"]) ?? dict

        let input = intValue(tokenSource, keys: ["total_input_tokens", "totalInputTokens", "input_tokens", "inputTokens"])
        let output = intValue(tokenSource, keys: ["total_output_tokens", "totalOutputTokens", "output_tokens", "outputTokens"])
        let total = intValue(tokenSource, keys: ["total_tokens", "totalTokens"])

        guard (input ?? 0) > 0 || (output ?? 0) > 0 || (total ?? 0) > 0 else { return nil }
        return SessionTokenSample(
            sessionId: sessionId,
            inputTokens: input ?? 0,
            outputTokens: output ?? 0,
            totalTokens: total
        )
    }

    // MARK: - Helpers

    private static func dictValue(_ dict: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let found = dict[key] as? [String: Any] { return found }
        }
        return nil
    }

    private static func stringValue(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func isJSONBoolean(_ value: Any) -> Bool {
        guard let num = value as? NSNumber else { return false }
        return CFGetTypeID(num) == CFBooleanGetTypeID()
    }

    private static func doubleValue(_ dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let raw = dict[key] else { continue }
            if let num = raw as? NSNumber, !isJSONBoolean(raw) { return num.doubleValue }
            if let str = raw as? String, let parsed = Double(str) { return parsed }
        }
        return nil
    }

    private static func intValue(_ dict: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            guard let raw = dict[key] else { continue }
            if let num = raw as? NSNumber, !isJSONBoolean(raw) { return num.intValue }
            if let str = raw as? String, let parsed = Int(str) { return parsed }
        }
        return nil
    }

    private static func dateValue(_ dict: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let str = dict[key] as? String, let parsed = QuotaFormatters.parseISO8601Date(str) {
                return parsed
            }
            if let raw = dict[key], let num = raw as? NSNumber, !isJSONBoolean(raw) {
                let val = num.doubleValue
                if val > 0 {
                    return val > 1_000_000_000_000
                        ? Date(timeIntervalSince1970: val / 1000.0)
                        : Date(timeIntervalSince1970: val)
                }
            }
        }
        return nil
    }

    private static func slugify(_ name: String) -> String {
        let lower = name.lowercased()
        let allowed = lower.map { ($0.isLetter || $0.isNumber) ? $0 : "-" }
        return String(allowed).replacingOccurrences(of: "--", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func redactValue(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var mapped: [String: Any] = [:]
            for (k, v) in dict {
                mapped[k] = redactValue(v)
            }
            return mapped
        }
        if let arr = value as? [Any] {
            return arr.first.map { [redactValue($0)] } ?? []
        }
        if value is Bool { return "<bool>" }
        if value is NSNumber { return "<number>" }
        if value is String { return "<string>" }
        return "<null>"
    }
}
