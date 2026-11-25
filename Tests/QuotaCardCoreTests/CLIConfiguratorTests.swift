import Foundation
@testable import QuotaCardCore

enum CLIConfiguratorTests {
    static func makeTempSandbox() throws -> (root: URL, home: URL, quota: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quotacard-cli-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home", isDirectory: true)
        let quota = home.appendingPathComponent(".quota-card", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (root, home, quota)
    }

    static var all: [TestCase] {
        [
            TestCase(suite: "CLIConfiguratorTests", name: "installHookCreatesAntigravitySettingsWithOfficialSchema") {
                let (root, home, quota) = try makeTempSandbox()
                defer { try? FileManager.default.removeItem(at: root) }

                let config = CLIConfigurator(quotaCardDir: quota, homeDir: home, searchPaths: [])
                let status = try config.installHook(for: .antigravity, ingestBinaryPath: "/tmp/quota-card-ingest")
                try expectEqual(status.isHookConfigured, true)
                try expectNil(status.chainedOriginalCommand)

                let settingsData = try Data(contentsOf: status.settingsPath)
                let obj = try expectNotNil(try JSONSerialization.jsonObject(with: settingsData) as? [String: Any])
                let sl = try expectNotNil(obj["statusLine"] as? [String: Any])
                try expectEqual(sl["type"] as? String, "command")
                try expectEqual(sl["enabled"] as? Bool, true)
                try expectEqual(sl["padding"] as? Int, 0)
                let scriptPath = try expectNotNil(sl["command"] as? String)
                try expect(FileManager.default.isExecutableFile(atPath: scriptPath))
            },
            TestCase(suite: "CLIConfiguratorTests", name: "installHookPreservesUnrelatedSettingsAndChainsExistingStatusLine") {
                let (root, home, quota) = try makeTempSandbox()
                defer { try? FileManager.default.removeItem(at: root) }

                let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
                try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
                let settingsURL = claudeDir.appendingPathComponent("settings.json")
                let existing = """
                {"theme":"dark","statusLine":{"type":"command","command":"/usr/local/bin/my-status.sh"}}
                """
                try Data(existing.utf8).write(to: settingsURL)

                let config = CLIConfigurator(quotaCardDir: quota, homeDir: home, searchPaths: [])
                let status = try config.installHook(for: .claude, ingestBinaryPath: "/tmp/quota-card-ingest")
                try expectEqual(status.isHookConfigured, true)
                try expectEqual(status.chainedOriginalCommand, "/usr/local/bin/my-status.sh")
                try expectEqual(config.chainedCommand(for: .claude), "/usr/local/bin/my-status.sh")

                let backupURL = claudeDir.appendingPathComponent("settings.json.bak")
                try expect(FileManager.default.fileExists(atPath: backupURL.path))

                let updatedData = try Data(contentsOf: settingsURL)
                let updatedObj = try expectNotNil(try JSONSerialization.jsonObject(with: updatedData) as? [String: Any])
                try expectEqual(updatedObj["theme"] as? String, "dark")
            },
            TestCase(suite: "CLIConfiguratorTests", name: "installHookIsIdempotentAndNeverChainsSelf") {
                let (root, home, quota) = try makeTempSandbox()
                defer { try? FileManager.default.removeItem(at: root) }

                let config = CLIConfigurator(quotaCardDir: quota, homeDir: home, searchPaths: [])
                _ = try config.installHook(for: .antigravity, ingestBinaryPath: "/tmp/quota-card-ingest")
                let second = try config.installHook(for: .antigravity, ingestBinaryPath: "/tmp/quota-card-ingest")
                try expectEqual(second.isHookConfigured, true)
                try expectNil(second.chainedOriginalCommand)
                try expectNil(config.chainedCommand(for: .antigravity))
            },
            TestCase(suite: "CLIConfiguratorTests", name: "restoreHookRestoresOriginalCommandAndCleansChain") {
                let (root, home, quota) = try makeTempSandbox()
                defer { try? FileManager.default.removeItem(at: root) }

                let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
                try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
                let settingsURL = claudeDir.appendingPathComponent("settings.json")
                let existing = """
                {"theme":"dark","statusLine":{"type":"command","command":"/usr/local/bin/my-status.sh"}}
                """
                try Data(existing.utf8).write(to: settingsURL)

                let config = CLIConfigurator(quotaCardDir: quota, homeDir: home, searchPaths: [])
                _ = try config.installHook(for: .claude, ingestBinaryPath: "/tmp/quota-card-ingest")
                let restored = try config.restoreHook(for: .claude)

                try expectEqual(restored.isHookConfigured, false)
                try expectNil(config.chainedCommand(for: .claude))

                let data = try Data(contentsOf: settingsURL)
                let obj = try expectNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                try expectEqual(obj["theme"] as? String, "dark")
                let sl = try expectNotNil(obj["statusLine"] as? [String: Any])
                try expectEqual(sl["command"] as? String, "/usr/local/bin/my-status.sh")
            },
            TestCase(suite: "CLIConfiguratorTests", name: "restoreHookThrowsAndPreservesFileWhenSettingsJSONIsMalformed") {
                let (root, home, quota) = try makeTempSandbox()
                defer { try? FileManager.default.removeItem(at: root) }

                let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
                try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
                let settingsURL = claudeDir.appendingPathComponent("settings.json")
                let broken = "{ \"theme\": \"dark\", // comment breaks json\n"
                try Data(broken.utf8).write(to: settingsURL)

                let config = CLIConfigurator(quotaCardDir: quota, homeDir: home, searchPaths: [])
                var threw = false
                do {
                    _ = try config.restoreHook(for: .claude)
                } catch {
                    threw = true
                }
                try expectEqual(threw, true, "restoreHook should throw on malformed JSON instead of wiping settings.json")
                let preserved = try String(contentsOf: settingsURL, encoding: .utf8)
                try expectEqual(preserved, broken)
            }
        ]
    }
}
