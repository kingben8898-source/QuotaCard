import AppKit
import QuotaCardCore
import SwiftUI

final class NonActivatingGlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class WeakPanelBox {
    weak var controller: FloatingPanelController?
}

@MainActor
private final class EdgeResizeOverlayView: NSView {
    var onBeginResize: (() -> Void)?
    var onApplyResize: ((ResizeEdge, CGRect, Double, CGSize) -> Void)?
    var onEndResize: (() -> Void)?
    var currentScaleProvider: (() -> Double)?

    private var trackingAreaRef: NSTrackingArea?
    private var lastHoverEdge: ResizeEdge = .none
    private let edgeThickness: CGFloat = 9
    private let cornerSize: CGFloat = 16

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let edge = WindowGeometry.edge(at: local, in: bounds.size, edgeThickness: edgeThickness, cornerSize: cornerSize)
        return edge == .none ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let edge = WindowGeometry.edge(at: local, in: bounds.size, edgeThickness: edgeThickness, cornerSize: cornerSize)
        if edge != .none {
            cursor(for: edge).set()
        } else if lastHoverEdge != .none {
            NSCursor.arrow.set()
        }
        lastHoverEdge = edge
    }

    override func mouseExited(with event: NSEvent) {
        if lastHoverEdge != .none {
            NSCursor.arrow.set()
            lastHoverEdge = .none
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let local = convert(event.locationInWindow, from: nil)
        let edge = WindowGeometry.edge(at: local, in: bounds.size, edgeThickness: edgeThickness, cornerSize: cornerSize)
        guard edge != .none else { return }

        let startFrame = window.frame
        let startMouse = NSEvent.mouseLocation
        let startScale = currentScaleProvider?() ?? 1.0

        cursor(for: edge).set()
        onBeginResize?()

        while true {
            guard let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            if nextEvent.type == .leftMouseUp {
                break
            }
            let currentMouse = NSEvent.mouseLocation
            let delta = CGSize(width: currentMouse.x - startMouse.x, height: currentMouse.y - startMouse.y)
            cursor(for: edge).set()
            onApplyResize?(edge, startFrame, startScale, delta)
        }

        NSCursor.arrow.set()
        onEndResize?()
    }

    private func cursor(for edge: ResizeEdge) -> NSCursor {
        if #available(macOS 15.0, *) {
            switch edge {
            case .left:
                return .frameResize(position: .left, directions: .all)
            case .right:
                return .frameResize(position: .right, directions: .all)
            case .top:
                return .frameResize(position: .top, directions: .all)
            case .bottom:
                return .frameResize(position: .bottom, directions: .all)
            case .topLeft:
                return .frameResize(position: .topLeft, directions: .all)
            case .topRight:
                return .frameResize(position: .topRight, directions: .all)
            case .bottomLeft:
                return .frameResize(position: .bottomLeft, directions: .all)
            case .bottomRight:
                return .frameResize(position: .bottomRight, directions: .all)
            case .none:
                return .arrow
            }
        } else {
            switch edge {
            case .left, .right:
                return .resizeLeftRight
            case .top, .bottom:
                return .resizeUpDown
            case .topLeft, .topRight, .bottomLeft, .bottomRight:
                return .crosshair
            case .none:
                return .arrow
            }
        }
    }
}

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    let panel: NonActivatingGlassPanel
    private let preferences: Preferences
    private let hostingView: NSHostingView<QuotaCardView>
    private let containerView: NSView
    private let resizeOverlay: EdgeResizeOverlayView
    private var isUserLiveResizing: Bool = false

    init(
        viewModel: QuotaViewModel,
        preferences: Preferences,
        onOpenSettings: @escaping () -> Void
    ) {
        self.preferences = preferences

        let initialRect = NSRect(x: 200, y: 200, width: 444, height: 340)
        self.panel = NonActivatingGlassPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        let box = WeakPanelBox()
        let rootView = QuotaCardView(
            viewModel: viewModel,
            preferences: preferences,
            onOpenSettings: onOpenSettings,
            onCloseCard: {
                box.controller?.hide()
            },
            onLayerModeChanged: { mode in
                box.controller?.applyWindowLayer(mode)
            },
            onContentSizeMayHaveChanged: {
                box.controller?.resizeToFitContent()
            }
        )
        self.hostingView = NSHostingView(rootView: rootView)
        self.containerView = NSView(frame: NSRect(origin: .zero, size: initialRect.size))
        self.resizeOverlay = EdgeResizeOverlayView(frame: NSRect(origin: .zero, size: initialRect.size))

        super.init()
        box.controller = self

        hostingView.frame = containerView.bounds
        hostingView.autoresizingMask = [.width, .height]
        resizeOverlay.frame = containerView.bounds
        resizeOverlay.autoresizingMask = [.width, .height]

        resizeOverlay.currentScaleProvider = { [weak self] in
            self?.preferences.cardScale ?? 1.0
        }
        resizeOverlay.onBeginResize = { [weak self] in
            self?.isUserLiveResizing = true
        }
        resizeOverlay.onApplyResize = { [weak self] edge, startFrame, startScale, delta in
            guard let self else { return }
            let result = WindowGeometry.anchoredResize(
                edge: edge,
                startFrame: startFrame,
                startScale: startScale,
                delta: delta
            )
            if abs(result.scale - self.preferences.cardScale) > 0.002 {
                self.preferences.cardScale = result.scale
            }
            self.panel.setFrame(result.frame, display: true, animate: false)
        }
        resizeOverlay.onEndResize = { [weak self] in
            guard let self else { return }
            self.isUserLiveResizing = false
            self.preferences.saveOrigin(self.panel.frame.origin)
            DispatchQueue.main.async { [weak self] in
                self?.resizeToFitContent()
            }
        }

        containerView.addSubview(hostingView)
        containerView.addSubview(resizeOverlay)

        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentView = containerView

        applyWindowLayer(preferences.windowLayer)
        restoreOrDefaultPosition()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleScreenParametersDidChange() {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let primaryFrame = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let clampedOrigin = WindowGeometry.clampOrigin(
            savedOrigin: panel.frame.origin,
            windowSize: panel.frame.size,
            visibleFrames: visibleFrames,
            primaryVisibleFrame: primaryFrame
        )
        if abs(clampedOrigin.x - panel.frame.origin.x) > 0.5 || abs(clampedOrigin.y - panel.frame.origin.y) > 0.5 {
            panel.setFrameOrigin(clampedOrigin)
            preferences.saveOrigin(clampedOrigin)
        }
    }

    func show() {
        resizeToFitContent()
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggleVisibility() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func applyWindowLayer(_ mode: WindowLayerMode) {
        switch mode {
        case .desktop:
            let desktopLevel = Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
            panel.level = NSWindow.Level(rawValue: desktopLevel)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        case .floating:
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        }
    }

    func resizeToFitContent() {
        guard !isUserLiveResizing else { return }
        let fitting = hostingView.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return }
        let oldFrame = panel.frame
        guard abs(oldFrame.height - fitting.height) > 0.5 || abs(oldFrame.width - fitting.width) > 0.5 else {
            return
        }
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let primaryFrame = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let clamped = WindowGeometry.clampFrameAfterResize(
            oldFrame: oldFrame,
            newSize: fitting,
            visibleFrames: visibleFrames,
            primaryVisibleFrame: primaryFrame
        )
        panel.setFrame(clamped, display: true, animate: false)
    }

    private func restoreOrDefaultPosition() {
        let fitting = hostingView.fittingSize
        let size = CGSize(width: max(333, fitting.width), height: max(220, fitting.height))
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let primaryFrame = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let origin: CGPoint
        if let saved = preferences.savedOrigin {
            origin = WindowGeometry.clampOrigin(
                savedOrigin: saved,
                windowSize: size,
                visibleFrames: visibleFrames,
                primaryVisibleFrame: primaryFrame
            )
        } else {
            origin = WindowGeometry.defaultOrigin(windowSize: size, primaryVisibleFrame: primaryFrame)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func windowDidMove(_ notification: Notification) {
        preferences.saveOrigin(panel.frame.origin)
    }
}
