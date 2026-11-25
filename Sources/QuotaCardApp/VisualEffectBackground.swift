import AppKit
import SwiftUI

@MainActor
private func isNearWindowEdge(event: NSEvent, window: NSWindow, edgeMargin: CGFloat = 7) -> Bool {
    let p = event.locationInWindow
    let size = window.frame.size
    return p.x <= edgeMargin
        || p.x >= size.width - edgeMargin
        || p.y <= edgeMargin
        || p.y >= size.height - edgeMargin
}

final class DraggableVisualEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if isNearWindowEdge(event: event, window: window) {
            super.mouseDown(with: event)
            return
        }
        window.performDrag(with: event)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    let isDark: Bool
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> DraggableVisualEffectView {
        let view = DraggableVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        applyAppearance(to: view)
        return view
    }

    func updateNSView(_ nsView: DraggableVisualEffectView, context: Context) {
        nsView.layer?.cornerRadius = cornerRadius
        applyAppearance(to: nsView)
    }

    private func applyAppearance(to view: NSVisualEffectView) {
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        view.material = isDark ? .hudWindow : .popover
    }
}

final class WindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if isNearWindowEdge(event: event, window: window) {
            super.mouseDown(with: event)
            return
        }
        window.performDrag(with: event)
    }
}

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragNSView {
        WindowDragNSView()
    }

    func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}
