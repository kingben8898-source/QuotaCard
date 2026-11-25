import AppKit
import QuotaCardCore
import SwiftUI

struct SettingsSheetView: View {
    @ObservedObject var viewModel: QuotaViewModel
    @ObservedObject var preferences: Preferences
    @State private var showFullToken: Bool = false
    @State private var copiedHint: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("QuotaCard 接入与设置")
                    .font(.title2.bold())

                if let msg = viewModel.statusMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.accentColor)
                        Text(msg)
                            .font(.caption)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
                }

                // Section 1: Antigravity & Claude CLI
                GroupBox("1. 官方 CLI 接入（推荐）") {
                    VStack(alignment: .leading, spacing: 12) {
                        cliSection(.antigravity, installCommand: "curl -fsSL https://antigravity.google/cli/install.sh | bash")
                        Divider()
                        cliSection(.claude, installCommand: "npm install -g @anthropic-ai/claude-code")
                    }
                    .padding(6)
                }

                // Section 2: Codex & Web Extension Local HTTP API
                GroupBox("2. Codex CLI 与网页扩展本地接口（127.0.0.1）") {
                    VStack(alignment: .leading, spacing: 8) {
                        let port = viewModel.server.listeningPort ?? viewModel.server.requestedPort
                        let endpoint = "http://127.0.0.1:\(port)/v1/providers/gemini-web"

                        HStack {
                            Text("本机推送端点：")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(endpoint)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }

                        HStack {
                            Text("Bearer Token：")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            let token = viewModel.server.authToken
                            Text(showFullToken ? token : "\(token.prefix(8))••••••••\(token.suffix(6))")
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Button(showFullToken ? "隐藏" : "显示") {
                                showFullToken.toggle()
                            }
                            .controlSize(.small)
                            Button("复制 Token") {
                                copyToClipboard(token, label: "Token 已复制")
                            }
                            .controlSize(.small)
                        }

                        Text("Codex CLI 可将 rateLimits JSON 通过管道喂给：\(viewModel.ingestBinaryInstallPath) --provider codex")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(6)
                }

                // Section 3: Display Preferences
                GroupBox("3. 卡片显示偏好") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("毛玻璃透明度")
                            Slider(value: $preferences.glassOpacity, in: 0.18...0.92)
                            Text("\(Int((preferences.glassOpacity * 100).rounded()))%")
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 42, alignment: .trailing)
                        }

                        HStack {
                            Text("卡片缩放比例")
                            Slider(value: $preferences.cardScale, in: WindowGeometry.minScale...WindowGeometry.maxScale)
                            Text("\(Int((preferences.cardScale * 100).rounded()))%")
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 42, alignment: .trailing)
                        }

                        Picker("外观风格", selection: $preferences.appearance) {
                            ForEach(AppAppearance.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        VStack(alignment: .leading, spacing: 4) {
                            Picker("额度刷新策略", selection: $preferences.refreshMode) {
                                ForEach(RefreshMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            Text(preferences.refreshMode.summaryDescription)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Toggle("强制显示演示数据（预览三池与倒计时效果）", isOn: $preferences.forceDemoMode)
                        Toggle("在顶部菜单栏显示最低额度与 Token 速览", isOn: $preferences.showMenuBarText)
                        Toggle("开启调试字段日志（仅记录脱敏 JSON 键结构到 ~/.quota-card/debug-schema.log）", isOn: $preferences.debugSchemaLogging)
                    }
                    .padding(6)
                }

                if let copiedHint {
                    Text(copiedHint)
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            .padding(18)
        }
        .frame(width: 500, height: 520)
        .onAppear {
            viewModel.refreshCLIStatuses()
        }
    }

    @ViewBuilder
    private func cliSection(_ cli: ManagedCLI, installCommand: String) -> some View {
        let status = viewModel.cliStatuses[cli]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(cli.displayName)
                    .font(.headline)
                Spacer()
                if let path = status?.binaryPath {
                    Label("已安装", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                        .help(path)
                } else {
                    Label("未检测到二进制", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            if status?.binaryPath == nil {
                HStack {
                    Text(installCommand)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
                    Button("复制安装命令") {
                        copyToClipboard(installCommand, label: "安装命令已复制")
                    }
                    .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                if cli == .antigravity && status?.binaryPath != nil {
                    Button(viewModel.isRefreshing ? "正在拉取…" : "立即拉取实时额度") {
                        viewModel.triggerAntigravityPoll(trigger: .manual)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(viewModel.isRefreshing)
                }

                if status?.isHookConfigured == true {
                    if status?.binaryPath != nil {
                        Label(cli == .antigravity ? preferences.refreshMode.badgeText : "statusLine 钩子已生效", systemImage: "link.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Label("钩子已写入，请先安装 CLI", systemImage: "clock.badge.exclamationmark")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    Button("还原配置") {
                        viewModel.restoreHook(for: cli)
                    }
                    .controlSize(.small)
                } else {
                    Button("一键配置 statusLine 钩子") {
                        viewModel.installHook(for: cli)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Text("自动备份原 settings.json，保留原有状态栏")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let chained = status?.chainedOriginalCommand {
                Text("已链式保留原状态栏命令：\(chained)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func copyToClipboard(_ value: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedHint = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            copiedHint = nil
        }
    }
}
