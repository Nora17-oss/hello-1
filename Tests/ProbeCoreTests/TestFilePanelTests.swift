import AppKit
import Testing
@testable import ProbeCore

@Suite(.serialized)
@MainActor
struct TestFilePanelTests {
    @Test func explicitlyAllowsFilesWithoutTypeRestrictions() {
        _ = NSApplication.shared
        let panel = TestFilePanel.make()
        #expect(panel.canChooseFiles)
        #expect(panel.allowedContentTypes.isEmpty)
        #expect(panel.allowsOtherFileTypes)
    }

    @Test func directoriesCannotBeAddedAsTestFiles() {
        _ = NSApplication.shared
        let panel = TestFilePanel.make()
        #expect(!panel.canChooseDirectories)
        #expect(!panel.canCreateDirectories)
        #expect(!panel.treatsFilePackagesAsDirectories)
        #expect(panel.allowsMultipleSelection)
    }
}
