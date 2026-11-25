import CoreGraphics
import Foundation
@testable import QuotaCardCore

enum WindowGeometryTests {
    static var all: [TestCase] {
        [
            TestCase(suite: "WindowGeometryTests", name: "offScreenSavedOriginClampsIntoPrimaryVisibleFrame") {
                let primary = CGRect(x: 0, y: 0, width: 1440, height: 875)
                let windowSize = CGSize(width: 444, height: 340)
                // Saved on a disconnected external monitor at x = 2200
                let saved = CGPoint(x: 2200, y: 400)
                let resolved = WindowGeometry.clampOrigin(
                    savedOrigin: saved,
                    windowSize: windowSize,
                    visibleFrames: [primary],
                    primaryVisibleFrame: primary
                )
                try expect(resolved.x >= primary.minX)
                try expect(resolved.x + windowSize.width <= primary.maxX)
                try expect(resolved.y >= primary.minY)
                try expect(resolved.y + windowSize.height <= primary.maxY)
            },
            TestCase(suite: "WindowGeometryTests", name: "onScreenSecondaryMonitorOriginIsPreserved") {
                let primary = CGRect(x: 0, y: 0, width: 1440, height: 875)
                let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
                let windowSize = CGSize(width: 444, height: 340)
                let saved = CGPoint(x: 1600, y: 200)
                let resolved = WindowGeometry.clampOrigin(
                    savedOrigin: saved,
                    windowSize: windowSize,
                    visibleFrames: [primary, secondary],
                    primaryVisibleFrame: primary
                )
                try expectEqual(resolved, saved)
            },
            TestCase(suite: "WindowGeometryTests", name: "clampFrameAfterResizePreventsBottomEdgeClipping") {
                let primary = CGRect(x: 0, y: 0, width: 1440, height: 875)
                // Window sitting near bottom edge (y = 20, height = 300) expands to height = 400
                let oldFrame = CGRect(x: 960, y: 20, width: 444, height: 300)
                let resized = WindowGeometry.clampFrameAfterResize(
                    oldFrame: oldFrame,
                    newSize: CGSize(width: 444, height: 400),
                    visibleFrames: [primary],
                    primaryVisibleFrame: primary
                )
                try expect(resized.minY >= primary.minY, "Expanded card should not clip below visible screen minY")
                try expect(resized.maxY <= primary.maxY)
                try expectEqual(resized.height, 400)
            },
            TestCase(suite: "WindowGeometryTests", name: "clampScaleBoundsAndWidthConversion") {
                try expectEqual(WindowGeometry.clampScale(0.3), 0.75)
                try expectEqual(WindowGeometry.clampScale(2.5), 1.45)
                try expect(abs(WindowGeometry.clampScale(1.15) - 1.15) < 0.0001)
                let scaleFromWidth = WindowGeometry.scale(forWidth: 532.8, baseWidth: 444.0)
                try expect(abs(scaleFromWidth - 1.2) < 0.001)
            },
            TestCase(suite: "WindowGeometryTests", name: "proportionalResizeHandlesHorizontalVerticalAndClamping") {
                let currentSize = CGSize(width: 444, height: 320)
                // Horizontal edge drag (e.g. left/right edge to 1.25x width)
                let horiz = WindowGeometry.proportionalResize(
                    currentSize: currentSize,
                    proposedSize: CGSize(width: 555, height: 320),
                    currentScale: 1.0
                )
                try expect(abs(horiz.scale - 1.25) < 0.001)
                try expect(abs(horiz.size.width - 555) < 0.5)
                try expect(abs(horiz.size.height - 400) < 0.5)

                // Vertical edge drag (e.g. top/bottom edge to 0.8x height)
                let vert = WindowGeometry.proportionalResize(
                    currentSize: currentSize,
                    proposedSize: CGSize(width: 444, height: 256),
                    currentScale: 1.0
                )
                try expect(abs(vert.scale - 0.8) < 0.001)
                try expect(abs(vert.size.width - 355.2) < 0.5)
                try expect(abs(vert.size.height - 256) < 0.5)

                // Clamps beyond maxScale (1.45)
                let clamped = WindowGeometry.proportionalResize(
                    currentSize: currentSize,
                    proposedSize: CGSize(width: 900, height: 700),
                    currentScale: 1.0
                )
                try expectEqual(clamped.scale, WindowGeometry.maxScale)
                try expect(abs(clamped.size.width - 444 * 1.45) < 0.5)
            },
            TestCase(suite: "WindowGeometryTests", name: "edgeHitTestDetectsAllEightZonesAndInterior") {
                let size = CGSize(width: 444, height: 320)
                try expectEqual(WindowGeometry.edge(at: CGPoint(x: 2, y: 2), in: size), .bottomLeft)
                try expectEqual(WindowGeometry.edge(at: CGPoint(x: 442, y: 2), in: size), .bottomRight)
                try expectEqual(WindowGeometry.edge(at: CGPoint(x: 2, y: 318), in: size), .topLeft)
                try expectEqual(WindowGeometry.edge(at: CGPoint(x: 442, y: 318), in: size), .topRight)
                try expectEqual(WindowGeometry.edge(at: CGPoint(x: 2, y: 160), in: size), .left)
                try expectEqual(WindowGeometry.edge(at: CGPoint(x: 442, y: 160), in: size), .right)
                try expectEqual(WindowGeometry.edge(at: CGPoint(x: 222, y: 318), in: size), .top)
                try expectEqual(WindowGeometry.edge(at: CGPoint(x: 222, y: 2), in: size), .bottom)
                try expectEqual(WindowGeometry.edge(at: CGPoint(x: 222, y: 160), in: size), .none)
            },
            TestCase(suite: "WindowGeometryTests", name: "anchoredResizeKeepsOppositeEdgeFixed") {
                let start = CGRect(x: 300, y: 200, width: 444, height: 320)
                // Dragging left edge left by -88.8pt (scale -> 1.2x) keeps maxX fixed at 744
                let leftDrag = WindowGeometry.anchoredResize(
                    edge: .left,
                    startFrame: start,
                    startScale: 1.0,
                    delta: CGSize(width: -88.8, height: 0)
                )
                try expect(abs(leftDrag.scale - 1.2) < 0.001)
                try expect(abs(leftDrag.frame.maxX - start.maxX) < 0.5)
                try expect(abs(leftDrag.frame.maxY - start.maxY) < 0.5)

                // Dragging top edge upward by +64pt (scale -> 1.2x) keeps minY fixed at 200
                let topDrag = WindowGeometry.anchoredResize(
                    edge: .top,
                    startFrame: start,
                    startScale: 1.0,
                    delta: CGSize(width: 0, height: 64)
                )
                try expect(abs(topDrag.scale - 1.2) < 0.001)
                try expect(abs(topDrag.frame.minY - start.minY) < 0.5)
                try expect(abs(topDrag.frame.minX - start.minX) < 0.5)

                // Dragging top-left corner keeps bottom-right (maxX, minY) fixed
                let tlDrag = WindowGeometry.anchoredResize(
                    edge: .topLeft,
                    startFrame: start,
                    startScale: 1.0,
                    delta: CGSize(width: -88.8, height: 64)
                )
                try expect(abs(tlDrag.scale - 1.2) < 0.001)
                try expect(abs(tlDrag.frame.maxX - start.maxX) < 0.5)
                try expect(abs(tlDrag.frame.minY - start.minY) < 0.5)
            }
        ]
    }
}
