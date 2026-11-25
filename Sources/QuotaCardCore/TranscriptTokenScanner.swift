import Foundation

public struct TranscriptTokenReport: Equatable, Sendable {
    public var usage: TokenUsage?
    public var poolTokens: [String: Int]

    public init(usage: TokenUsage?, poolTokens: [String: Int]) {
        self.usage = usage
        self.poolTokens = poolTokens
    }
}

public enum TranscriptTokenScanner {
    public static func defaultBrainDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity", isDirectory: true)
            .appendingPathComponent("brain", isDirectory: true)
    }

    public static func scanAntigravityToday(
        brainDirectory: URL = defaultBrainDirectory(),
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> TranscriptTokenReport {
        let fm = FileManager.default
        guard let conversations = try? fm.contentsOfDirectory(
            at: brainDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return TranscriptTokenReport(usage: nil, poolTokens: [:])
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfToday = calendar.startOfDay(for: now)
        let todayKey = QuotaFormatters.dayKey(for: now, timeZone: timeZone)

        var totalInput = 0
        var totalOutput = 0
        var poolTokens: [String: Int] = [:]

        for convDir in conversations {
            let transcriptURL = convDir
                .appendingPathComponent(".system_generated", isDirectory: true)
                .appendingPathComponent("logs", isDirectory: true)
                .appendingPathComponent("transcript.jsonl")

            guard let values = try? transcriptURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else {
                continue
            }
            if let modDate = values.contentModificationDate, modDate < startOfToday {
                continue
            }

            guard let data = try? Data(contentsOf: transcriptURL),
                  let content = String(data: data, encoding: .utf8)
            else {
                continue
            }

            content.enumerateLines { line, _ in
                // Fast substring filter before JSON parsing
                guard line.contains("PLANNER_RESPONSE"),
                      line.contains("input_tokens"),
                      let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      (obj["type"] as? String) == "PLANNER_RESPONSE",
                      let createdStr = obj["created_at"] as? String,
                      let createdDate = QuotaFormatters.parseISO8601Date(createdStr),
                      QuotaFormatters.dayKey(for: createdDate, timeZone: timeZone) == todayKey
                else {
                    return
                }

                let input = (obj["input_tokens"] as? NSNumber)?.intValue ?? 0
                let cacheRead = (obj["cache_read_tokens"] as? NSNumber)?.intValue ?? 0
                let output = (obj["output_tokens"] as? NSNumber)?.intValue ?? 0
                let stepIn = max(0, input) + max(0, cacheRead)
                let stepOut = max(0, output)
                let stepTotal = stepIn + stepOut
                guard stepTotal > 0 else { return }

                totalInput += stepIn
                totalOutput += stepOut

                if let model = (obj["model"] as? String)?.lowercased() {
                    let poolKey = classifyPoolKey(forModel: model)
                    poolTokens[poolKey, default: 0] += stepTotal
                }
            }
        }

        let grandTotal = totalInput + totalOutput
        guard grandTotal > 0 else {
            return TranscriptTokenReport(usage: nil, poolTokens: [:])
        }

        let usage = TokenUsage(
            periodLabel: "今日 Token",
            dayKey: todayKey,
            total: grandTotal,
            input: totalInput,
            output: totalOutput
        )
        return TranscriptTokenReport(usage: usage, poolTokens: poolTokens)
    }

    private static func classifyPoolKey(forModel model: String) -> String {
        if model.contains("claude") || model.contains("opus") || model.contains("sonnet") || model.contains("gpt") {
            return "claude-gpt"
        }
        return "gemini"
    }
}
