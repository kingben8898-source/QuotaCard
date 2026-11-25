import Foundation

public enum ManagedCLI: String, CaseIterable, Sendable {
    case antigravity
    case claude

    public var binaryName: String {
        switch self {
        case .antigravity: return "agy"
        case .claude: return "claude"
        }
    }

    public var displayName: String {
        switch self {
        case .antigravity: return "Antigravity CLI (agy)"
        case .claude: return "Claude Code (claude)"
        }
    }

    public var bridgeScriptFilename: String {
        switch self {
        case .antigravity: return "agy-statusline.sh"
        case .claude: return "claude-statusline.sh"
        }
    }

    public func settingsURL(homeDir: URL) -> URL {
        switch self {
        case .antigravity:
            return homeDir
                .appendingPathComponent(".gemini", isDirectory: true)
                .appendingPathComponent("antigravity-cli", isDirectory: true)
                .appendingPathComponent("settings.json")
        case .claude:
            return homeDir
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("settings.json")
        }
    }
}

public struct CLIStatus: Equatable, Sendable {
    public var cli: ManagedCLI
    public var binaryPath: String?
    public var settingsPath: URL
    public var isHookConfigured: Bool
    public var chainedOriginalCommand: String?

    public init(
        cli: ManagedCLI,
        binaryPath: String?,
        settingsPath: URL,
        isHookConfigured: Bool,
        chainedOriginalCommand: String?
    ) {
        self.cli = cli
        self.binaryPath = binaryPath
        self.settingsPath = settingsPath
        self.isHookConfigured = isHookConfigured
        self.chainedOriginalCommand = chainedOriginalCommand
    }
}

public final class CLIConfigurator: @unchecked Sendable {
    public let quotaCardDir: URL
    public let homeDir: URL
    public let searchPaths: [String]
    public let chainFileURL: URL

