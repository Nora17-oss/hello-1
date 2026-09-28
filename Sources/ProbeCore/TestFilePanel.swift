import AppKit

@MainActor
public enum TestFilePanel {
    public static func make() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "选择测试文件"
        panel.prompt = "加入看板"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.treatsFilePackagesAsDirectories = false
        panel.canCreateDirectories = false
        return panel
    }
}
