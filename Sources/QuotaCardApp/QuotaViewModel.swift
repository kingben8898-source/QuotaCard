import AppKit
import Combine
import Foundation
import QuotaCardCore

struct ProviderTabItem: Identifiable, Equatable {
    let id: String
    let shortName: String
    let displayName: String
    let snapshot: ProviderSnapshot?
}

@MainActor
final class QuotaViewModel: ObservableObject {
    @Published var liveState: QuotaState
    @Published var now: Date = Date()
    @Published var cliStatuses: [ManagedCLI: CLIStatus] = [:]
    @Published var codexSessionsDetected: Bool = false
    @Published var statusMessage: String?
    @Published var isRefreshing: Bool = false

    let preferences: Preferences
    let store: StateStore
    let configurator: CLIConfigurator
    let server: LocalIngestServer
    let agyPoller: AntigravityPoller

    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var watchedDirFD: Int32 = -1
    private var tickTimer: Timer?
    private var pollTimer: Timer?
    private var agyDispatchTimer: DispatchSourceTimer?
    private var tokenDispatchTimer: DispatchSourceTimer?
    private var activityToken: NSObjectProtocol?
    private var wakeObservers: [NSObjectProtocol] = []
    private var lastAgyPollAt: Date?
    private var lastCodexSyncAt: Date?
    private var lastCodexFingerprint: String?
    private var lastTickDate: Date = Date()

    init(
        preferences: Preferences,
        store: StateStore = StateStore(),
        port: UInt16 = 18421
    ) {
        self.preferences = preferences
        self.store = store
        self.configurator = CLIConfigurator(quotaCardDir: store.baseDirectory)
        self.server = LocalIngestServer(store: store, port: port)
        self.agyPoller = AntigravityPoller(store: store, configurator: configurator)
        self.liveState = store.load()

        // Prevent macOS App Nap from throttling periodic background quota polling
        self.activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
            reason: "Periodic Antigravity quota polling"
        )

