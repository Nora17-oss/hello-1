import CoreGraphics

public enum DesktopWindowPolicy {
    // Finder and desktop widgets can intercept input below their own window layers.
    // Keep the interactive board immediately below ordinary application windows.
    public static var interactiveLevel: Int32 {
        CGWindowLevelForKey(.normalWindow) - 1
    }
}
