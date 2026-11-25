import AppKit
import Combine
import QuotaCardCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var preferences: Preferences!
    private var viewModel: QuotaViewModel!
    private var panelController: FloatingPanelController!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        preferences = Preferences()
        viewModel = QuotaViewModel(preferences: preferences)

        panelController = FloatingPanelController(
            viewModel: viewModel,
            preferences: preferences,
            onOpenSettings: { [weak self] in
                self?.openSettingsWindow()
            }
        )

        setupMenuBar()
        observeMenuBarUpdates()
        panelController.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.shutdown()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItemTitle()

        let menu = NSMenu()
        menu.addItem(withTitle: "显示 / 隐藏桌面卡片", action: #selector(toggleCard), keyEquivalent: "k")
        menu.addItem(withTitle: "切换贴桌面 / 悬浮置顶", action: #selector(toggleLayer), keyEquivalent: "p")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "立即刷新数据", action: #selector(refreshNow), keyEquivalent: "r")
        menu.addItem(withTitle: "CLI 接入与设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出 QuotaCard", action: #selector(quitApp), keyEquivalent: "q")

        for item in menu.items {
            item.target = self
        }
        statusItem.menu = menu
    }

    private func observeMenuBarUpdates() {
        viewModel.$now
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemTitle()
            }
            .store(in: &cancellables)

        viewModel.$liveState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemTitle()
                DispatchQueue.main.async {
                    self?.panelController.resizeToFitContent()
                }
            }
            .store(in: &cancellables)

        preferences.$windowLayer
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.panelController.applyWindowLayer(mode)
            }
            .store(in: &cancellables)

        preferences.$activeProviderId
            .combineLatest(preferences.$forceDemoMode, preferences.$showMenuBarText, preferences.$cardScale)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.updateStatusItemTitle()
                DispatchQueue.main.async {
                    self?.panelController.resizeToFitContent()
                }
            }
            .store(in: &cancellables)
    }

    private func updateStatusItemTitle() {
        statusItem?.button?.title = viewModel.menuBarTitle
        statusItem?.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    }

    @objc private func toggleCard() {
        panelController.toggleVisibility()
    }

    @objc private func toggleLayer() {
        let next: WindowLayerMode = preferences.windowLayer == .desktop ? .floating : .desktop
        preferences.windowLayer = next
        panelController.applyWindowLayer(next)
    }

    @objc private func refreshNow() {
        viewModel.reloadFromDisk()
    }

    @objc private func openSettings() {
        openSettingsWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func openSettingsWindow() {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsSheetView(viewModel: viewModel, preferences: preferences)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "QuotaCard 设置与 CLI 接入"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
