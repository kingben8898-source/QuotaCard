import AppKit
import QuotaCardCore
import SwiftUI

struct QuotaCardView: View {
    @ObservedObject var viewModel: QuotaViewModel
    @ObservedObject var preferences: Preferences
    @Environment(\.colorScheme) private var systemColorScheme

    @State private var showOpacityDrawer: Bool = false

    let onOpenSettings: () -> Void
    let onCloseCard: () -> Void
    let onLayerModeChanged: (WindowLayerMode) -> Void
    let onContentSizeMayHaveChanged: () -> Void

    private var scale: CGFloat { CGFloat(preferences.cardScale) }
    private var cardWidth: CGFloat { CGFloat(WindowGeometry.baseCardWidth) * scale }
    private var windowColWidth: CGFloat { 108 * scale }
    private var cornerRadius: CGFloat { 22 * scale }

    var body: some View {
        let isDark = preferences.resolvedIsDark(systemColorScheme: systemColorScheme)
        let alpha = preferences.glassOpacity
        let primaryText = isDark ? Color.white.opacity(0.96) : Color(red: 0.08, green: 0.10, blue: 0.15)
        let secondaryText = isDark ? Color.white.opacity(0.66) : Color(red: 0.12, green: 0.15, blue: 0.22).opacity(0.68)
        let countdownText = isDark ? Color.white.opacity(0.88) : Color(red: 0.08, green: 0.10, blue: 0.15).opacity(0.84)
        let innerSurface = isDark ? Color.white.opacity(0.085) : Color.white.opacity(0.42)
        let innerBorder = isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
        let trackFill = isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.11)
        let dividerColor = isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
        let tintFill = isDark
            ? Color(red: 0.09, green: 0.10, blue: 0.15).opacity(alpha)
            : Color.white.opacity(alpha)

