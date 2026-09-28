import CoreGraphics
import Testing
@testable import ProbeCore

@Test func interactiveBoardIsAboveFinderDesktopLayer() {
    #expect(DesktopWindowPolicy.interactiveLevel > CGWindowLevelForKey(.desktopIconWindow))
    #expect(DesktopWindowPolicy.interactiveLevel > CGWindowLevelForKey(.desktopWindow))
}

@Test func interactiveBoardRemainsBelowOrdinaryApplications() {
    #expect(DesktopWindowPolicy.interactiveLevel < CGWindowLevelForKey(.normalWindow))
}

@Test func originalWallpaperLevelFailsInteractionPolicy() {
    let originalLevel = CGWindowLevelForKey(.desktopWindow) + 1
    #expect(originalLevel < CGWindowLevelForKey(.desktopIconWindow))
    #expect(DesktopWindowPolicy.interactiveLevel != originalLevel)
}
