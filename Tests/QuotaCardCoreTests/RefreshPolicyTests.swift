import Foundation
@testable import QuotaCardCore

enum RefreshPolicyTests {
    static var all: [TestCase] {
        [
            TestCase(suite: "RefreshPolicyTests", name: "smartModeHonorsActivityCooldownAnd15MinFallback") {
                let t0 = Date(timeIntervalSince1970: 1_764_000_000)

                // Initial launch with nil lastPollAt always polls
                try expectEqual(RefreshPolicy.shouldPoll(mode: .smart, trigger: .appLaunch, lastPollAt: nil, now: t0), true)

                // New token activity within 2-min cooldown is suppressed
                try expectEqual(RefreshPolicy.shouldPoll(mode: .smart, trigger: .newTokenActivity, lastPollAt: t0, now: t0.addingTimeInterval(60)), false)
                // New token activity after 2-min cooldown triggers poll
                try expectEqual(RefreshPolicy.shouldPoll(mode: .smart, trigger: .newTokenActivity, lastPollAt: t0, now: t0.addingTimeInterval(125)), true)

                // Periodic fallback suppressed before 15 minutes, fires at 15 minutes
                try expectEqual(RefreshPolicy.shouldPoll(mode: .smart, trigger: .periodicFallback, lastPollAt: t0, now: t0.addingTimeInterval(10 * 60)), false)
                try expectEqual(RefreshPolicy.shouldPoll(mode: .smart, trigger: .periodicFallback, lastPollAt: t0, now: t0.addingTimeInterval(15 * 60)), true)
            },
            TestCase(suite: "RefreshPolicyTests", name: "manualModeBlocksAllAutoTriggersButAllowsManual") {
                let t0 = Date(timeIntervalSince1970: 1_764_000_000)
                let tLater = t0.addingTimeInterval(3600)
                try expectEqual(RefreshPolicy.shouldPoll(mode: .manualOnly, trigger: .periodicFallback, lastPollAt: t0, now: tLater), false)
                try expectEqual(RefreshPolicy.shouldPoll(mode: .manualOnly, trigger: .newTokenActivity, lastPollAt: t0, now: tLater), false)
                try expectEqual(RefreshPolicy.shouldPoll(mode: .manualOnly, trigger: .wakeFromSleep, lastPollAt: t0, now: tLater), false)
                try expectEqual(RefreshPolicy.shouldPoll(mode: .manualOnly, trigger: .countdownResetReached, lastPollAt: t0, now: tLater), false)
                try expectEqual(RefreshPolicy.shouldPoll(mode: .manualOnly, trigger: .manual, lastPollAt: t0, now: t0), true)
            },
            TestCase(suite: "RefreshPolicyTests", name: "wakeAndCountdownResetDebounceWithin30Seconds") {
                let t0 = Date(timeIntervalSince1970: 1_764_000_000)
                try expectEqual(RefreshPolicy.shouldPoll(mode: .smart, trigger: .wakeFromSleep, lastPollAt: t0, now: t0.addingTimeInterval(10)), false)
                try expectEqual(RefreshPolicy.shouldPoll(mode: .smart, trigger: .wakeFromSleep, lastPollAt: t0, now: t0.addingTimeInterval(35)), true)
                try expectEqual(RefreshPolicy.shouldPoll(mode: .smart, trigger: .countdownResetReached, lastPollAt: t0, now: t0.addingTimeInterval(35)), true)
            },
            TestCase(suite: "RefreshPolicyTests", name: "didAnyWindowJustResetDetectsCrossingZeroOnce") {
                let resetAt = Date(timeIntervalSince1970: 1_764_000_100)
                let pools = [
                    QuotaPool(
                        id: "gemini",
                        name: "Gemini",
                        fiveHour: QuotaWindow(remainingPercent: 50, resetAt: resetAt),
                        weekly: QuotaWindow(remainingPercent: 80, resetAt: resetAt.addingTimeInterval(86_400))
                    )
                ]
                // Before reset: false
                try expectEqual(
                    RefreshPolicy.didAnyWindowJustReset(
                        pools: pools,
                        previousCheck: resetAt.addingTimeInterval(-2),
                        now: resetAt.addingTimeInterval(-1)
                    ),
                    false
                )
                // Crossing reset boundary: true
                try expectEqual(
                    RefreshPolicy.didAnyWindowJustReset(
                        pools: pools,
                        previousCheck: resetAt.addingTimeInterval(-1),
                        now: resetAt.addingTimeInterval(0.5)
                    ),
                    true
                )
                // After reset already passed: false (does not repeat every second!)
                try expectEqual(
                    RefreshPolicy.didAnyWindowJustReset(
                        pools: pools,
                        previousCheck: resetAt.addingTimeInterval(0.5),
                        now: resetAt.addingTimeInterval(1.5)
                    ),
                    false
                )
            }
        ]
    }
}
