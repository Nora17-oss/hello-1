import Foundation
import CoreGraphics

public enum BoardPlacement {
    public static func availableFrame(preferred: CGRect, screen: CGRect, occupied: [CGRect]) -> CGRect? {
        let bounds = screen.insetBy(dx: 8, dy: 8)
        let size = CGSize(width: min(preferred.width, bounds.width),
                          height: min(preferred.height, bounds.height))
        guard size.width > 0, size.height > 0 else { return nil }
        func fits(_ frame: CGRect) -> Bool {
            bounds.contains(frame) && !occupied.contains { $0.intersects(frame) }
        }
        let initial = CGRect(x: min(max(preferred.minX, bounds.minX), bounds.maxX - size.width),
                             y: min(max(preferred.minY, bounds.minY), bounds.maxY - size.height),
                             width: size.width, height: size.height)
        if fits(initial) { return initial }
        // Try screen and window edges before requiring a compact grid layout.
        let xs = [bounds.minX, bounds.maxX - size.width] +
            occupied.flatMap { [$0.maxX + 14, $0.minX - size.width - 14] }
        let ys = [bounds.maxY - size.height, bounds.minY] +
            occupied.flatMap { [$0.minY - size.height - 14, $0.maxY + 14] }
        for y in ys.sorted(by: >) {
            for x in xs.sorted() {
                let candidate = CGRect(origin: CGPoint(x: x, y: y), size: size)
                if fits(candidate) { return candidate }
            }
        }
        return nil
    }
}
