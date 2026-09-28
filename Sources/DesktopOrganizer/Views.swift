import SwiftUI
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import OrganizerCore
import OrganizerStore

extension BoardCategory {
    var tint: Color {
        switch self {
        case .images: .pink
        case .files: .blue
        case .fixedFolders: .teal
        case .folders: .orange
        }
    }
}

extension BoardColor {
    var color: Color {
        switch self {
        case .mint: Color(red: 0.70, green: 0.86, blue: 0.78)
        case .peach: Color(red: 0.96, green: 0.76, blue: 0.63)
        case .sky: Color(red: 0.67, green: 0.82, blue: 0.94)
        case .lavender: Color(red: 0.80, green: 0.75, blue: 0.91)
        case .butter: Color(red: 0.96, green: 0.88, blue: 0.58)
        case .slate: Color(red: 0.28, green: 0.34, blue: 0.40)
        }
    }
}

extension BoardTheme {
    var colorScheme: ColorScheme {
        self == .focus ? .dark : .light
    }
}

struct FileThumbnail: View {
    let item: DesktopItem
    var size: CGFloat = 38
    @State private var image: NSImage?
    var body: some View {
        Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: item.url.path))
            .resizable().scaledToFit().frame(width: size, height: size)
            .task(id: "\(item.id)-\(item.changedAt.timeIntervalSince1970)") {
                image = nil
                guard item.unavailableReason == nil else { return }
                let request = QLThumbnailGenerator.Request(fileAt: item.url,
                    size: NSSize(width: size * 2, height: size * 2), scale: 2, representationTypes: .thumbnail)
                do {
                    let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                    if !Task.isCancelled { image = representation.nsImage }
                } catch { /* System file icon remains available for unsupported formats. */ }
            }
    }
}

