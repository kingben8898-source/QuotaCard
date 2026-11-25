import CoreGraphics
import Foundation

public enum ResizeEdge: Equatable, Sendable {
    case none
    case left
    case right
    case top
    case bottom
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

public enum WindowGeometry {
    public static let minScale: Double = 0.75
    public static let maxScale: Double = 1.45
    public static let baseCardWidth: Double = 444.0

    public static func clampScale(_ scale: Double) -> Double {
        guard scale.isFinite else { return 1.0 }
        return min(maxScale, max(minScale, scale))
    }

    public static func scale(forWidth width: Double, baseWidth: Double = baseCardWidth) -> Double {
        guard baseWidth > 0, width.isFinite else { return 1.0 }
        return clampScale(width / baseWidth)
    }

    public static func proportionalResize(
        currentSize: CGSize,
        proposedSize: CGSize,
        currentScale: Double,
        baseWidth: Double = baseCardWidth
    ) -> (scale: Double, size: CGSize) {
        let safeScale = clampScale(currentScale)
        let baseHeight = max(120.0, Double(currentSize.height) / safeScale)
        let widthRatioDelta = abs(Double(proposedSize.width) - Double(currentSize.width)) / max(1.0, Double(currentSize.width))
        let heightRatioDelta = abs(Double(proposedSize.height) - Double(currentSize.height)) / max(1.0, Double(currentSize.height))

        let targetScale: Double
        if widthRatioDelta >= heightRatioDelta {
            targetScale = clampScale(Double(proposedSize.width) / baseWidth)
        } else {
            targetScale = clampScale(Double(proposedSize.height) / baseHeight)
        }
        return (
            scale: targetScale,
            size: CGSize(width: baseWidth * targetScale, height: baseHeight * targetScale)
        )
    }

    public static func edge(
        at point: CGPoint,
        in size: CGSize,
        edgeThickness: CGFloat = 9,
        cornerSize: CGFloat = 16
    ) -> ResizeEdge {
        guard point.x >= 0, point.x <= size.width, point.y >= 0, point.y <= size.height else {
            return .none
        }
        let nearLeft = point.x <= edgeThickness
        let nearRight = point.x >= size.width - edgeThickness
        let nearBottom = point.y <= edgeThickness
        let nearTop = point.y >= size.height - edgeThickness

        let inLeftCorner = point.x <= cornerSize
        let inRightCorner = point.x >= size.width - cornerSize
        let inBottomCorner = point.y <= cornerSize
        let inTopCorner = point.y >= size.height - cornerSize

        if (nearLeft || nearTop) && inLeftCorner && inTopCorner { return .topLeft }
        if (nearRight || nearTop) && inRightCorner && inTopCorner { return .topRight }
        if (nearLeft || nearBottom) && inLeftCorner && inBottomCorner { return .bottomLeft }
        if (nearRight || nearBottom) && inRightCorner && inBottomCorner { return .bottomRight }

        if nearLeft { return .left }
        if nearRight { return .right }
        if nearTop { return .top }
        if nearBottom { return .bottom }
        return .none
    }

