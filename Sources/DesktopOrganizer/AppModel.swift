import AppKit
import SwiftUI
import SwiftData
import UserNotifications
import OrganizerCore
import OrganizerStore

@MainActor
final class AppModel: ObservableObject {
    let database: OrganizerDatabase
    let archives: ArchiveService
    @Published var items: [DesktopItem] = []
    @Published var selected = Set<String>()
    @Published var desktop: URL?
    @Published var roots: [URL] = []
    @Published var projects: [ProjectFolder] = []
    @Published var history: [MoveRecord] = []
    @Published var search = ""
    @Published var onlyDue = false
    @Published var message: String?
    @Published var busy: String?
    @Published var tab = "settings"
    @Published var days: Int
    @Published var weeklyEnabled: Bool
    @Published var weekday: Int
    @Published var hour: Int
    @Published var minute: Int
    @Published var guideConfirmed: Bool
    @Published var targetProject = ""
    @Published var byCategory = true
    @Published var specifiedFolder: URL?
    @Published var conflict: ConflictPolicy = .skip
    @Published var plans: [MovePlan] = []
    @Published var newFolderName = ""
    @Published var collapsedBoards = Set<BoardCategory>()
    @Published var boardNameDrafts: [BoardCategory: String] = [:]
    @Published var boardTheme: BoardTheme
    @Published var boardOpacity: Double
    @Published var boardIconSize: BoardIconSize
    @Published var boardColors: [BoardCategory: BoardColor]
    let demoRoot: URL?
    var showControl: (() -> Void)?
    var boardsChanged: (() -> Void)?
    var preview: (([URL]) -> Void)?
    var toggleBoardCollapse: ((BoardCategory) -> Void)?
    private var scopes: [URL] = []
    private let watcher = DirectoryWatcher()
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var scanning = false
    private var rescanNeeded = false

    init(database: OrganizerDatabase, demoRoot: URL?) {
        self.database = database; self.demoRoot = demoRoot
        archives = ArchiveService(database: database)
        let p = database.preferences
        days = p.days; weeklyEnabled = p.weeklyEnabled; weekday = p.weekday
        hour = p.hour; minute = p.minute; guideConfirmed = p.iconGuideConfirmed
        boardTheme = BoardTheme(rawValue: p.boardTheme ?? "") ?? .soft
        boardOpacity = min(1, max(0.35, p.boardOpacity ?? 0.72))
        boardIconSize = BoardIconSize(rawValue: p.boardIconSize ?? "") ?? .standard
        boardColors = Dictionary(uniqueKeysWithValues: BoardCategory.allCases.map { ($0, .mint) })
        for (key, value) in p.boardColors ?? [:] {
            if let category = BoardCategory(rawValue: key), let color = BoardColor(rawValue: value) {
                boardColors[category] = color
            }
        }
        boardNameDrafts = Dictionary(uniqueKeysWithValues: BoardCategory.allCases.map { ($0, $0.title) })
        if let names = try? database.boardNames() {
            for name in names {
                if let category = BoardCategory(rawValue: name.category) {
                    boardNameDrafts[category] = name.name
                }
            }
        }
        if let layouts = try? database.layouts() {
            collapsedBoards = Set(layouts.compactMap { layout in
                layout.collapsed == true ? BoardCategory(rawValue: layout.category) : nil
            })
        }
    }