        VStack(spacing: 11 * scale) {
            headerBar(
                isDark: isDark,
                primaryText: primaryText,
                secondaryText: secondaryText,
                surface: innerSurface,
                border: innerBorder
            )

            if showOpacityDrawer {
                opacityAndScaleDrawer(
                    isDark: isDark,
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                    surface: innerSurface,
                    border: innerBorder
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let provider = viewModel.activeProvider {
                heroMetricsStrip(
                    provider: provider,
                    isDark: isDark,
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                    surface: innerSurface,
                    border: innerBorder
                )

                // Left-Right Matrix Header
                HStack(spacing: 10 * scale) {
                    Text("订阅剩余")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("5 小时")
                        .lineLimit(1)
                        .frame(width: windowColWidth, alignment: .center)
                    Text("每周")
                        .lineLimit(1)
                        .frame(width: windowColWidth, alignment: .center)
                }
                .font(.system(size: 11.5 * scale, weight: .semibold))
                .foregroundColor(secondaryText)
                .padding(.horizontal, 14 * scale)
                .padding(.top, 2 * scale)

                // Pool Rows
                VStack(spacing: 7 * scale) {
                    ForEach(provider.pools) { pool in
                        poolRow(
                            pool: pool,
                            isDark: isDark,
                            primaryText: primaryText,
                            secondaryText: secondaryText,
                            countdownText: countdownText,
                            surface: innerSurface,
                            border: innerBorder,
                            trackFill: trackFill
                        )
                    }
                }

                footerBar(
                    provider: provider,
                    secondaryText: secondaryText,
                    dividerColor: dividerColor
                )
            } else {
                unconfiguredTabView(
                    tab: viewModel.activeTab,
                    isDark: isDark,
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                    surface: innerSurface,
                    border: innerBorder,
                    dividerColor: dividerColor
                )
            }
        }
        .padding(16 * scale)
        .background(WindowDragHandle())
        .frame(width: cardWidth)
        .background(
            ZStack {
                VisualEffectBackground(isDark: isDark, cornerRadius: cornerRadius)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tintFill)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: isDark
                            ? [Color.white.opacity(0.30), Color.white.opacity(0.09)]
                            : [Color.white.opacity(0.88), Color.black.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(.easeInOut(duration: 0.16), value: showOpacityDrawer)
        .animation(.easeInOut(duration: 0.16), value: preferences.activeProviderId)
    }

    // MARK: - Subviews

    @ViewBuilder
    private func headerBar(
        isDark: Bool,
        primaryText: Color,
        secondaryText: Color,
        surface: Color,
        border: Color
    ) -> some View {
        HStack(spacing: 8 * scale) {
            // Segmented provider pills (always show AGY / Claude / Codex + any extras)
            HStack(spacing: 2 * scale) {
                ForEach(viewModel.providerTabs) { tab in
                    let selected = tab.id == viewModel.activeTab.id
                    Button {
                        preferences.activeProviderId = tab.id
                    } label: {
                        Text(tab.shortName)
                            .font(.system(size: 12 * scale, weight: selected ? .semibold : .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: true)
                            .foregroundColor(selected ? (isDark ? .white : Color(red: 0.06, green: 0.09, blue: 0.16)) : secondaryText)
                            .padding(.horizontal, 10 * scale)
                            .padding(.vertical, 5 * scale)
                            .background(
                                RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                                    .fill(selected ? (isDark ? Color.white.opacity(0.22) : Color.white.opacity(0.92)) : Color.clear)
                                    .shadow(color: selected ? Color.black.opacity(isDark ? 0.20 : 0.08) : .clear, radius: 2, y: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2.5 * scale)
            .background(
                RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                    .fill(surface)
                    .overlay(RoundedRectangle(cornerRadius: 9 * scale, style: .continuous).strokeBorder(border, lineWidth: 0.5))
            )

            Spacer(minLength: 6 * scale)

            // Utility buttons
            HStack(spacing: 5 * scale) {
                let isFloating = preferences.windowLayer == .floating
                Button {
                    let next: WindowLayerMode = isFloating ? .desktop : .floating
                    preferences.windowLayer = next
                    onLayerModeChanged(next)
                } label: {
                    HStack(spacing: 3 * scale) {
                        Image(systemName: isFloating ? "pin.fill" : "pin")
                            .font(.system(size: 10.5 * scale, weight: .semibold))
                        Text(isFloating ? "置顶" : "贴桌面")
                            .font(.system(size: 11.5 * scale, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                    .foregroundColor(isFloating ? .white : primaryText)
                    .padding(.horizontal, 8 * scale)
                    .frame(height: 26 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 7.5 * scale, style: .continuous)
                            .fill(isFloating ? (isDark ? Color.white.opacity(0.26) : Color.black.opacity(0.80)) : surface)
                            .overlay(RoundedRectangle(cornerRadius: 7.5 * scale, style: .continuous).strokeBorder(border, lineWidth: 0.5))
                    )
                }
                .buttonStyle(.plain)
                .help("切换贴桌面底层 / 悬浮置顶")

                iconButton(
                    systemName: "circle.lefthalf.filled",
                    active: showOpacityDrawer,
                    isDark: isDark,
                    primaryText: primaryText,
                    surface: surface,
                    border: border,
                    tooltip: "调节透明度、缩放比例与外观"
                ) {
                    showOpacityDrawer.toggle()
                    DispatchQueue.main.async {
                        onContentSizeMayHaveChanged()
                    }
                }

                iconButton(
                    systemName: "gearshape",
                    active: false,
                    isDark: isDark,
                    primaryText: primaryText,
                    surface: surface,
                    border: border,
                    tooltip: "CLI 接入与设置"
                ) {
                    onOpenSettings()
                }

                Button {
                    viewModel.reloadFromDisk()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5 * scale, weight: .medium))
                        .foregroundColor(primaryText)
                        .rotationEffect(.degrees(viewModel.isRefreshing ? 360 : 0))
                        .animation(viewModel.isRefreshing ? .linear(duration: 0.7).repeatForever(autoreverses: false) : .default, value: viewModel.isRefreshing)
                        .frame(width: 26 * scale, height: 26 * scale)
                        .background(
                            RoundedRectangle(cornerRadius: 7.5 * scale, style: .continuous)
                                .fill(surface)
                                .overlay(RoundedRectangle(cornerRadius: 7.5 * scale, style: .continuous).strokeBorder(border, lineWidth: 0.5))
                        )
                }
                .buttonStyle(.plain)
                .help("立即拉取最新额度")

                iconButton(
                    systemName: "xmark",
                    active: false,
                    isDark: isDark,
                    primaryText: secondaryText,
                    surface: surface,
                    border: border,
                    tooltip: "收起桌面卡片（可从顶部菜单栏重新打开）"
                ) {
                    onCloseCard()
                }
            }
        }
    }

    @ViewBuilder
    private func iconButton(
        systemName: String,
        active: Bool,
        isDark: Bool,
        primaryText: Color,
        surface: Color,
        border: Color,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5 * scale, weight: .medium))
                .foregroundColor(active ? .white : primaryText)
                .frame(width: 26 * scale, height: 26 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 7.5 * scale, style: .continuous)
                        .fill(active ? (isDark ? Color.white.opacity(0.26) : Color.black.opacity(0.80)) : surface)
                        .overlay(RoundedRectangle(cornerRadius: 7.5 * scale, style: .continuous).strokeBorder(border, lineWidth: 0.5))
                )
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    @ViewBuilder
    private func opacityAndScaleDrawer(
        isDark: Bool,
        primaryText: Color,
        secondaryText: Color,
        surface: Color,
        border: Color
    ) -> some View {
        VStack(spacing: 8 * scale) {
            HStack(spacing: 10 * scale) {
                Text("透明度")
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundColor(secondaryText)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(width: 44 * scale, alignment: .leading)
                Slider(value: $preferences.glassOpacity, in: 0.18...0.92)
                    .controlSize(.small)
                Text("\(Int((preferences.glassOpacity * 100).rounded()))%")
                    .font(.system(size: 12 * scale, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(primaryText)
                    .frame(width: 40 * scale, alignment: .trailing)
            }
            HStack(spacing: 10 * scale) {
                Text("缩放")
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundColor(secondaryText)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(width: 44 * scale, alignment: .leading)
                Slider(value: $preferences.cardScale, in: WindowGeometry.minScale...WindowGeometry.maxScale)
                    .controlSize(.small)
                Text("\(Int((preferences.cardScale * 100).rounded()))%")
                    .font(.system(size: 12 * scale, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(primaryText)
                    .frame(width: 40 * scale, alignment: .trailing)
            }
            HStack(spacing: 6 * scale) {
                Text("外观")
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundColor(secondaryText)
                Spacer()
                ForEach(AppAppearance.allCases) { mode in
                    let active = preferences.appearance == mode
                    Button {
                        preferences.appearance = mode
                    } label: {
                        Text(mode.label)
                            .font(.system(size: 11.5 * scale, weight: active ? .semibold : .regular))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: true)
                            .foregroundColor(active ? .white : primaryText)
                            .padding(.horizontal, 9 * scale)
                            .padding(.vertical, 3.5 * scale)
                            .background(
                                RoundedRectangle(cornerRadius: 6.5 * scale, style: .continuous)
                                    .fill(active ? Color.accentColor : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 9 * scale)
        .background(
            RoundedRectangle(cornerRadius: 13 * scale, style: .continuous)
                .fill(surface)
                .overlay(RoundedRectangle(cornerRadius: 13 * scale, style: .continuous).strokeBorder(border, lineWidth: 0.5))
        )
    }

    @ViewBuilder
    private func heroMetricsStrip(
        provider: ProviderSnapshot,
        isDark: Bool,
        primaryText: Color,
        secondaryText: Color,
        surface: Color,
        border: Color
    ) -> some View {
        let displayedTokens = provider.displayTokens(for: viewModel.now)
        HStack(alignment: .center, spacing: 12 * scale) {
            VStack(alignment: .leading, spacing: 3 * scale) {
                HStack(alignment: .firstTextBaseline, spacing: 7 * scale) {
                    Text(displayedTokens?.periodLabel ?? "今日 Token")
                        .font(.system(size: 11.5 * scale, weight: .medium))
                        .foregroundColor(secondaryText)
                        .lineLimit(1)
                    Text(displayedTokens.map { QuotaFormatters.formatTokens($0.total) } ?? "—")
                        .font(.system(size: 22 * scale, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(primaryText)
                        .lineLimit(1)
                }
                if let tokens = displayedTokens, let input = tokens.input, let output = tokens.output {
                    Text("入 \(QuotaFormatters.formatTokens(input))  ·  出 \(QuotaFormatters.formatTokens(output))")
                        .font(.system(size: 11.5 * scale, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8 * scale)

            VStack(alignment: .trailing, spacing: 2 * scale) {
                Text("最快重置")
                    .font(.system(size: 11.5 * scale, weight: .medium))
                    .foregroundColor(secondaryText)
                    .lineLimit(1)
                let soonest = provider.soonestFiveHourReset(now: viewModel.now)
                Text(QuotaFormatters.formatCountdown(to: soonest, now: viewModel.now))
                    .font(.system(size: 20 * scale, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(isDark ? Color(red: 0.45, green: 0.82, blue: 0.99) : Color(red: 0.00, green: 0.48, blue: 0.78))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14 * scale)
        .padding(.vertical, 10 * scale)
        .background(
            RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .fill(surface)
                .overlay(RoundedRectangle(cornerRadius: 14 * scale, style: .continuous).strokeBorder(border, lineWidth: 0.5))
        )
    }

    @ViewBuilder
    private func poolRow(
        pool: QuotaPool,
        isDark: Bool,
        primaryText: Color,
        secondaryText: Color,
        countdownText: Color,
        surface: Color,
        border: Color,
        trackFill: Color
    ) -> some View {
        HStack(alignment: .center, spacing: 10 * scale) {
            VStack(alignment: .leading, spacing: 3 * scale) {
                Text(pool.name)
                    .font(.system(size: 14.5 * scale, weight: .semibold))
                    .foregroundColor(primaryText)
                    .lineLimit(1)
                if let tokensUsed = pool.tokensUsed, let subtitle = pool.subtitle {
                    Text("\(QuotaFormatters.formatTokens(tokensUsed)) tok")
                        .font(.system(size: 11.5 * scale, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(secondaryText)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10.5 * scale, weight: .regular))
                        .foregroundColor(secondaryText.opacity(0.85))
                        .lineLimit(1)
                } else if let tokensUsed = pool.tokensUsed {
                    Text("\(QuotaFormatters.formatTokens(tokensUsed)) tok")
                        .font(.system(size: 11.5 * scale, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(secondaryText)
                        .lineLimit(1)
                } else if let subtitle = pool.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11 * scale, weight: .regular))
                        .foregroundColor(secondaryText.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            windowCell(
                window: pool.fiveHour,
                isDark: isDark,
                secondaryText: secondaryText,
                countdownText: countdownText,
                trackFill: trackFill
            )
            .frame(width: windowColWidth)

            windowCell(
                window: pool.weekly,
                isDark: isDark,
                secondaryText: secondaryText,
                countdownText: countdownText,
                trackFill: trackFill
            )
            .frame(width: windowColWidth)
        }
        .padding(.horizontal, 14 * scale)
        .padding(.vertical, 11 * scale)
        .background(
            RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .fill(surface)
                .overlay(RoundedRectangle(cornerRadius: 14 * scale, style: .continuous).strokeBorder(border, lineWidth: 0.5))
        )
    }

    @ViewBuilder
    private func windowCell(
        window: QuotaWindow?,
        isDark: Bool,
        secondaryText: Color,
        countdownText: Color,
        trackFill: Color
    ) -> some View {
        if let window {
            let pct = QuotaFormatters.clampPercent(window.remainingPercent)
            let style = semanticStyle(for: pct, isDark: isDark)
            VStack(alignment: .center, spacing: 5 * scale) {
                Text(QuotaFormatters.formatPercent(pct))
                    .font(.system(size: 19.5 * scale, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(style.textColor)
                    .lineLimit(1)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(trackFill)
                        Capsule()
                            .fill(style.barGradient)
                            .frame(width: max(pct > 0 ? 4 : 0, geo.size.width * CGFloat(pct / 100.0)))
                    }
                }
                .frame(height: 5.5 * scale)

                Text(QuotaFormatters.formatCountdown(to: window.resetAt, now: viewModel.now))
                    .font(.system(size: 12.5 * scale, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(countdownText)
                    .lineLimit(1)
            }
            .help("预计 \(QuotaFormatters.formatResetClock(window.resetAt)) 重置")
        } else {
            VStack(alignment: .center, spacing: 5 * scale) {
                Text("—")
                    .font(.system(size: 19 * scale, weight: .bold, design: .rounded))
                    .foregroundColor(secondaryText.opacity(0.65))
                Capsule()
                    .fill(trackFill)
                    .frame(height: 5.5 * scale)
                Text("—")
                    .font(.system(size: 12 * scale, weight: .medium, design: .rounded))
                    .foregroundColor(secondaryText.opacity(0.45))
            }
        }
    }

    @ViewBuilder
    private func footerBar(provider: ProviderSnapshot, secondaryText: Color, dividerColor: Color) -> some View {
        let isDemo = viewModel.isShowingDemo
        let isStale = !isDemo && provider.isPoolsStale(now: viewModel.now)
        let dotColor: Color = isDemo ? .blue : (isStale ? .orange : .green)

        VStack(spacing: 0) {
            Rectangle().fill(dividerColor).frame(height: 0.75).padding(.bottom, 8 * scale)
            HStack {
                HStack(spacing: 6 * scale) {
                    Circle().fill(dotColor).frame(width: 7 * scale, height: 7 * scale)
                    if isDemo {
                        Button {
                            onOpenSettings()
                        } label: {
                            Text("演示数据 · 点击接入 agy CLI")
                                .font(.system(size: 11.5 * scale, weight: .medium))
                                .foregroundColor(secondaryText)
                                .underline()
                        }
                        .buttonStyle(.plain)
                    } else {
                        let rel = QuotaFormatters.formatRelativeSync(since: provider.poolsUpdatedAt ?? provider.updatedAt, now: viewModel.now)
                        Text(isStale ? "\(provider.source) · 数据较旧（\(rel)）" : "\(provider.source) · \(rel)")
                            .font(.system(size: 11.5 * scale, weight: .medium))
                            .foregroundColor(secondaryText)
                    }
                }
                Spacer()
                Text(preferences.windowLayer.footerLabel)
                    .font(.system(size: 11.5 * scale, weight: .medium))
                    .foregroundColor(secondaryText)
            }
        }
    }

    @ViewBuilder
    private func unconfiguredTabView(
        tab: ProviderTabItem,
        isDark: Bool,
        primaryText: Color,
        secondaryText: Color,
        surface: Color,
        border: Color,
        dividerColor: Color
    ) -> some View {
        VStack(spacing: 10 * scale) {
            Text("\(tab.displayName) 尚未同步实时额度")
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundColor(primaryText)

            if tab.id == "claude" {
                let status = viewModel.cliStatuses[.claude]
                if status?.isHookConfigured == true {
                    Text("statusLine 钩子已配置，在终端运行一次 claude 并对话即可自动同步 5h / 每周额度与 Token。")
                        .font(.system(size: 12 * scale))
                        .foregroundColor(secondaryText)
                        .multilineTextAlignment(.center)
                } else {
                    Text("已检测到本机 Claude Code，点击下方按钮即可一键接入。")
                        .font(.system(size: 12 * scale))
                        .foregroundColor(secondaryText)
                        .multilineTextAlignment(.center)
                    Button("一键配置 Claude Code 钩子") {
                        viewModel.installHook(for: .claude)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else if tab.id == "codex" {
                Text("通过管道将 Codex rateLimits JSON 喂给本地脚本，或在设置页查看本机 HTTP 推送接口。")
                    .font(.system(size: 12 * scale))
                    .foregroundColor(secondaryText)
                    .multilineTextAlignment(.center)
                Button("查看接入说明与接口") {
                    onOpenSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button("打开设置与接入引导") {
                    onOpenSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 18 * scale)
        .padding(.vertical, 26 * scale)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .fill(surface)
                .overlay(RoundedRectangle(cornerRadius: 14 * scale, style: .continuous).strokeBorder(border, lineWidth: 0.5))
        )

        VStack(spacing: 0) {
            Rectangle().fill(dividerColor).frame(height: 0.75).padding(.bottom, 8 * scale)
            HStack {
                HStack(spacing: 6 * scale) {
                    Circle().fill(Color.gray.opacity(0.6)).frame(width: 7 * scale, height: 7 * scale)
                    Text("等待 \(tab.shortName) 首次数据推送")
                        .font(.system(size: 11.5 * scale, weight: .medium))
                        .foregroundColor(secondaryText)
                }
                Spacer()
                Text(preferences.windowLayer.footerLabel)
                    .font(.system(size: 11.5 * scale, weight: .medium))
                    .foregroundColor(secondaryText)
            }
        }
    }

    private func semanticStyle(for pct: Double, isDark: Bool) -> (barGradient: LinearGradient, textColor: Color) {
        if pct <= 20 {
            return (
                LinearGradient(colors: [Color(red: 0.96, green: 0.25, blue: 0.37), Color(red: 0.98, green: 0.44, blue: 0.52)], startPoint: .leading, endPoint: .trailing),
                isDark ? Color(red: 1.00, green: 0.56, blue: 0.62) : Color(red: 0.85, green: 0.11, blue: 0.26)
            )
        }
        if pct <= 45 {
            return (
                LinearGradient(colors: [Color(red: 0.96, green: 0.60, blue: 0.04), Color(red: 0.98, green: 0.74, blue: 0.14)], startPoint: .leading, endPoint: .trailing),
                isDark ? Color(red: 0.99, green: 0.81, blue: 0.28) : Color(red: 0.75, green: 0.36, blue: 0.03)
            )
        }
        return (
            isDark
                ? LinearGradient(colors: [Color.white.opacity(0.86), Color.white], startPoint: .leading, endPoint: .trailing)
                : LinearGradient(colors: [Color(red: 0.06, green: 0.72, blue: 0.50), Color(red: 0.05, green: 0.64, blue: 0.90)], startPoint: .leading, endPoint: .trailing),
            isDark ? Color.white : Color(red: 0.08, green: 0.10, blue: 0.15)
        )
    }
}
