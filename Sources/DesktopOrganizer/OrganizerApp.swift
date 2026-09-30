import AppKit
import SwiftUI
import Quartz
import UserNotifications
import OrganizerCore
import OrganizerStore
import ProbeCore

final class OrganizerPanel: NSPanel {
    var category: BoardCategory?
    var onInteraction: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            onInteraction?()
        }
        super.sendEvent(event)
    }
}
final class InteractiveHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PreviewController: NSResponder, @preconcurrency QLPreviewPanelDataSource {
    var urls: [URL] = []
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { !urls.isEmpty }
    }
    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self; panel.reloadData() }
    }
    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
    func show(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.updateController()
        panel.makeKeyAndOrderFront(nil)
        if panel.currentController as? PreviewController === self { panel.reloadData() }
    }
}

@MainActor
final class OrganizerDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    var model: AppModel!
    var control: NSWindow!
    var boards: [BoardCategory: OrganizerPanel] = [:]
    var statusItem: NSStatusItem!
    let previews = PreviewController()
    var keyMonitor: Any?
    var arranging = false
    var layoutSaveTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            let args = ProcessInfo.processInfo.arguments
            var demoRoot: URL?
            if let i = args.firstIndex(of: "--demo-root"), args.indices.contains(i + 1) {
                demoRoot = URL(fileURLWithPath: args[i + 1])
                guard let demoRoot,
                      (try? String(contentsOf: demoRoot.appendingPathComponent(".desktop-organizer-demo"), encoding: .utf8))
                        == "DesktopOrganizer disposable fixtures v1" else {
                    throw OrganizerError.unsafe("示例模式仅接受专用脚本生成的隔离目录，未访问桌面文件")
                }
            }
            let dataRoot = demoRoot?.appendingPathComponent("AppData") ??
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DesktopOrganizer")
            let database = try OrganizerDatabase(url: dataRoot.appendingPathComponent("Organizer.store"))
            model = AppModel(database: database, demoRoot: demoRoot)
            control = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 670),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            control.title = demoRoot == nil ? "桌面归纳器" : "桌面归纳器 · 示例目录"
            control.minSize = NSSize(width: 680, height: 560)
            control.isReleasedWhenClosed = false
            control.contentView = NSHostingView(rootView: ControlCenter(model: model))
            previews.nextResponder = NSApp
            control.nextResponder = previews
            control.center()
            model.showControl = { [weak self] in self?.showControl() }
            model.boardsChanged = { [weak self] in self?.synchronizeBoards() }
            model.preview = { [weak self] urls in self?.previews.show(urls) }
            model.toggleBoardCollapse = { [weak self] category in self?.toggleBoardCollapse(category) }
            setupMenu()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, let board = event.window as? OrganizerPanel, event.keyCode == 49,
                          !(board.firstResponder is NSTextView) else { return false }
                    let candidates = self.model.chosenItems
                    self.previews.show(candidates.map(\.url))
                    return !candidates.isEmpty
                }
                return consumed ? nil : event
            }
            let center = NSWorkspace.shared.notificationCenter
            center.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
            center.addObserver(self, selector: #selector(wake), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
            UNUserNotificationCenter.current().delegate = self
            Task {
                await model.start()
                if args.contains("--normalize-boards") { normalizeBoardSizes() }
                if args.contains("--self-test"), demoRoot != nil { await model.runDemoChecks() }
                if model.desktop == nil || demoRoot != nil || !model.guideConfirmed { showControl() }
                if args.contains("--preview-check"), let demoRoot,
                   let image = model.items.first(where: { $0.category == .images }) {
                    previews.show([image.url])
                    try? await Task.sleep(for: .milliseconds(800))
                    if let panel = QLPreviewPanel.shared() {
                        let previewResult: [String: Any] = [
                            "controllerOwned": panel.currentController as? PreviewController === previews,
                            "visible": panel.isVisible,
                            "window": panel.windowNumber
                        ]
                        if let data = try? JSONSerialization.data(withJSONObject: previewResult, options: .prettyPrinted) {
                            try? data.write(to: demoRoot.appendingPathComponent("AppData/preview-check.json"), options: .atomic)
                        }
                    }
                }
                if args.contains("--collapse-check"), let demoRoot,
                   let category = boards.keys.sorted(by: { $0.rawValue < $1.rawValue }).first,
                   let board = boards[category] {
                    let expanded = board.frame
                    toggleBoardCollapse(category)
                    try? await Task.sleep(for: .milliseconds(300))
                    let collapsed = board.frame
                    toggleBoardCollapse(category)
                    try? await Task.sleep(for: .milliseconds(300))
                    let result: [String: Any] = [
                        "category": category.rawValue,
                        "expandedHeight": expanded.height,
                        "collapsedHeight": collapsed.height,
                        "topPreserved": abs(collapsed.maxY - expanded.maxY) < 0.5,
                        "restoredHeight": board.frame.height,
                        "restoredWidth": board.frame.width,
                        "restored": abs(board.frame.height - expanded.height) < 0.5
                            && abs(board.frame.width - expanded.width) < 0.5,
                        "collapsed": model.isBoardCollapsed(category)
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted) {
                        try? data.write(to: demoRoot.appendingPathComponent("AppData/collapse-check.json"), options: .atomic)
                    }
                }
                if let demoRoot {
                    let windows = ["control": control.windowNumber].merging(
                        Dictionary(uniqueKeysWithValues: boards.map { ($0.key.rawValue, $0.value.windowNumber) }),
                        uniquingKeysWith: { first, _ in first })
                    if let data = try? JSONSerialization.data(withJSONObject: windows, options: .prettyPrinted) {
                        try? data.write(to: demoRoot.appendingPathComponent("AppData/windows.json"), options: .atomic)
                    }
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法打开本地数据"
            alert.informativeText = "\(error.localizedDescription)\n未改动桌面文件。"
            alert.runModal(); NSApp.terminate(nil)
        }
    }

    func setupMenu() {
        let menu = NSMenu()
        add(menu, "控制中心", #selector(showControl), key: "o")
        add(menu, "显示看板", #selector(showBoards))
        add(menu, "投递选中项", #selector(archiveSelection))
        add(menu, "设置", #selector(settings), key: ",")
        menu.addItem(.separator())
        add(menu, "统一看板大小", #selector(normalizeBoardSizes))
        add(menu, "恢复默认看板布局", #selector(resetLayout))
        menu.addItem(.separator())
        add(menu, "退出桌面归纳器", #selector(quit), key: "q")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "桌面归纳器")
        statusItem.menu = menu
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = menu.copy() as? NSMenu
        main.addItem(appItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [
            ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")
        ] { edit.addItem(withTitle: title, action: selector, keyEquivalent: key) }
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
    }
    func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        menu.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
    }
    @objc func showControl() { NSApp.activate(ignoringOtherApps: true); control.makeKeyAndOrderFront(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if control != nil { showControl() }
        return false
    }
    @objc func settings() { model.tab = "settings"; showControl() }
    @objc func archiveSelection() { model.beginArchive() }
    @objc func showBoards() {
        for (category, board) in boards where model.items.contains(where: { $0.board == category }) {
            board.orderFrontRegardless()
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func wake() {
        Task { await model.refresh(); await model.checkReminder(); showBoards() }
    }
    @objc func screensChanged() {
        arranging = true
        if let screen = NSScreen.screens.first?.visibleFrame {
            for board in boards.values { board.setFrame(clamp(board.frame, to: screen), display: true) }
            control.setFrame(clamp(control.frame, to: screen), display: true)
        }
        arranging = false
        persistLayouts()
    }
    @objc func resetLayout() {
        do {
            for layout in try model.database.layouts() { model.database.context.delete(layout) }
            try model.database.save()
            model.collapsedBoards = []
            arranging = true
            let categories = BoardCategory.allCases.filter { category in model.items.contains { $0.board == category } }
            for (i, category) in categories.enumerated() {
                if let board = boards[category] {
                    board.minSize = NSSize(width: 260, height: 215)
                    setBoardFrame(board, defaultFrame(index: i, count: categories.count))
                }
            }
            arranging = false; persistLayouts()
        } catch { model.message = error.localizedDescription }
    }
    @objc func normalizeBoardSizes() {
        let active = BoardCategory.allCases.filter { category in model.items.contains { $0.board == category } }
        guard !active.isEmpty, let screen = NSScreen.screens.first?.visibleFrame else { return }
        do {
            let layouts = try model.database.layouts()
            let standard = defaultFrame(index: 0, count: active.count).size
            var occupied: [NSRect] = []
            arranging = true
            defer { arranging = false }
            for (index, category) in active.enumerated() {
                guard let board = boards[category] else { continue }
                let preferred = NSRect(x: board.frame.minX, y: board.frame.maxY - standard.height,
                                       width: standard.width, height: standard.height)
                let expanded = BoardPlacement.availableFrame(preferred: preferred, screen: screen, occupied: occupied)
                    ?? defaultFrame(index: index, count: active.count)
                let layout = layouts.first(where: { $0.category == category.rawValue }) ??
                    BoardLayout(category: category.rawValue, x: expanded.minX, y: expanded.minY,
                                width: expanded.width, height: expanded.height)
                if !layouts.contains(where: { $0 === layout }) { model.database.context.insert(layout) }
                layout.x = expanded.minX; layout.y = expanded.minY
                layout.width = expanded.width; layout.height = expanded.height
                layout.collapsed = model.isBoardCollapsed(category)
                if model.isBoardCollapsed(category) {
                    board.minSize = NSSize(width: 260, height: BoardGeometry.collapsedHeight)
                    setBoardFrame(board, BoardGeometry.collapsed(expanded))
                } else {
                    board.minSize = NSSize(width: 260, height: 215)
                    setBoardFrame(board, expanded)
                }
                occupied.append(expanded)
            }
            try model.database.save()
        } catch {
            model.message = "统一看板大小失败：\(error.localizedDescription)"
        }
    }
    func synchronizeBoards() {
        let active = BoardCategory.allCases.filter { category in model.items.contains { $0.board == category } }
        let layouts = (try? model.database.layouts()) ?? []
        var needsCompactLayout = false
        arranging = true
        defer { arranging = false }
        for category in BoardCategory.allCases {
            guard active.contains(category) else { boards[category]?.orderOut(nil); continue }
            if let existing = boards[category] {
                existing.title = model.boardTitle(category)
                if !existing.isVisible, let screen = NSScreen.screens.first?.visibleFrame {
                    let occupied = boards.filter { $0.key != category && active.contains($0.key) }.map { $0.value.frame }
                    if let frame = BoardPlacement.availableFrame(preferred: existing.frame, screen: screen, occupied: occupied) {
                        existing.setFrame(frame, display: true)
                    } else {
                        needsCompactLayout = true
                    }
                }
                existing.orderFrontRegardless()
                continue
            }
            let board = OrganizerPanel(contentRect: defaultFrame(index: active.firstIndex(of: category) ?? 0, count: active.count),
                styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            board.category = category; board.title = model.boardTitle(category)
            board.onInteraction = { [weak self, weak board] in
                guard let self, let board else { return }
                self.promoteBoard(board)
            }
            board.titleVisibility = .hidden; board.titlebarAppearsTransparent = true
            board.isReleasedWhenClosed = false; board.hidesOnDeactivate = false; board.isFloatingPanel = false
            board.isOpaque = false; board.backgroundColor = .clear; board.hasShadow = true
            board.minSize = NSSize(width: 260, height: 215)
            board.level = NSWindow.Level(rawValue: Int(DesktopWindowPolicy.interactiveLevel))
            board.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            board.contentView = InteractiveHostingView(rootView: CategoryBoard(model: model, category: category))
            board.nextResponder = previews
            board.delegate = self
            if let saved = layouts.first(where: { $0.category == category.rawValue }),
               let screen = NSScreen.screens.first?.visibleFrame {
                board.setFrame(clamp(NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height), to: screen), display: false)
            }
            if model.isBoardCollapsed(category) {
                board.minSize = NSSize(width: 260, height: BoardGeometry.collapsedHeight)
                board.setFrame(BoardGeometry.collapsed(board.frame), display: false)
            }
            if let screen = NSScreen.screens.first?.visibleFrame {
                let occupied = boards.filter { active.contains($0.key) }.map { $0.value.frame }
                if let frame = BoardPlacement.availableFrame(preferred: board.frame, screen: screen, occupied: occupied) {
                    board.setFrame(frame, display: false)
                } else {
                    needsCompactLayout = true
                }
            }
            boards[category] = board; board.orderFrontRegardless()
            if !model.isBoardCollapsed(category) {
                setBoardFrame(board, board.frame)
            }
        }
        if needsCompactLayout {
            for (index, category) in active.enumerated() {
                boards[category]?.setFrame(defaultFrame(index: index, count: active.count), display: true)
            }
        }
        statusItem.button?.toolTip = "桌面 \(model.items.count) 项 · \(model.dueCount) 项可归档"
    }
    /// Bring the interacted board above ordinary app windows without making it permanently always-on-top.
    func promoteBoard(_ board: OrganizerPanel) {
        board.level = .normal
        board.orderFrontRegardless()
        board.makeKey()
    }
    func toggleBoardCollapse(_ category: BoardCategory) {
        guard let board = boards[category] else { return }
        do {
            let layouts = try model.database.layouts()
            let layout = layouts.first(where: { $0.category == category.rawValue }) ??
                BoardLayout(category: category.rawValue, x: board.frame.minX, y: board.frame.minY,
                            width: board.frame.width, height: board.frame.height)
            if !layouts.contains(where: { $0 === layout }) { model.database.context.insert(layout) }
            arranging = true
            defer { arranging = false }
            if model.isBoardCollapsed(category) {
                board.minSize = NSSize(width: 260, height: 215)
                let target = BoardGeometry.expanded(board.frame, height: CGFloat(layout.height))
                if let screen = NSScreen.screens.first?.visibleFrame {
                    setBoardFrame(board, clamp(target, to: screen))
                } else {
                    setBoardFrame(board, target)
                }
                layout.collapsed = false
                model.collapsedBoards.remove(category)
            } else {
                let expanded = board.frame
                layout.x = expanded.minX; layout.y = expanded.minY
                layout.width = expanded.width; layout.height = expanded.height
                layout.collapsed = true
                board.minSize = NSSize(width: 260, height: BoardGeometry.collapsedHeight)
                setBoardFrame(board, BoardGeometry.collapsed(expanded))
                model.collapsedBoards.insert(category)
            }
            try model.database.save()
        } catch {
            model.message = "看板状态保存失败：\(error.localizedDescription)"
        }
    }
    func setBoardFrame(_ board: OrganizerPanel, _ frame: NSRect) {
        board.setFrame(frame, display: true)
        // The SwiftUI view changes shape during folding, so reapply the native frame on the next loop.
        DispatchQueue.main.async { [weak self, weak board] in
            guard let self, let board else { return }
            self.arranging = true
            board.setFrame(frame, display: true)
            self.arranging = false
        }
    }
    func defaultFrame(index: Int, count: Int) -> NSRect {
        let screen = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let columns = min(4, max(1, Int(ceil(sqrt(Double(max(1, count)) * screen.width / screen.height)))))
        let rows = max(1, Int(ceil(Double(count) / Double(columns))))
        let width = min(370, (screen.width - 32 - Double(columns - 1) * 14) / Double(columns))
        let height = min(350, (screen.height - 32 - Double(rows - 1) * 14) / Double(rows))
        return clamp(NSRect(x: screen.minX + 16 + Double(index % columns) * (width + 14),
            y: screen.maxY - 16 - Double(index / columns + 1) * height - Double(index / columns) * 14,
            width: width, height: height), to: screen)
    }
    func clamp(_ frame: NSRect, to screen: NSRect) -> NSRect {
        let w = min(frame.width, screen.width - 16), h = min(frame.height, screen.height - 16)
        return NSRect(x: min(max(frame.minX, screen.minX + 8), screen.maxX - w - 8),
            y: min(max(frame.minY, screen.minY + 8), screen.maxY - h - 8), width: w, height: h)
    }
    func windowDidMove(_ notification: Notification) {
        guard !arranging else { return }
        layoutSaveTask?.cancel()
        layoutSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.persistLayouts()
        }
    }
    func windowDidEndLiveResize(_ notification: Notification) { if !arranging { persistLayouts() } }
    func persistLayouts() {
        guard model != nil else { return }
        do {
            let layouts = try model.database.layouts()
            for (category, board) in boards {
                let frame = board.frame
                let collapsed = model.isBoardCollapsed(category)
                let savedFrame: NSRect
                if collapsed, let layout = layouts.first(where: { $0.category == category.rawValue }) {
                    savedFrame = BoardGeometry.expanded(frame, height: CGFloat(layout.height))
                } else {
                    savedFrame = frame
                }
                if let layout = layouts.first(where: { $0.category == category.rawValue }) {
                    layout.x = savedFrame.minX; layout.y = savedFrame.minY
                    layout.width = savedFrame.width; layout.height = savedFrame.height
                    layout.collapsed = collapsed
                } else {
                    model.database.context.insert(BoardLayout(category: category.rawValue,
                        x: savedFrame.minX, y: savedFrame.minY, width: savedFrame.width, height: savedFrame.height))
                }
            }
            try model.database.save()
        } catch { model.message = "布局保存失败：\(error.localizedDescription)" }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.busy != nil {
            let alert = NSAlert(); alert.messageText = "文件操作尚未结束"; alert.informativeText = "请等待当前操作完成后退出。"
            alert.runModal(); return .terminateCancel
        }
        let alert = NSAlert()
        alert.messageText = "退出桌面归纳器？"
        alert.informativeText = "如已隐藏系统桌面图标，可在“系统设置 → 桌面与程序坞 → 显示项目”重新开启“在桌面上”。文件仍在真实目录中。"
        alert.addButton(withTitle: "退出"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        layoutSaveTask?.cancel()
        persistLayouts(); model?.stop(); return .terminateNow
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        await MainActor.run { self.model.onlyDue = true; self.model.tab = "files"; self.showControl() }
    }
}

@main
struct OrganizerApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = OrganizerDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
