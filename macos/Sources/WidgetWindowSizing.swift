import Foundation
import CoreGraphics

/// Shared by native edge resizing and the visible bottom handle.
enum WidgetWindowSizing {
    static let width: CGFloat = 390
    static let minimumHeight: CGFloat = 240

    static func maximumHeight(visibleHeight: CGFloat) -> CGFloat {
        max(180, visibleHeight - 16)
    }

    static func height(_ proposed: CGFloat, visibleHeight: CGFloat) -> CGFloat {
        let maximum = maximumHeight(visibleHeight: visibleHeight)
        let minimum = min(minimumHeight, maximum)
        return min(maximum, max(minimum, proposed.isFinite ? proposed : 728))
    }

    static func frame(height proposed: CGFloat, top: CGFloat, x: CGFloat, visible: CGRect) -> CGRect {
        let height = height(proposed, visibleHeight: visible.height)
        return CGRect(x: max(visible.minX, min(x, visible.maxX - width)),
                      y: max(visible.minY, min(top - height, visible.maxY - height)),
                      width: width, height: height)
    }
}