    public init(
        quotaCardDir: URL = StateStore.defaultDirectory(),
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser,
        searchPaths: [String]? = nil
    ) {
        self.quotaCardDir = quotaCardDir
        self.homeDir = homeDir
        let defaultPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            homeDir.appendingPathComponent(".local/bin").path,
            homeDir.appendingPathComponent(".npm-global/bin").path
        ]
        self.searchPaths = searchPaths ?? defaultPaths
        self.chainFileURL = quotaCardDir.appendingPathComponent("chain.json")
    }

    public func bridgeScriptURL(for cli: ManagedCLI) -> URL {
        quotaCardDir
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent(cli.bridgeScriptFilename)
    }

    public func detectStatus(for cli: ManagedCLI) -> CLIStatus {
        let settingsURL = cli.settingsURL(homeDir: homeDir)
        let binaryPath = findBinary(named: cli.binaryName)
        let configured = isBridgeConfigured(for: cli, settingsURL: settingsURL)
        let chained = chainedCommand(for: cli)
        return CLIStatus(
            cli: cli,
            binaryPath: binaryPath,
            settingsPath: settingsURL,
            isHookConfigured: configured,
            chainedOriginalCommand: chained
        )
    }

    @discardableResult
    public func installHook(for cli: ManagedCLI, ingestBinaryPath: String) throws -> CLIStatus {
        let scriptsDir = quotaCardDir.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)

        let scriptURL = bridgeScriptURL(for: cli)
        let escapedIngest = shellQuote(ingestBinaryPath)
        let escapedQuotaDir = shellQuote(quotaCardDir.path)
        let scriptContent = """
        #!/bin/sh
        # Managed by QuotaCard — safe statusLine bridge for \(cli.rawValue)
        exec \(escapedIngest) --provider \(cli.rawValue) --quota-dir \(escapedQuotaDir) --print-statusline
        """
        try Data(scriptContent.utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let settingsURL = cli.settingsURL(homeDir: homeDir)
        let settingsDir = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)

        var settingsDict: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let existingData = try Data(contentsOf: settingsURL)
            if !existingData.isEmpty,
               let parsed = try JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
                settingsDict = parsed
            }
            let backupURL = settingsDir.appendingPathComponent("settings.json.bak")
            if !FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.copyItem(at: settingsURL, to: backupURL)
            }
        }

        // Preserve any pre-existing custom statusLine command (and guard against self-chaining!)
        if let existingSL = settingsDict["statusLine"] as? [String: Any],
           let existingCmd = existingSL["command"] as? String,
           !existingCmd.isEmpty,
           !isManagedBridgeCommand(existingCmd, scriptURL: scriptURL) {
            try saveChainedCommand(existingCmd, for: cli)
        }

        var statusLineObj: [String: Any] = [
            "type": "command",
            "command": scriptURL.path
        ]
        if cli == .antigravity {
            statusLineObj["enabled"] = true
            statusLineObj["padding"] = 0
        }
        settingsDict["statusLine"] = statusLineObj

        let outData = try JSONSerialization.data(withJSONObject: settingsDict, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: settingsURL, options: .atomic)

        return detectStatus(for: cli)
    }

    @discardableResult
    public func restoreHook(for cli: ManagedCLI) throws -> CLIStatus {
        let settingsURL = cli.settingsURL(homeDir: homeDir)
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            try removeChainedCommand(for: cli)
            return detectStatus(for: cli)
        }

        let existingData = try Data(contentsOf: settingsURL)
        var settingsDict: [String: Any]
        if existingData.isEmpty {
            settingsDict = [:]
        } else {
            guard let parsed = try JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
                throw NSError(domain: "QuotaCard.CLIConfigurator", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "现有 \(settingsURL.lastPathComponent) 不是有效的 JSON 对象，已中止还原以保护原配置。"
                ])
            }
            settingsDict = parsed
        }

        if let originalCmd = chainedCommand(for: cli) {
            var restoredSL: [String: Any] = [
                "type": "command",
                "command": originalCmd
            ]
            if cli == .antigravity {
                restoredSL["enabled"] = true
                restoredSL["padding"] = 0
            }
            settingsDict["statusLine"] = restoredSL
        } else {
            settingsDict.removeValue(forKey: "statusLine")
        }

        let outData = try JSONSerialization.data(withJSONObject: settingsDict, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: settingsURL, options: .atomic)
        try removeChainedCommand(for: cli)

        return detectStatus(for: cli)
    }

    public func chainedCommand(for cli: ManagedCLI) -> String? {
        loadChainMap()[cli.rawValue]
    }

    // MARK: - Helpers

    private func findBinary(named name: String) -> String? {
        for dir in searchPaths {
            let full = URL(fileURLWithPath: dir).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
        return nil
    }

    private func isBridgeConfigured(for cli: ManagedCLI, settingsURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sl = obj["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String
        else {
            return false
        }
        return isManagedBridgeCommand(cmd, scriptURL: bridgeScriptURL(for: cli))
    }

    private func isManagedBridgeCommand(_ command: String, scriptURL: URL) -> Bool {
        let normalized = (command as NSString).expandingTildeInPath
        return normalized == scriptURL.path || command.contains(scriptURL.lastPathComponent)
    }

    private func loadChainMap() -> [String: String] {
        guard let data = try? Data(contentsOf: chainFileURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return map
    }

    private func saveChainedCommand(_ command: String, for cli: ManagedCLI) throws {
        try FileManager.default.createDirectory(at: quotaCardDir, withIntermediateDirectories: true)
        var map = loadChainMap()
        map[cli.rawValue] = command
        let data = try QuotaJSONCoding.makeEncoder().encode(map)
        try data.write(to: chainFileURL, options: .atomic)
    }

    private func removeChainedCommand(for cli: ManagedCLI) throws {
        var map = loadChainMap()
        map.removeValue(forKey: cli.rawValue)
        if map.isEmpty {
            try? FileManager.default.removeItem(at: chainFileURL)
        } else {
            let data = try QuotaJSONCoding.makeEncoder().encode(map)
            try data.write(to: chainFileURL, options: .atomic)
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
