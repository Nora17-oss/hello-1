import AppKit
import SwiftUI
import ProbeCore
import UniformTypeIdentifiers

@MainActor
final class ProbeState: NSObject, ObservableObject, NSOpenSavePanelDelegate {
    @Published var report = GateReport(systemVersion: ProcessInfo.processInfo.operatingSystemVersionString)
    @Published var files: [URL] = []
    @Published var error: String?
    @Published var clicks = 0
    let reportURL: URL
    weak var filePickerParent: NSWindow?
    private var filePanel: NSOpenPanel?
    private var selectionLabel: NSTextField?

    override init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--report"), arguments.indices.contains(index + 1) {
            reportURL = URL(fileURLWithPath: arguments[index + 1])
        } else {
            reportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DesktopOrganizerProbe/session-report.json")
        }
        super.init()
    }

    func save() {
        do { try report.save(to: reportURL) }
        catch { self.error = "验收记录保存失败：\(error.localizedDescription)" }
    }

    func event(_ text: String) {
        report.record(text)
        save()
    }

    func setVerdict(_ verdict: Verdict, for scenario: Scenario) {
        report.scenarios[scenario.rawValue] = verdict
        event("manual: \(scenario.rawValue) = \(verdict.rawValue)")
    }

    func chooseFile() {
        NSApp.activate(ignoringOtherApps: true)
        if let filePanel {
            filePanel.makeKeyAndOrderFront(nil)
            return
        }
        guard let parent = filePickerParent else {
            error = "文件选择窗口尚未就绪，请重新打开验收窗口。"
            return
        }
        error = nil
        parent.makeKeyAndOrderFront(nil)
        let panel = TestFilePanel.make()
        let label = NSTextField(wrappingLabelWithString: "未选中文件")
        label.frame = NSRect(x: 0, y: 0, width: 440, height: 36)
        label.textColor = .secondaryLabelColor
        panel.accessoryView = label
        panel.isAccessoryViewDisclosed = true
        panel.delegate = self
        selectionLabel = label
        filePanel = panel
        event("file picker presented as sheet; files enabled; no type filter")
        // A desktop nonactivating panel must not own the modal file chooser.
        panel.beginSheetModal(for: parent) { [weak self, weak panel] response in
            guard let self, let panel else { return }
            defer {
                panel.delegate = nil
                self.filePanel = nil
                self.selectionLabel = nil
            }
            if response == .OK, !panel.urls.isEmpty {
                self.files = panel.urls
                // Never persist selected filenames or file contents in the diagnostic report.
                self.event("selected \(self.files.count) read-only test items")
            } else {
                self.event("file picker cancelled or empty")
            }
        }
    }

    func panelSelectionDidChange(_ sender: Any?) {
        guard let panel = filePanel else { return }
        let urls = panel.urls
        var directoryCount = 0
        var remoteCount = 0
        for url in urls {
            let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .isPackageKey,
                .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
            ])
            if values?.isDirectory == true, values?.isPackage != true {
                directoryCount += 1
            }
            if values?.isUbiquitousItem == true,
               values?.ubiquitousItemDownloadingStatus == .notDownloaded {
                remoteCount += 1
            }
        }
        if urls.isEmpty {
            selectionLabel?.stringValue = "未选中文件"
        } else if directoryCount > 0 {
            selectionLabel?.stringValue = "当前选中的是文件夹，不能作为测试文件加入"
        } else if remoteCount > 0 {
            selectionLabel?.stringValue = "所选文件尚未下载到本机"
        } else {
            selectionLabel?.stringValue = "已选中 \(urls.count) 个文件"
        }
        event("file picker selection: items=\(urls.count), directories=\(directoryCount), notDownloaded=\(remoteCount)")
    }

    func open(_ url: URL) {
        let result = NSWorkspace.shared.open(url)
        if !result { error = "系统未能打开所选文件。" }
        event("file open request accepted: \(result)")
    }
}

final class DesktopPanel: NSPanel {
    var onMouseDown: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { onMouseDown?() }
        super.sendEvent(event)
    }
}

final class DesktopHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct BoardView: View {
    @ObservedObject var state: ProbeState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2.fill").foregroundStyle(.teal)
                Text("桌面看板").font(.headline)
                Spacer()
                Text("验证版").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if state.files.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("暂无测试文件").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(state.files, id: \.self) { url in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable().frame(width: 32, height: 32)
                                Text(url.lastPathComponent)
                                    .lineLimit(2).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { state.open(url) }
                            .contextMenu {
                                Button("打开") { state.open(url) }
                                Button("在 Finder 中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            if let error = state.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button {
                    state.clicks += 1
                    state.event("desktop click \(state.clicks)")
                } label: {
                    Label("点击测试 \(state.clicks)", systemImage: "cursorarrow.click")
                }
                Spacer()
                Button { state.chooseFile() } label: {
                    Image(systemName: "plus")
                }.help("加入测试文件")
            }
        }
        .padding(18)
        .frame(minWidth: 280, minHeight: 250)
        .background(.regularMaterial)
        .environment(\.colorScheme, .light)
    }
}

