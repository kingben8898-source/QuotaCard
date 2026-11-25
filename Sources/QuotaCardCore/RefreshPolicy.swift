import Foundation

public enum RefreshMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case smart
    case every5Min
    case every10Min
    case every15Min
    case manualOnly

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .smart: return "智能省电（推荐）"
        case .every5Min: return "每 5 分钟"
        case .every10Min: return "每 10 分钟"
        case .every15Min: return "每 15 分钟"
        case .manualOnly: return "仅手动"
        }
    }

    public var summaryDescription: String {
        switch self {
        case .smart:
            return "有新对话自动刷新（2 分钟冷却）· 15 分钟兜底 · 倒计时归零与亮屏唤醒自动刷"
        case .every5Min:
            return "后台每 5 分钟定时刷新 · 倒计时归零与亮屏唤醒自动刷"
        case .every10Min:
            return "后台每 10 分钟定时刷新 · 倒计时归零与亮屏唤醒自动刷"
        case .every15Min:
            return "后台每 15 分钟定时刷新 · 倒计时归零与亮屏唤醒自动刷"
        case .manualOnly:
            return "仅在点击卡片 ↻ 或手动按钮时拉取额度（最省电）"
        }
    }

    public var badgeText: String {
        switch self {
        case .smart: return "智能省电模式（无需开终端）"
        case .every5Min: return "每 5 分钟自动刷新"
        case .every10Min: return "每 10 分钟自动刷新"
        case .every15Min: return "每 15 分钟自动刷新"
        case .manualOnly: return "仅手动刷新模式"
        }
    }

    public var fallbackInterval: TimeInterval? {
        switch self {
        case .smart: return 15 * 60
        case .every5Min: return 5 * 60
        case .every10Min: return 10 * 60
        case .every15Min: return 15 * 60
        case .manualOnly: return nil
        }
    }
}

public enum RefreshTrigger: Equatable, Sendable {
    case manual
    case appLaunch
    case wakeFromSleep
    case newTokenActivity
    case countdownResetReached
    case periodicFallback
}

public enum RefreshPolicy {
    public static let smartActivityCooldown: TimeInterval = 120
    public static let eventCooldown: TimeInterval = 30

    public static func shouldPoll(
        mode: RefreshMode,
        trigger: RefreshTrigger,
        lastPollAt: Date?,
        now: Date
    ) -> Bool {
        if trigger == .manual {
            return true
        }
        if mode == .manualOnly {
            return false
        }

        let elapsed = lastPollAt.map { now.timeIntervalSince($0) } ?? .infinity

        switch trigger {
        case .manual:
            return true
        case .appLaunch:
            return true
        case .wakeFromSleep, .countdownResetReached:
            return elapsed >= eventCooldown
        case .newTokenActivity:
            return mode == .smart && elapsed >= smartActivityCooldown
        case .periodicFallback:
            guard let interval = mode.fallbackInterval else { return false }
            return elapsed >= interval
        }
    }

    public static func didAnyWindowJustReset(
        pools: [QuotaPool],
        previousCheck: Date,
        now: Date
    ) -> Bool {
        guard now > previousCheck else { return false }
        for pool in pools {
            for resetAt in [pool.fiveHour?.resetAt, pool.weekly?.resetAt].compactMap({ $0 }) {
                if resetAt > previousCheck && resetAt <= now {
                    return true
                }
            }
        }
        return false
    }
}
