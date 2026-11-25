import AppKit
import Combine
import Foundation
import QuotaCardCore
import SwiftUI

public enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }
}

public enum WindowLayerMode: String, CaseIterable, Identifiable {
    case desktop
    case floating

    public var id: String { rawValue }

    public var shortLabel: String {
        switch self {
        case .desktop: return "贴桌面"
        case .floating: return "置顶"
        }
    }

    public var footerLabel: String {
        switch self {
        case .desktop: return "贴桌面层"
        case .floating: return "悬浮置顶"
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    private enum Keys {
        static let appearance = "quotacard.appearance"
        static let windowLayer = "quotacard.windowLayer"
        static let glassOpacity = "quotacard.glassOpacity"
        static let cardScale = "quotacard.cardScale"
        static let activeProviderId = "quotacard.activeProviderId"
        static let forceDemoMode = "quotacard.forceDemoMode"
        static let showMenuBarText = "quotacard.showMenuBarText"
        static let debugSchemaLogging = "quotacard.debugSchemaLogging"
        static let refreshMode = "quotacard.refreshMode"
        static let savedOriginX = "quotacard.savedOriginX"
        static let savedOriginY = "quotacard.savedOriginY"
        static let hasSavedOrigin = "quotacard.hasSavedOrigin"
    }

    private let defaults: UserDefaults

    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    @Published var windowLayer: WindowLayerMode {
        didSet { defaults.set(windowLayer.rawValue, forKey: Keys.windowLayer) }
    }

    @Published var glassOpacity: Double {
        didSet {
            let clamped = min(0.92, max(0.18, glassOpacity))
            if clamped != glassOpacity { glassOpacity = clamped }
            defaults.set(clamped, forKey: Keys.glassOpacity)
        }
    }

    @Published var cardScale: Double {
        didSet {
            let clamped = WindowGeometry.clampScale(cardScale)
            if abs(clamped - cardScale) > 0.0001 { cardScale = clamped }
            defaults.set(clamped, forKey: Keys.cardScale)
        }
    }

    @Published var activeProviderId: String {
        didSet { defaults.set(activeProviderId, forKey: Keys.activeProviderId) }
    }

    @Published var forceDemoMode: Bool {
        didSet { defaults.set(forceDemoMode, forKey: Keys.forceDemoMode) }
    }

    @Published var showMenuBarText: Bool {
        didSet { defaults.set(showMenuBarText, forKey: Keys.showMenuBarText) }
    }

    @Published var debugSchemaLogging: Bool {
        didSet {
            defaults.set(debugSchemaLogging, forKey: Keys.debugSchemaLogging)
            syncDebugSchemaMarker()
        }
    }

    @Published var refreshMode: RefreshMode {
        didSet { defaults.set(refreshMode.rawValue, forKey: Keys.refreshMode) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedAppearance = defaults.string(forKey: Keys.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .dark
        let savedLayer = defaults.string(forKey: Keys.windowLayer).flatMap(WindowLayerMode.init(rawValue:)) ?? .desktop
        let savedOpacity = defaults.object(forKey: Keys.glassOpacity) as? Double ?? 0.52
        let savedScale = defaults.object(forKey: Keys.cardScale) as? Double ?? 1.0
        let savedRefreshMode = defaults.string(forKey: Keys.refreshMode).flatMap(RefreshMode.init(rawValue:)) ?? .smart
        self.appearance = savedAppearance
        self.windowLayer = savedLayer
        self.glassOpacity = min(0.92, max(0.18, savedOpacity))
        self.cardScale = WindowGeometry.clampScale(savedScale)
        self.activeProviderId = defaults.string(forKey: Keys.activeProviderId) ?? "antigravity"
        self.forceDemoMode = defaults.object(forKey: Keys.forceDemoMode) as? Bool ?? false
        self.showMenuBarText = defaults.object(forKey: Keys.showMenuBarText) as? Bool ?? true
        self.debugSchemaLogging = defaults.object(forKey: Keys.debugSchemaLogging) as? Bool ?? false
        self.refreshMode = savedRefreshMode
        syncDebugSchemaMarker()
    }

    private func syncDebugSchemaMarker() {
        let dir = StateStore.defaultDirectory()
        let marker = dir.appendingPathComponent("debug-schema-enabled")
        if debugSchemaLogging {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data("1\n".utf8).write(to: marker, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
    }

    var savedOrigin: CGPoint? {
        guard defaults.bool(forKey: Keys.hasSavedOrigin) else { return nil }
        return CGPoint(
            x: defaults.double(forKey: Keys.savedOriginX),
            y: defaults.double(forKey: Keys.savedOriginY)
        )
    }

    func saveOrigin(_ origin: CGPoint) {
        defaults.set(true, forKey: Keys.hasSavedOrigin)
        defaults.set(Double(origin.x), forKey: Keys.savedOriginX)
        defaults.set(Double(origin.y), forKey: Keys.savedOriginY)
    }

    func resolvedIsDark(systemColorScheme: ColorScheme) -> Bool {
        switch appearance {
        case .system: return systemColorScheme == .dark
        case .dark: return true
        case .light: return false
        }
    }
}