struct InspectorView: View {
    @ObservedObject var state: ProbeState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("桌面兼容性验收").font(.title2.bold())
                Spacer()
                Text(state.report.gatePassed ? "全部通过" : "等待验收")
                    .foregroundStyle(state.report.gatePassed ? .green : .secondary)
            }
            HStack {
                Label("自动配置检查", systemImage: "checkmark.shield")
                Spacer()
                Text("\(state.report.automaticChecks.values.filter { $0 }.count) / \(state.report.automaticChecks.count)")
                    .monospacedDigit()
            }
            Divider()
            ForEach(Scenario.allCases, id: \.rawValue) { scenario in
                HStack {
                    Text(scenario.title).frame(maxWidth: .infinity, alignment: .leading)
                    Picker(scenario.title, selection: Binding(
                        get: { state.report.scenarios[scenario.rawValue] ?? .pending },
                        set: { state.setVerdict($0, for: scenario) }
                    )) {
                        ForEach(Verdict.allCases, id: \.rawValue) {
                            Text($0.title).tag($0)
                        }
                    }
                    .labelsHidden().frame(width: 105)
                }
            }
            Divider()
            TextField("异常备注", text: $state.report.notes, axis: .vertical)
                .lineLimit(2...4)
                .onChange(of: state.report.notes) { state.save() }
            if let error = state.error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Button("选择测试文件", systemImage: "doc.badge.plus") { state.chooseFile() }
                Spacer()
                Button("查看记录", systemImage: "doc.text.magnifyingglass") {
                    state.save()
                    NSWorkspace.shared.activateFileViewerSelecting([state.reportURL])
                }
            }
        }
        .padding(24)
        .frame(width: 570)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let state = ProbeState()
    var board: DesktopPanel!
    var inspector: NSWindow!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        board = DesktopPanel(
            contentRect: NSRect(x: 60, y: 160, width: 340, height: 380),
            styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        board.title = "桌面看板 · 验证版"
        board.titlebarAppearsTransparent = true
        board.isReleasedWhenClosed = false
        board.hidesOnDeactivate = false
        board.isFloatingPanel = false
        board.isOpaque = false
        board.backgroundColor = .clear
        board.hasShadow = true
        board.minSize = NSSize(width: 300, height: 290)
        board.level = NSWindow.Level(rawValue: Int(DesktopWindowPolicy.interactiveLevel))
        board.ignoresMouseEvents = false
        board.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        board.contentView = DesktopHostingView(rootView: BoardView(state: state))
        board.onMouseDown = { [weak self] in self?.state.event("desktop received mouse-down") }
        board.delegate = self
        placeBoard()
        board.orderFrontRegardless()

        inspector = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 490),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        inspector.title = "桌面整理器 · 技术验证"
        inspector.isReleasedWhenClosed = false
        inspector.contentView = NSHostingView(rootView: InspectorView(state: state))
        inspector.center()
        state.filePickerParent = inspector

        let menu = NSMenu()
        menu.addItem(withTitle: "显示验收窗口", action: #selector(showInspector), keyEquivalent: "i").target = self
        menu.addItem(withTitle: "重新显示桌面看板", action: #selector(showBoard), keyEquivalent: "").target = self
        menu.addItem(withTitle: "桌面显示设置", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出验证版", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "桌面整理器验证版")
        statusItem.menu = menu
        NSApp.mainMenu = menu

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        checkConfiguration()
        state.event("launched build 3; interactive window level \(board.level.rawValue)")
        showInspector()
        state.event("window ids: board=\(board.windowNumber), inspector=\(inspector.windowNumber)")
    }

    func checkConfiguration() {
        state.report.automaticChecks = [
            "aboveWallpaper": board.level.rawValue > Int(CGWindowLevelForKey(.desktopWindow)),
            "aboveDesktopInteractionLayer": board.level.rawValue > Int(CGWindowLevelForKey(.desktopIconWindow)),
            "belowNormalWindows": board.level.rawValue < NSWindow.Level.normal.rawValue,
            "stationary": board.collectionBehavior.contains(.stationary),
            "allSpaces": board.collectionBehavior.contains(.canJoinAllSpaces),
            "configuredToAcceptClicks": !board.ignoresMouseEvents && board.canBecomeKey,
            "acceptsFirstClick": board.contentView?.acceptsFirstMouse(for: nil) ?? false,
            "doesNotHideOnDeactivate": !board.hidesOnDeactivate,
            "onPrimaryDisplay": NSScreen.screens.first?.visibleFrame.contains(board.frame) ?? false
        ]
        state.save()
    }

    func placeBoard() {
        guard let frame = NSScreen.screens.first?.visibleFrame else { return }
        let width = min(board.frame.width, frame.width - 32)
        let height = min(board.frame.height, frame.height - 32)
        board.setFrame(NSRect(
            x: frame.minX + 24, y: frame.maxY - height - 24,
            width: width, height: height), display: true)
    }

    @objc func showInspector() {
        NSApp.activate(ignoringOtherApps: true)
        inspector.makeKeyAndOrderFront(nil)
    }
    @objc func showBoard() {
        board.orderFrontRegardless()
        checkConfiguration()
    }
    @objc func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
    }
    @objc func didWake() {
        showBoard()
        state.event("system woke; visual verification still required")
    }
    @objc func spaceChanged() {
        state.event("active space changed; visual verification still required")
    }
    @objc func screenChanged() {
        placeBoard()
        checkConfiguration()
        state.event("screen configuration changed")
    }
    func windowDidEndLiveResize(_ notification: Notification) { checkConfiguration() }
    func windowDidMove(_ notification: Notification) { if inspector != nil { checkConfiguration() } }
    @objc func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.messageText = "退出桌面验证版？"
        alert.informativeText = "如果你已手动关闭桌面项目显示，可在“系统设置 → 桌面与程序坞 → 显示项目”中重新开启“在桌面上”。本工具未修改该设置。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        state.event("normal exit")
        return .terminateNow
    }
}

@main
struct ProbeApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
