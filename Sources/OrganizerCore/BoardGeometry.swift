import CoreGraphics

public enum BoardGeometry {
    public static let collapsedHeight: CGFloat = 52

    public static func collapsed(_ expanded: CGRect) -> CGRect {
        let height = min(collapsedHeight, expanded.height)
        return CGRect(x: expanded.minX, y: expanded.maxY - height,
                      width: expanded.width, height: height)
    }

    public static func expanded(_ collapsed: CGRect, height: CGFloat) -> CGRect {
        let expandedHeight = max(height, collapsed.height)
        return CGRect(x: collapsed.minX, y: collapsed.maxY - expandedHeight,
                      width: collapsed.width, height: expandedHeight)
    }
}