        installBundledHelpersIfNeeded()
        refreshCLIStatuses()
        startTimers()
        startWakeObservers()
        startWatchingDirectory()
        startLocalServer()
        triggerCodexSync(trigger: .appLaunch)
        triggerAntigravityPoll(trigger: .appLaunch)
    }

    deinit {
        directoryWatcher?.cancel()
        agyDispatchTimer?.cancel()
        tokenDispatchTimer?.cancel()
        server.stop()
    }

    func shutdown() {
        directoryWatcher?.cancel()
        agyDispatchTimer?.cancel()
        tokenDispatchTimer?.cancel()
        tickTimer?.invalidate()
        pollTimer?.invalidate()
        for obs in wakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        wakeObservers.removeAll()
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        server.stop()
    }

    var isShowingDemo: Bool {
        preferences.forceDemoMode || liveState.providers.isEmpty
    }

    var effectiveState: QuotaState {
        if isShowingDemo {
            return DemoData.makeState(now: now)
        }
        return liveState
    }

    var providerTabs: [ProviderTabItem] {
        let baseOrder: [(id: String, short: String, display: String)] = [
            ("antigravity", "AGY", "Antigravity"),
            ("claude", "Claude", "Claude Code"),
            ("codex", "Codex", "OpenAI Codex")
        ]
        var items: [ProviderTabItem] = baseOrder.map { entry in
            let snap = effectiveState.providers[entry.id]
            return ProviderTabItem(
                id: entry.id,
                shortName: snap?.shortName ?? entry.short,
                displayName: snap?.displayName ?? entry.display,
                snapshot: snap
            )
        }
        let baseIds = Set(baseOrder.map(\.id))
        let extras = effectiveState.providers.values
            .filter { !baseIds.contains($0.id) }
            .sorted { $0.displayName < $1.displayName }
            .map { ProviderTabItem(id: $0.id, shortName: $0.shortName, displayName: $0.displayName, snapshot: $0) }
        items.append(contentsOf: extras)
        return items
    }

    var activeTab: ProviderTabItem {
        if let found = providerTabs.first(where: { $0.id == preferences.activeProviderId }) {
            return found
        }
        return providerTabs[0]
    }

    var activeProvider: ProviderSnapshot? {
        activeTab.snapshot
    }

    var menuBarTitle: String {
        guard preferences.showMenuBarText, let provider = activeProvider else {
            return "✦"
        }
        var parts: [String] = ["✦"]
        if let lowest = provider.lowestRemainingPercent {
            parts.append(QuotaFormatters.formatPercent(lowest))
        }
        if let total = provider.tokens?.total {
            parts.append(QuotaFormatters.formatTokens(total))
        }
        return parts.joined(separator: " ")
    }

    var ingestBinaryInstallPath: String {
        store.baseDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("quota-card-ingest")
            .path
    }

    func reloadFromDisk() {
        isRefreshing = true
        liveState = store.load()
        refreshCLIStatuses()
        now = Date()
        triggerCodexSync(trigger: .manual, showStatusFeedback: activeTab.id == "codex")
        triggerAntigravityPoll(trigger: .manual)
    }

    func syncCodexSessionsNow(userInitiated: Bool = false) {
        triggerCodexSync(trigger: userInitiated ? .manual : .appLaunch, showStatusFeedback: userInitiated)
    }

    func triggerCodexSync(trigger: RefreshTrigger, showStatusFeedback: Bool = false) {
        let current = Date()
        guard RefreshPolicy.shouldPoll(
            mode: preferences.refreshMode,
            trigger: trigger,
            lastPollAt: lastCodexSyncAt,
            now: current
        ) else {
            return
        }

        lastCodexSyncAt = current
        let storeRef = self.store
        DispatchQueue.global(qos: .utility).async {
            let fingerprint = CodexSessionScanner.sessionsFingerprint()
            let detected = (fingerprint != nil)
            let updated = CodexSessionScanner.syncToStore(storeRef)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.codexSessionsDetected = detected
                self.lastCodexFingerprint = fingerprint
                self.lastCodexSyncAt = Date()
                if let updated {
                    self.liveState = updated
                    self.now = Date()
                    if showStatusFeedback {
                        self.statusMessage = "已从 ~/.codex/sessions 同步最新 Codex 额度与今日 Token。"
                    }
                } else if showStatusFeedback {
                    self.liveState = storeRef.load()
                    self.statusMessage = detected
                        ? "Codex 额度已是最新（来自 ~/.codex/sessions）。"
                        : "未在 ~/.codex/sessions 检测到 Codex 会话日志。"
                }
            }
        }
    }

    func triggerAntigravityPoll(trigger: RefreshTrigger) {
        let current = Date()
        guard RefreshPolicy.shouldPoll(
            mode: preferences.refreshMode,
            trigger: trigger,
            lastPollAt: lastAgyPollAt,
            now: current
        ) else {
            if trigger == .manual {
                isRefreshing = false
            }
            return
        }

        let userInitiated = (trigger == .manual)
        lastAgyPollAt = current
        Task { [weak self] in
            guard let self else { return }
            if userInitiated {
                self.isRefreshing = true
            }
            let result = await self.agyPoller.pollNow()
            switch result {
            case .updated(let newState):
                self.liveState = newState
                self.now = Date()
                self.lastAgyPollAt = self.now
                if userInitiated {
                    self.statusMessage = "已通过 agy /usage 同步最新 Antigravity 额度。"
                }
            case .failed(let reason):
                if userInitiated {
                    self.statusMessage = reason
                }
            case .binaryNotFound, .skippedAlreadyRunning:
                break
            }
            self.isRefreshing = false
        }
    }

    func refreshCLIStatuses() {
        var map: [ManagedCLI: CLIStatus] = [:]
        for cli in ManagedCLI.allCases {
            map[cli] = configurator.detectStatus(for: cli)
        }
        cliStatuses = map
        codexSessionsDetected = CodexSessionScanner.hasSessionLogs()
    }

    func installHook(for cli: ManagedCLI) {
        installBundledHelpersIfNeeded()
        do {
            let updated = try configurator.installHook(for: cli, ingestBinaryPath: ingestBinaryInstallPath)
            cliStatuses[cli] = updated
            if let chained = updated.chainedOriginalCommand {
                statusMessage = "已配置 \(cli.displayName)，并链式保留原有状态栏命令：\(chained)"
            } else {
                statusMessage = "已成功配置 \(cli.displayName) 钩子，使用 CLI 后将自动同步额度。"
            }
        } catch {
            statusMessage = "配置 \(cli.displayName) 失败：\(error.localizedDescription)"
        }
    }

    func restoreHook(for cli: ManagedCLI) {
        do {
            let updated = try configurator.restoreHook(for: cli)
            cliStatuses[cli] = updated
            statusMessage = "已还原 \(cli.displayName) 原始配置。"
        } catch {
            statusMessage = "还原 \(cli.displayName) 失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Private Setup

    private func startTimers() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let prev = self.lastTickDate
                let current = Date()
                self.lastTickDate = current
                self.now = current

                // Auto-refresh 5 seconds after any Antigravity or Codex 5h/weekly countdown hits zero
                if let agy = self.liveState.providers["antigravity"],
                   RefreshPolicy.didAnyWindowJustReset(pools: agy.pools, previousCheck: prev, now: current) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                        self?.triggerAntigravityPoll(trigger: .countdownResetReached)
                    }
                }
                if let codex = self.liveState.providers["codex"],
                   RefreshPolicy.didAnyWindowJustReset(pools: codex.pools, previousCheck: prev, now: current) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                        self?.triggerCodexSync(trigger: .countdownResetReached)
                    }
                }
            }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let loaded = self.store.load()
                if loaded != self.liveState {
                    self.liveState = loaded
                }
            }
        }
        // Check fallback interval every 60s; RefreshPolicy enforces 15m (smart/15m), 10m, 5m, or manual-only
        let agyTimer = DispatchSource.makeTimerSource(queue: .main)
        agyTimer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
        agyTimer.setEventHandler { [weak self] in
            self?.triggerAntigravityPoll(trigger: .periodicFallback)
            self?.triggerCodexSync(trigger: .periodicFallback)
        }
        agyTimer.resume()
        agyDispatchTimer = agyTimer

        // In Smart mode, check lightweight local activity every 30s (zero network, zero subprocess);
        // new AGY token activity or Codex session file changes trigger a debounced (2-min cooldown) sync!
        let tokTimer = DispatchSource.makeTimerSource(queue: .main)
        tokTimer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(3))
        tokTimer.setEventHandler { [weak self] in
            guard let self else { return }
            let mode = self.preferences.refreshMode
            guard mode != .manualOnly else { return }

            let poller = self.agyPoller
            let prevCodexFP = self.lastCodexFingerprint
            let checkCodexActivity = (mode == .smart)

            DispatchQueue.global(qos: .utility).async {
                let agyUpdated = poller.refreshLocalTokensOnly()
                let codexFP = checkCodexActivity ? CodexSessionScanner.sessionsFingerprint() : prevCodexFP
                let codexChanged = checkCodexActivity && codexFP != nil && codexFP != prevCodexFP

                if agyUpdated != nil || codexChanged {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let agyUpdated {
                            self.liveState = agyUpdated
                            self.triggerAntigravityPoll(trigger: .newTokenActivity)
                        }
                        if codexChanged {
                            self.triggerCodexSync(trigger: .newTokenActivity)
                        }
                    }
                }
            }
        }
        tokTimer.resume()
        tokenDispatchTimer = tokTimer
    }

    private func startWakeObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let obs = wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.triggerCodexSync(trigger: .wakeFromSleep)
                    self?.triggerAntigravityPoll(trigger: .wakeFromSleep)
                }
            }
            wakeObservers.append(obs)
        }
    }

    private func startWatchingDirectory() {
        try? FileManager.default.createDirectory(at: store.baseDirectory, withIntermediateDirectories: true)
        let fd = open(store.baseDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedDirFD = fd

        // Run DispatchSource handler directly on .main because QuotaViewModel is @MainActor
        // (avoids Swift 6 _dispatch_assert_queue_fail trap on background queues).
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let loaded = self.store.load()
            if loaded != self.liveState {
                self.liveState = loaded
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        directoryWatcher = source
    }

    private func startLocalServer() {
        server.onUpdateApplied = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.liveState = self.store.load()
            }
        }
        server.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.statusMessage = message
            }
        }
        do {
            try server.start()
        } catch {
            statusMessage = "本机 HTTP 监听启动失败：\(error.localizedDescription)"
        }
    }

    private func installBundledHelpersIfNeeded() {
        let fm = FileManager.default
        let binDir = store.baseDirectory.appendingPathComponent("bin", isDirectory: true)
        let dest = binDir.appendingPathComponent("quota-card-ingest")
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        // Look for bundled helper inside .app/Contents/Helpers or sibling to executable
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates: [URL] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/quota-card-ingest"),
            exeDir?.appendingPathComponent("quota-card-ingest")
        ].compactMap { $0 }

        for candidate in candidates where fm.isExecutableFile(atPath: candidate.path) {
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: dest)
            }
            try? fm.copyItem(at: candidate, to: dest)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            break
        }
    }
}