struct FileRow: View {
    @ObservedObject var model: AppModel
    let item: DesktopItem
    var dragProvider: (() -> NSItemProvider)? = nil
    var body: some View {
        HStack(spacing: 8) {
            Button { model.toggle(item) } label: {
                Image(systemName: model.selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.selected.contains(item.id) ? Color.accentColor : .secondary)
            }.buttonStyle(.plain).help("选择或取消选择").disabled(model.busy != nil)
            FileThumbnail(item: item)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(2).truncationMode(.middle)
                    .font(.system(size: 12, weight: .medium))
                    .help(item.name)
                if let reason = item.unavailableReason {
                    Text(reason).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                } else if item.isDue(days: model.days) {
                    Label("可归档", systemImage: "tray.and.arrow.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(model.selected.contains(item.id) ? Color.accentColor.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(item) }
        .onDrag { dragProvider?() ?? NSItemProvider(object: item.url as NSURL) }
        .contextMenu {
            Button("打开", systemImage: "arrow.up.forward.app") { model.open(item) }
            Button("快速预览", systemImage: "eye") { model.preview?([item.url]) }
            Button("在 Finder 中显示", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Divider()
            if item.category == .folders {
                Button(item.isFixedFolder ? "改为临时文件夹" : "设为固定文件夹",
                       systemImage: item.isFixedFolder ? "folder" : "pin") {
                    Task { await model.setFixed(!item.isFixedFolder, items: [item]) }
                }.disabled(model.busy != nil)
            }
            Button("投递此项", systemImage: "tray.and.arrow.down") {
                model.selected = [item.id]; model.beginArchive()
            }.disabled(model.busy != nil || item.isFixedFolder)
        }
    }
}

struct ReorderableFileRow: View {
    @ObservedObject var model: AppModel
    let item: DesktopItem
    let category: BoardCategory
    @Binding var draggedID: String?

    var body: some View {
        FileRow(model: model, item: item, dragProvider: {
            draggedID = item.id
            let provider = NSItemProvider(object: item.url as NSURL)
            provider.registerObject("desktop-organizer-order:\(item.id)" as NSString, visibility: .all)
            return provider
        })
        .onDrop(of: [UTType.plainText], delegate: FileOrderDropDelegate(
            model: model, category: category, targetID: item.id, draggedID: $draggedID
        ))
    }
}

struct FileOrderDropDelegate: DropDelegate {
    let model: AppModel
    let category: BoardCategory
    let targetID: String
    @Binding var draggedID: String?

    func dropEntered(info: DropInfo) {
        guard let draggedID, draggedID != targetID else { return }
        model.previewReorder(draggedID, before: targetID, in: category)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard draggedID != nil else { return false }
        model.saveReorder(in: category)
        draggedID = nil
        return true
    }
}

struct FileTile: View {
    @ObservedObject var model: AppModel
    let item: DesktopItem

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                FileThumbnail(item: item, size: model.boardIconSize.pixel)
                Button { model.toggle(item) } label: {
                    Image(systemName: model.selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(model.selected.contains(item.id) ? Color.accentColor : .secondary)
                        .shadow(color: .white.opacity(0.85), radius: 2)
                }
                .buttonStyle(.plain)
                .help("选择或取消选择")
                .disabled(model.busy != nil)
                .offset(x: -6, y: -6)

                if item.isDue(days: model.days) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .background(.thinMaterial, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .offset(x: 5, y: -5)
                }
            }
            Text(item.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .top)
                .help(item.name)
            if item.unavailableReason != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help(item.unavailableReason ?? "")
            } else {
                Color.clear.frame(height: 11)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: model.boardIconSize.tileHeight, alignment: .top)
        .background(model.selected.contains(item.id) ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(item) }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .contextMenu {
            Button("打开", systemImage: "arrow.up.forward.app") { model.open(item) }
            Button("快速预览", systemImage: "eye") { model.preview?([item.url]) }
            Button("在 Finder 中显示", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Divider()
            if item.category == .folders {
                Button(item.isFixedFolder ? "改为临时文件夹" : "设为固定文件夹",
                       systemImage: item.isFixedFolder ? "folder" : "pin") {
                    Task { await model.setFixed(!item.isFixedFolder, items: [item]) }
                }.disabled(model.busy != nil)
            }
            Button("投递此项", systemImage: "tray.and.arrow.down") {
                model.selected = [item.id]; model.beginArchive()
            }.disabled(model.busy != nil || item.isFixedFolder)
        }
    }
}

struct CategoryBoard: View {
    @ObservedObject var model: AppModel
    let category: BoardCategory
    var body: some View {
        let collapsed = model.isBoardCollapsed(category)
        VStack(spacing: 0) {
            HStack {
                Image(systemName: category.symbol).foregroundStyle(category.tint)
                Text(model.boardTitle(category)).font(.system(size: 14, weight: .semibold))
                Text("\(model.visible(category).count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Menu {
                    Button("选中此看板全部文件") { model.selectAll(category) }
                    Button("取消全部选择") { model.selected = []; model.invalidatePlan() }
                    Button(collapsed ? "展开看板" : "收起看板",
                           systemImage: collapsed ? "chevron.down" : "chevron.up") {
                        model.toggleBoardCollapse?(category)
                    }
                    Button("控制中心") { model.showControl?() }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().help("看板菜单")
                Button {
                    model.toggleBoardCollapse?(category)
                } label: {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.plain)
                .help(collapsed ? "展开看板" : "收起看板")
            }.padding(.horizontal, 14).padding(.vertical, 10)
            if !collapsed {
                Divider()
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: model.boardIconSize.tileWidth, maximum: model.boardIconSize.tileWidth + 24), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(model.visible(category)) { FileTile(model: model, item: $0) }
                    }
                    .padding(12)
                }
                Divider()
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索桌面", text: $model.search).textFieldStyle(.plain)
                    Button { model.beginArchive() } label: {
                        Image(systemName: "tray.and.arrow.down")
                        if !model.selected.isEmpty { Text("\(model.selected.count)").monospacedDigit() }
                    }.help("投递选中的文件").disabled(model.selected.isEmpty || model.busy != nil)
                }.padding(10)
            }
        }
        .frame(minWidth: 240, minHeight: collapsed ? 0 : 190)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .background(model.boardColor(category).color.opacity(model.boardOpacity),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(model.boardColor(category).color.opacity(0.32), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .environment(\.colorScheme, model.boardTheme.colorScheme)
    }
}

struct ControlCenter: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "square.grid.2x2.fill").font(.title2).foregroundStyle(.teal)
                Text("桌面归纳器").font(.title3.bold())
                if model.demoRoot != nil { Text("示例目录").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Text("\(model.items.count) 项 · \(model.dueCount) 项可归档")
                    .font(.callout).foregroundStyle(.secondary)
                Button { Task { await model.refresh() }; model.refreshProjects() } label: {
                    Image(systemName: "arrow.clockwise")
                }.help("刷新文件与项目").disabled(model.busy != nil)
            }.padding(20)
            Picker("页面", selection: $model.tab) {
                Text("桌面文件").tag("files")
                Text("投递").tag("archive")
                Text("操作历史").tag("history")
                Text("设置").tag("settings")
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 14)
            Divider()
            if let busy = model.busy {
                HStack { ProgressView().controlSize(.small); Text(busy); Spacer() }
                    .padding(12).background(Color.accentColor.opacity(0.06))
            }
            if let message = model.message {
                HStack(alignment: .top) {
                    Text(message).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { model.message = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("关闭消息")
                }.padding(12).background(Color.yellow.opacity(0.12))
            }
            Group {
                switch model.tab {
                case "files": FileListView(model: model)
                case "archive": ArchiveView(model: model)
                case "history": HistoryView(model: model)
                default: SettingsView(model: model)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 660, minHeight: 520)
    }
}

struct FileListView: View {
    @ObservedObject var model: AppModel
    @State private var draggedID: String?
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("搜索桌面文件", text: $model.search)
                Toggle("只看可归档", isOn: $model.onlyDue).toggleStyle(.checkbox)
                Button("全选") {
                    model.selected = Set(BoardCategory.allCases.flatMap { model.visible($0) }.map(\.id))
                    model.invalidatePlan()
                }.disabled(model.busy != nil)
                Button("取消选择") { model.selected = []; model.invalidatePlan() }.disabled(model.busy != nil)
            }
            if model.chosenItems.contains(where: { $0.category == .folders }) {
                HStack {
                    Text("已选 \(model.chosenItems.filter { $0.category == .folders }.count) 个文件夹")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("设为固定文件夹", systemImage: "pin") {
                        Task { await model.setFixed(true, items: model.chosenItems) }
                    }
                    Button("改为临时文件夹", systemImage: "folder") {
                        Task { await model.setFixed(false, items: model.chosenItems) }
                    }
                }.disabled(model.busy != nil)
            }
            if model.desktop == nil {
                ContentUnavailableView("尚未授权桌面", systemImage: "folder.badge.questionmark")
                Button("选择桌面目录") { model.authorize(role: "desktop") }
            } else if model.items.isEmpty {
                ContentUnavailableView("桌面很清爽", systemImage: "sparkles")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(BoardCategory.allCases) { category in
                            if !model.visible(category).isEmpty {
                                Label(model.boardTitle(category), systemImage: category.symbol)
                                    .foregroundStyle(category.tint).font(.headline).padding(.top, 10)
                                ForEach(model.visible(category)) { item in
                                    if model.search.isEmpty && !model.onlyDue {
                                        ReorderableFileRow(model: model, item: item, category: category,
                                                           draggedID: $draggedID)
                                    } else {
                                        FileRow(model: model, item: item)
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                }
            }
            HStack {
                Text("已选 \(model.selected.count) 项").foregroundStyle(.secondary)
                Spacer()
                Button("投递选中项", systemImage: "tray.and.arrow.down") { model.beginArchive() }
                    .buttonStyle(.borderedProminent).disabled(model.selected.isEmpty || model.busy != nil)
            }
        }.padding(20)
    }
}

struct ArchiveView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.chosenItems.isEmpty {
                ContentUnavailableView("尚未选择文件", systemImage: "checkmark.circle")
                Button("选择桌面文件") { model.tab = "files" }
            } else {
                HStack {
                    Text("已选 \(model.chosenItems.count) 项").font(.headline)
                    Spacer()
                    Button("调整选择") { model.tab = "files" }.disabled(model.busy != nil)
                }
                if model.projects.isEmpty {
                    ContentUnavailableView("没有可投递的项目", systemImage: "folder.badge.plus")
                    Button("添加项目总目录") { model.authorize(role: "project") }
                } else {
                    archiveOptions
                    Divider()
                    if model.plans.isEmpty {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(model.chosenItems) { item in
                                    Label(item.name, systemImage: item.category.symbol).lineLimit(2)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(model.plans) { plan in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label(plan.source.lastPathComponent,
                                              systemImage: plan.canMove ? "checkmark.circle" : "exclamationmark.circle")
                                            .foregroundStyle(plan.canMove ? Color.primary : Color.orange)
                                        Text(plan.destination.path).font(.caption).foregroundStyle(.secondary)
                                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                        if let problem = plan.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
                                    }
                                    Divider()
                                }
                            }
                        }
                    }
                    HStack {
                        Text(model.plans.isEmpty ? "尚未预检" : "\(model.plans.filter(\.canMove).count) 项可移动")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("预检目标位置", systemImage: "checkmark.shield") { Task { await model.prepare() } }
                            .disabled(model.busy != nil)
                        Button("确认投递", systemImage: "tray.and.arrow.down") { Task { await model.execute() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy != nil || !model.plans.contains(where: \.canMove))
                    }
                }
            }
        }.padding(20)
    }
    private var archiveOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("目标项目", selection: $model.targetProject) {
                ForEach(model.projects) { project in
                    Text("\(project.name) · \(project.root.lastPathComponent)").tag(project.id)
                }
            }.onChange(of: model.targetProject) { model.specifiedFolder = nil; model.invalidatePlan() }
            Picker("存放方式", selection: $model.byCategory) {
                Text("按类型分放").tag(true)
                Text("指定文件夹").tag(false)
            }.pickerStyle(.segmented).onChange(of: model.byCategory) { model.invalidatePlan() }
            if !model.byCategory {
                HStack {
                    Text((model.specifiedFolder ?? model.projectURL)?.path ?? "")
                        .font(.caption).textSelection(.enabled).lineLimit(3)
                    Spacer()
                    Button("项目根目录") { model.specifiedFolder = nil; model.invalidatePlan() }
                    Button { model.chooseSubfolder() } label: { Image(systemName: "folder") }.help("选择已有子文件夹")
                }
                HStack {
                    TextField("新文件夹名称", text: $model.newFolderName)
                    Button { model.useNewFolder() } label: { Image(systemName: "folder.badge.plus") }
                        .help("使用新建子文件夹").disabled(model.newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Picker("同名处理", selection: $model.conflict) {
                ForEach(ConflictPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }.onChange(of: model.conflict) { model.invalidatePlan() }
        }.disabled(model.busy != nil)
    }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    private var batches: [UUID] {
        var seen = Set<UUID>()
        return model.history.compactMap { seen.insert($0.batchID).inserted ? $0.batchID : nil }
    }
    private func label(_ status: String) -> String {
        switch status {
        case "pending": "待核对"
        case "moved": "已投递"
        case "undone": "已撤销"
        case "undoPending": "撤销待核对"
        case "skipped": "已跳过"
        case "failed": "未完成"
        default: "需人工核对"
        }
    }
    var body: some View {
        if model.history.isEmpty {
            ContentUnavailableView("暂无投递记录", systemImage: "clock.arrow.circlepath")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Spacer()
                        Button("核对未完成记录", systemImage: "arrow.clockwise") {
                            Task { await model.reconcileHistory() }
                        }.disabled(model.busy != nil)
                    }
                    ForEach(batches, id: \.self) { batch in
                        let records = model.history.filter { $0.batchID == batch }
                        HStack {
                            Text(records.first?.date.formatted(date: .abbreviated, time: .shortened) ?? "")
                                .font(.headline)
                            Spacer()
                            Button("撤销本批次", systemImage: "arrow.uturn.backward") {
                                Task { await model.undo(records) }
                            }.disabled(model.busy != nil || !records.contains { $0.status == "moved" })
                        }
                        ForEach(records, id: \.id) { record in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(URL(fileURLWithPath: record.source).lastPathComponent).fontWeight(.medium)
                                    Text(record.destination).font(.caption).foregroundStyle(.secondary)
                                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    if !record.detail.isEmpty { Text(record.detail).font(.caption).foregroundStyle(.orange) }
                                }
                                Spacer()
                                Text(label(record.status)).font(.caption)
                                Menu {
                                    Button("显示原位置") {
                                        NSWorkspace.shared.open(URL(fileURLWithPath: record.source).deletingLastPathComponent())
                                    }
                                    Button("显示目标位置") {
                                        NSWorkspace.shared.open(URL(fileURLWithPath: record.destination).deletingLastPathComponent())
                                    }
                                    Button("撤销此项") { Task { await model.undo([record]) } }
                                        .disabled(model.busy != nil || record.status != "moved")
                                } label: { Image(systemName: "ellipsis") }
                                .menuStyle(.borderlessButton).fixedSize().help("此项操作")
                            }
                            Divider()
                        }
                    }
                }.padding(20)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("桌面目录") {
                if let desktop = model.desktop {
                    Text(desktop.path).font(.callout).textSelection(.enabled)
                } else { Text("未授权").foregroundStyle(.secondary) }
                Button(model.desktop == nil ? "选择桌面目录" : "重新授权桌面目录", systemImage: "folder.badge.gearshape") {
                    model.authorize(role: "desktop")
                }.disabled(model.demoRoot != nil || model.busy != nil)
            }
            Section("项目总目录") {
                ForEach(model.roots, id: \.path) { root in
                    HStack {
                        Text(root.path).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { model.removeRoot(root) } label: { Image(systemName: "minus.circle") }
                            .help("移除目录授权记录").disabled(model.demoRoot != nil || model.busy != nil)
                    }
                }
                Button("添加项目总目录", systemImage: "folder.badge.plus") { model.authorize(role: "project") }
                    .disabled(model.demoRoot != nil || model.busy != nil)
            }
            Section("归档提示") {
                Stepper("停留 \(model.days) 天后标记", value: $model.days, in: 1...365)
                    .onChange(of: model.days) { model.savePreferences() }
                Toggle("每周提醒", isOn: $model.weeklyEnabled).onChange(of: model.weeklyEnabled) { model.savePreferences() }
                if model.weeklyEnabled {
                    HStack {
                        Picker("星期", selection: $model.weekday) {
                            ForEach(1...7, id: \.self) { day in
                                Text(["周日", "周一", "周二", "周三", "周四", "周五", "周六"][day - 1]).tag(day)
                            }
                        }
                        Picker("时", selection: $model.hour) {
                            ForEach(0...23, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        Picker("分", selection: $model.minute) {
                            ForEach(0...59, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                    }
                    .onChange(of: model.weekday) { model.savePreferences() }
                    .onChange(of: model.hour) { model.savePreferences() }
                    .onChange(of: model.minute) { model.savePreferences() }
                }
            }
            Section("看板名称") {
                ForEach(BoardCategory.allCases) { category in
                    HStack {
                        Image(systemName: category.symbol).foregroundStyle(category.tint)
                        TextField(category.title, text: Binding(
                            get: { model.boardNameDrafts[category] ?? category.title },
                            set: { model.setBoardNameDraft($0, for: category) }
                        ))
                        Button { model.resetBoardName(category) } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.plain)
                        .help("恢复默认名称")
                    }
                }
                Button("保存看板名称", systemImage: "checkmark") { model.saveBoardNames() }
                    .disabled(model.busy != nil)
            }
            Section("看板外观") {
                Picker("主题方案", selection: Binding(
                    get: { model.boardTheme },
                    set: { model.applyTheme($0); model.saveAppearance() }
                )) {
                    ForEach(BoardTheme.allCases) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
                Picker("图标大小", selection: Binding(
                    get: { model.boardIconSize },
                    set: { model.boardIconSize = $0; model.saveAppearance() }
                )) {
                    ForEach(BoardIconSize.allCases) { size in
                        Text(size.rawValue).tag(size)
                    }
                }
                HStack {
                    Text("透明度")
                    Slider(value: Binding(
                        get: { model.boardOpacity },
                        set: { model.boardOpacity = $0 }
                    ), in: 0.35...1, step: 0.05)
                    Text("\(Int(model.boardOpacity * 100))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                .onChange(of: model.boardOpacity) { model.saveAppearance() }
                Text("看板颜色").font(.headline)
                ForEach(BoardCategory.allCases) { category in
                    HStack {
                        Image(systemName: category.symbol)
                            .foregroundStyle(model.boardColor(category).color)
                        Text(model.boardTitle(category))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { model.boardColor(category) },
                            set: { model.setBoardColor($0, for: category); model.saveAppearance() }
                        )) {
                            ForEach(BoardColor.allCases) { color in
                                Text(color.rawValue).tag(color)
                            }
                        }
                        .labelsHidden()
                    }
                }
            }
            Section("系统桌面图标") {
                Toggle("已确认系统桌面图标显示设置", isOn: $model.guideConfirmed)
                    .onChange(of: model.guideConfirmed) { model.savePreferences() }
                Button("打开桌面与程序坞设置", systemImage: "gearshape") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
                }
            }
        }.formStyle(.grouped)
    }
}