    func start() async {
        do {
            if let demoRoot {
                desktop = demoRoot.appendingPathComponent("Desktop")
                roots = [demoRoot.appendingPathComponent("Projects")]
            } else {
                for grant in try database.grants() {
                    do {
                        var stale = false
                        let url = try URL(resolvingBookmarkData: grant.bookmark, options: [.withSecurityScope],
                                          relativeTo: nil, bookmarkDataIsStale: &stale)
                        if url.startAccessingSecurityScopedResource() { scopes.append(url) }
                        guard FileSafety.exists(url) else { throw OrganizerError.unsafe("目录不可用，请重新授权：\(grant.path)") }
                        if stale {
                            grant.bookmark = try url.bookmarkData(options: .withSecurityScope,
                                                                 includingResourceValuesForKeys: nil, relativeTo: nil)
                            grant.path = url.path; try database.save()
                        }
                        if grant.role == "desktop" { desktop = url } else { roots.append(url) }
                    } catch { message = "目录授权需要重新确认：\(grant.path)\n\(error.localizedDescription)" }
                }
            }
            if let desktop {
                watcher.changed = { [weak self] in self?.scheduleRefresh() }
                watcher.start(desktop)
            }
            refreshProjects()
            try await archives.recover()
            await refresh()
            reloadHistory()
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    await self.refresh()
                    await self.checkReminder()
                }
            }
            await checkReminder()
        } catch { message = error.localizedDescription }
    }

    func stop() {
        timer?.invalidate(); watcher.stop(); refreshTask?.cancel()
        scopes.forEach { $0.stopAccessingSecurityScopedResource() }; scopes.removeAll()
    }
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            await self?.refresh()
        }
    }
    func refresh() async {
        guard let desktop else { items = []; boardsChanged?(); return }
        if scanning { rescanNeeded = true; return }
        scanning = true
        defer {
            scanning = false
            if rescanNeeded { rescanNeeded = false; scheduleRefresh() }
        }
        do {
            let scanned = try await Task.detached {
                try FileManager.default.contentsOfDirectory(at: desktop,
                    includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]).compactMap { url -> (String, URL, FileCategory, Date, String?)? in
                        guard let meta = try? FileSafety.metadata(url) else { return nil }
                        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey])
                        return (FileSafety.identity(meta), url,
                            FileCategory.classify(url, directory: values?.isDirectory ?? false, package: values?.isPackage ?? false),
                            values?.contentModificationDate ?? .distantPast, FileSafety.availability(url))
                    }
            }.value
            let now = Date()
            let observations = try database.observations()
            let indexed = Dictionary(uniqueKeysWithValues: observations.map { ($0.identity, $0) })
            let present = Set(scanned.map(\.0))
            for observation in observations where observation.present && !present.contains(observation.identity) {
                observation.present = false
            }
            var newItems: [DesktopItem] = []
            for (identity, url, category, changed, reason) in scanned {
                let observation: Observation
                if let existing = indexed[identity] {
                    observation = existing
                    if !existing.present { existing.firstSeen = now; existing.lastSeen = now }
                    if existing.path != url.path || now.timeIntervalSince(existing.lastSeen) >= 60 { existing.lastSeen = now }
                    existing.path = url.path; existing.present = true
                } else {
                    observation = Observation(identity: identity, path: url.path, now: now)
                    database.context.insert(observation)
                }
                newItems.append(DesktopItem(id: identity, url: url, category: category,
                    firstSeen: observation.firstSeen, changedAt: changed, unavailableReason: reason,
                    isFixedFolder: observation.isFixedFolder ?? false, sortOrder: observation.sortOrder))
            }
            try database.save()
            items = DesktopItemOrdering.sorted(newItems)
            selected.formIntersection(present)
            boardsChanged?()
        } catch {
            message = "桌面读取失败，保留原文件：\(error.localizedDescription)"
        }
    }
    var chosenItems: [DesktopItem] { items.filter { selected.contains($0.id) } }
    var dueCount: Int { items.filter { $0.isDue(days: days) }.count }
    func visible(_ category: BoardCategory) -> [DesktopItem] {
        DesktopItemOrdering.sorted(items.filter {
            $0.board == category && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
                && (!onlyDue || $0.isDue(days: days))
        })
    }
    private func allItems(in category: BoardCategory) -> [DesktopItem] {
        DesktopItemOrdering.sorted(items.filter { $0.board == category })
    }
    func toggle(_ item: DesktopItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
        invalidatePlan()
    }
    func selectAll(_ category: BoardCategory) {
        selected.formUnion(visible(category).map(\.id)); invalidatePlan()
    }
    func setFixed(_ fixed: Bool, items candidates: [DesktopItem]) async {
        guard busy == nil else { return }
        let identities = Set(candidates.filter { $0.category == .folders }.map(\.id))
        guard !identities.isEmpty else { return }
        busy = "正在保存文件夹分类…"
        do {
            for observation in try database.observations() where identities.contains(observation.identity) {
                observation.isFixedFolder = fixed
                observation.sortOrder = nil
            }
            try database.save()
            plans = []
            await refresh()
        } catch { message = "分类保存失败：\(error.localizedDescription)" }
        busy = nil
    }
    func previewReorder(_ draggedID: String, before targetID: String, in category: BoardCategory) {
        guard search.isEmpty, !onlyDue else { return }
        var ids = allItems(in: category).map(\.id)
        guard let source = ids.firstIndex(of: draggedID), let target = ids.firstIndex(of: targetID),
              source != target else { return }
        ids.remove(at: source)
        let destination = ids.firstIndex(of: targetID) ?? ids.endIndex
        ids.insert(draggedID, at: destination)
        let ranks = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        items = items.map { item in
            var reordered = item
            if let rank = ranks[item.id] { reordered.sortOrder = rank }
            return reordered
        }
        boardsChanged?()
    }
    func saveReorder(in category: BoardCategory) {
        guard search.isEmpty, !onlyDue else { return }
        let ranks = Dictionary(uniqueKeysWithValues: allItems(in: category).enumerated().map { ($0.element.id, $0.offset) })
        do {
            for observation in try database.observations() where ranks[observation.identity] != nil {
                observation.sortOrder = ranks[observation.identity]
            }
            try database.save()
        } catch {
            message = "排序保存失败：\(error.localizedDescription)"
        }
    }
    func open(_ item: DesktopItem) {
        if !NSWorkspace.shared.open(item.url) { message = "无法打开：\(item.name)"; showControl?() }
    }
    func beginArchive() {
        tab = "archive"; invalidatePlan(); refreshProjects(); showControl?()
    }
    func invalidatePlan() { if busy == nil { plans = [] } }
    func isBoardCollapsed(_ category: BoardCategory) -> Bool { collapsedBoards.contains(category) }
    func boardTitle(_ category: BoardCategory) -> String {
        let name = boardNameDrafts[category]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? category.title : name
    }
    func setBoardNameDraft(_ name: String, for category: BoardCategory) {
        boardNameDrafts = boardNameDrafts.merging([category: name]) { _, replacement in replacement }
    }
    func resetBoardName(_ category: BoardCategory) {
        setBoardNameDraft(category.title, for: category)
    }
    func saveBoardNames() {
        guard busy == nil else { return }
        do {
            let existing = try database.boardNames()
            for category in BoardCategory.allCases {
                let candidate = boardTitle(category)
                guard candidate.count <= 24 else {
                    throw OrganizerError.unsafe("看板名称请控制在 24 个字以内")
                }
                if let record = existing.first(where: { $0.category == category.rawValue }) {
                    if candidate == category.title {
                        database.context.delete(record)
                    } else {
                        record.name = candidate
                    }
                } else if candidate != category.title {
                    database.context.insert(BoardName(category: category.rawValue, name: candidate))
                }
                setBoardNameDraft(candidate, for: category)
            }
            try database.save()
            boardsChanged?()
        } catch {
            message = "看板名称保存失败：\(error.localizedDescription)"
        }
    }
    func boardColor(_ category: BoardCategory) -> BoardColor {
        boardColors[category] ?? .mint
    }
    func setBoardColor(_ color: BoardColor, for category: BoardCategory) {
        boardColors[category] = color
    }
    func applyTheme(_ theme: BoardTheme) {
        boardTheme = theme
        switch theme {
        case .soft:
            boardColors = [.fixedFolders: .mint, .folders: .peach, .images: .butter, .files: .sky]
        case .candy:
            boardColors = [.fixedFolders: .lavender, .folders: .peach, .images: .butter, .files: .sky]
        case .focus:
            boardColors = [.fixedFolders: .slate, .folders: .slate, .images: .sky, .files: .slate]
        case .minimal:
            boardColors = Dictionary(uniqueKeysWithValues: BoardCategory.allCases.map { ($0, .mint) })
        }
    }
    func saveAppearance() {
        let p = database.preferences
        p.boardTheme = boardTheme.rawValue
        p.boardOpacity = min(1, max(0.35, boardOpacity))
        p.boardIconSize = boardIconSize.rawValue
        p.boardColors = Dictionary(uniqueKeysWithValues: boardColors.map { ($0.key.rawValue, $0.value.rawValue) })
        do {
            try database.save()
            boardsChanged?()
        } catch {
            message = "外观保存失败：\(error.localizedDescription)"
        }
    }

    func authorize(role: String) {
        guard busy == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = role != "desktop"
        panel.prompt = role == "desktop" ? "授权桌面目录" : "添加项目总目录"
        panel.directoryURL = role == "desktop" ? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first : nil
        guard panel.runModal() == .OK else { return }
        do {
            let existing = try database.grants()
            for url in panel.urls {
                let meta = try FileSafety.metadata(url)
                guard FileSafety.isDirectory(meta), !FileSafety.isLink(meta) else {
                    throw OrganizerError.unsafe("请选择真实文件夹，不支持符号链接")
                }
                if role == "project", roots.contains(url) { continue }
                let bookmark = try url.bookmarkData(options: .withSecurityScope,
                    includingResourceValuesForKeys: nil, relativeTo: nil)
                if role == "desktop" {
                    existing.filter { $0.role == "desktop" }.forEach { database.context.delete($0) }
                }
                database.context.insert(FolderGrant(role: role, path: url.path, bookmark: bookmark))
                try database.save()
                if url.startAccessingSecurityScopedResource() { scopes.append(url) }
                if role == "desktop" {
                    desktop = url; selected = []
                    watcher.changed = { [weak self] in self?.scheduleRefresh() }
                    watcher.start(url)
                } else { roots.append(url) }
            }
            refreshProjects(); scheduleRefresh()
        } catch { message = error.localizedDescription }
    }
    func removeRoot(_ root: URL) {
        guard busy == nil else { return }
        do {
            for grant in try database.grants() where grant.role == "project" && grant.path == root.path {
                database.context.delete(grant)
            }
            try database.save()
            roots.removeAll { $0 == root }; refreshProjects(); invalidatePlan()
        } catch { message = error.localizedDescription }
    }
    func refreshProjects() {
        var found: [ProjectFolder] = []
        for root in roots {
            guard let children = try? FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey], options: .skipsHiddenFiles) else { continue }
            for child in children {
                guard let meta = try? FileSafety.metadata(child), FileSafety.isDirectory(meta), !FileSafety.isLink(meta),
                      (try? child.resourceValues(forKeys: [.isPackageKey]).isPackage) != true else { continue }
                found.append(ProjectFolder(url: child, root: root))
            }
        }
        projects = Array(Set(found)).sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        if !projects.contains(where: { $0.id == targetProject }) { targetProject = projects.first?.id ?? ""; specifiedFolder = nil }
    }
    var projectURL: URL? { projects.first { $0.id == targetProject }?.url }
    func chooseSubfolder() {
        guard let project = projectURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = project; panel.prompt = "选择存放位置"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileSafety.contains(project, url), url.resolvingSymlinksInPath() == url.standardizedFileURL else {
            message = "请选择当前项目内部的真实文件夹"; return
        }
        specifiedFolder = url; invalidatePlan()
    }
    func useNewFolder() {
        guard let project = projectURL else { return }
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), name != ".", name != "..", !name.hasPrefix(".") else {
            message = "请输入不含斜杠的普通文件夹名称"; return
        }
        specifiedFolder = (specifiedFolder ?? project).appendingPathComponent(name, isDirectory: true)
        newFolderName = ""; invalidatePlan()
    }
    func prepare() async {
        guard busy == nil, let project = projectURL, !chosenItems.isEmpty else { return }
        busy = "正在检查文件稳定性与目标位置…"; plans = []; message = nil
        let captured = chosenItems
        let folder = byCategory ? nil : (specifiedFolder ?? project)
        let conflict = conflict
        plans = await Task.detached {
            await ArchivePlanner.prepare(items: captured, project: project, specifiedFolder: folder, conflict: conflict)
        }.value
        busy = nil
    }
    func execute() async {
        guard busy == nil, plans.contains(where: \.canMove) else { return }
        busy = "等待投递确认…"
        let alert = NSAlert()
        alert.messageText = "移动 \(plans.filter(\.canMove).count) 项到所选项目？"
        alert.informativeText = "这是实际移动。源文件将离开桌面；同名项不会被覆盖。目标路径已在预检列表中显示。"
        alert.addButton(withTitle: "确认移动"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { busy = nil; return }
        busy = "正在逐项移动并记录结果…"; message = nil
        do {
            let batch = try await archives.execute(plans)
            reloadHistory()
            let entries = history.filter { $0.batchID == batch }
            message = "本次投递：\(entries.filter { $0.status == "moved" }.count) 项成功，\(entries.filter { $0.status != "moved" }.count) 项未移动或需核对。"
            plans = []; selected = []; tab = "history"
        } catch { message = "操作已停止：\(error.localizedDescription)。请在历史中核对状态。" }
        busy = nil; reloadHistory(); await refresh()
    }
    func undo(_ records: [MoveRecord]) async {
        guard busy == nil else { return }
        let eligible = records.filter { $0.status == "moved" }
        guard !eligible.isEmpty else { return }
        busy = "等待撤销确认…"
        let alert = NSAlert()
        alert.messageText = "撤销 \(eligible.count) 项投递？"
        alert.informativeText = "仅移回内容未变且原位置无冲突的项目，不覆盖现有文件。"
        alert.addButton(withTitle: "撤销投递"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { busy = nil; return }
        busy = "正在核对并撤销…"
        var errors: [String] = []
        for record in eligible {
            guard let desktop, FileSafety.contains(desktop, URL(fileURLWithPath: record.source)),
                  roots.contains(where: { FileSafety.contains($0, URL(fileURLWithPath: record.destination)) }) else {
                errors.append("原桌面或项目目录未授权，请重新添加对应目录"); continue
            }
            do { try await archives.undo(record) } catch { errors.append(error.localizedDescription) }
        }
        busy = nil; reloadHistory(); await refresh()
        message = errors.isEmpty ? "撤销检查完成，请查看每项结果。" : errors.joined(separator: "\n")
    }
    func reloadHistory() {
        do { history = try database.history() } catch { message = error.localizedDescription }
    }
    func reconcileHistory() async {
        guard busy == nil else { return }
        busy = "正在核对未完成记录…"
        do { try await archives.recover() } catch { message = error.localizedDescription }
        busy = nil; reloadHistory(); await refresh()
    }
    func savePreferences() {
        let p = database.preferences
        let newlyEnabled = weeklyEnabled && !p.weeklyEnabled
        p.days = max(1, min(365, days)); p.weeklyEnabled = weeklyEnabled
        if newlyEnabled || p.weekday != weekday || p.hour != hour || p.minute != minute {
            p.enabledSince = .now; p.lastReminder = nil
        }
        p.weekday = weekday; p.hour = hour; p.minute = minute; p.iconGuideConfirmed = guideConfirmed
        do { try database.save(); boardsChanged?() } catch { message = error.localizedDescription }
        if newlyEnabled {
            Task {
                do {
                    let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    if !granted { message = "通知未获授权；看板上的归档标记仍然有效。" }
                } catch { message = "通知不可用：\(error.localizedDescription)" }
            }
        }
    }
    func checkReminder(now: Date = .now) async {
        guard weeklyEnabled, items.contains(where: { !$0.isFixedFolder }),
              let occurrence = ReminderClock.dueOccurrence(now: now, enabledSince: database.preferences.enabledSince,
                last: database.preferences.lastReminder, weekday: weekday, hour: hour, minute: minute) else { return }
        database.preferences.lastReminder = occurrence
        do {
            try database.save()
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = "桌面可以整理一下了"
            content.body = "桌面有 \(items.filter { !$0.isFixedFolder }.count) 项可整理，其中 \(dueCount) 项已达到归档标记时间。固定文件夹不参与提醒。"
            try await center.add(UNNotificationRequest(identifier: "weekly-\(occurrence.timeIntervalSince1970)",
                content: content, trigger: nil))
        } catch { message = "本次提醒未发送：\(error.localizedDescription)" }
    }
}