    public static func anchoredResize(
        edge: ResizeEdge,
        startFrame: CGRect,
        startScale: Double,
        delta: CGSize,
        baseWidth: Double = baseCardWidth
    ) -> (scale: Double, frame: CGRect) {
        let safeScale = clampScale(startScale)
        let baseHeight = max(120.0, Double(startFrame.height) / safeScale)

        let proposedWidth: Double
        let proposedHeight: Double

        switch edge {
        case .none:
            return (safeScale, startFrame)
        case .right:
            proposedWidth = Double(startFrame.width + delta.width)
            proposedHeight = Double(startFrame.height)
        case .left:
            proposedWidth = Double(startFrame.width - delta.width)
            proposedHeight = Double(startFrame.height)
        case .top:
            proposedWidth = Double(startFrame.width)
            proposedHeight = Double(startFrame.height + delta.height)
        case .bottom:
            proposedWidth = Double(startFrame.width)
            proposedHeight = Double(startFrame.height - delta.height)
        case .topRight:
            proposedWidth = Double(startFrame.width + delta.width)
            proposedHeight = Double(startFrame.height + delta.height)
        case .topLeft:
            proposedWidth = Double(startFrame.width - delta.width)
            proposedHeight = Double(startFrame.height + delta.height)
        case .bottomRight:
            proposedWidth = Double(startFrame.width + delta.width)
            proposedHeight = Double(startFrame.height - delta.height)
        case .bottomLeft:
            proposedWidth = Double(startFrame.width - delta.width)
            proposedHeight = Double(startFrame.height - delta.height)
        }

        let resized = proportionalResize(
            currentSize: startFrame.size,
            proposedSize: CGSize(width: proposedWidth, height: proposedHeight),
            currentScale: safeScale,
            baseWidth: baseWidth
        )
        let newW = resized.size.width
        let newH = CGFloat(baseHeight * resized.scale)

        let originX: CGFloat
        switch edge {
        case .left, .topLeft, .bottomLeft:
            originX = startFrame.maxX - newW
        default:
            originX = startFrame.minX
        }

        let originY: CGFloat
        switch edge {
        case .top, .topLeft, .topRight:
            originY = startFrame.minY
        default:
            originY = startFrame.maxY - newH
        }

        return (
            scale: resized.scale,
            frame: CGRect(x: originX, y: originY, width: newW, height: newH)
        )
    }

    public static func clampOrigin(
        savedOrigin: CGPoint,
        windowSize: CGSize,
        visibleFrames: [CGRect],
        primaryVisibleFrame: CGRect,
        margin: CGFloat = 16
    ) -> CGPoint {
        let candidate = CGRect(origin: savedOrigin, size: windowSize)
        // If at least 60% of the window intersects any active screen, keep the user's position
        for frame in visibleFrames {
            let overlap = frame.intersection(candidate)
            if !overlap.isNull {
                let area = overlap.width * overlap.height
                let totalArea = max(1, windowSize.width * windowSize.height)
                if area / totalArea >= 0.60 {
                    return savedOrigin
                }
            }
        }

        // Otherwise clamp cleanly into the primary visible frame
        let minX = primaryVisibleFrame.minX + margin
        let maxX = max(minX, primaryVisibleFrame.maxX - windowSize.width - margin)
        let minY = primaryVisibleFrame.minY + margin
        let maxY = max(minY, primaryVisibleFrame.maxY - windowSize.height - margin)

        let clampedX = min(max(savedOrigin.x, minX), maxX)
        let clampedY = min(max(savedOrigin.y, minY), maxY)
        return CGPoint(x: clampedX, y: clampedY)
    }

    public static func defaultOrigin(windowSize: CGSize, primaryVisibleFrame: CGRect, margin: CGFloat = 24) -> CGPoint {
        let x = max(primaryVisibleFrame.minX + margin, primaryVisibleFrame.maxX - windowSize.width - margin)
        let y = max(primaryVisibleFrame.minY + margin, primaryVisibleFrame.maxY - windowSize.height - margin)
        return CGPoint(x: x, y: y)
    }

    public static func clampFrameAfterResize(
        oldFrame: CGRect,
        newSize: CGSize,
        visibleFrames: [CGRect],
        primaryVisibleFrame: CGRect,
        margin: CGFloat = 12
    ) -> CGRect {
        let topAnchoredOrigin = CGPoint(x: oldFrame.origin.x, y: oldFrame.maxY - newSize.height)
        // Find screen containing the old frame center, falling back to primary
        let center = CGPoint(x: oldFrame.midX, y: oldFrame.midY)
        let targetScreen = visibleFrames.first(where: { $0.contains(center) }) ?? primaryVisibleFrame

        let minX = targetScreen.minX + margin
        let maxX = max(minX, targetScreen.maxX - newSize.width - margin)
        let minY = targetScreen.minY + margin
        let maxY = max(minY, targetScreen.maxY - newSize.height - margin)

        let clampedX = min(max(topAnchoredOrigin.x, minX), maxX)
        let clampedY = min(max(topAnchoredOrigin.y, minY), maxY)
        return CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: newSize)
    }
}
