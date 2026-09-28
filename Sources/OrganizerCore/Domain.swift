import Foundation
import UniformTypeIdentifiers

public enum FileCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case images, pdf, documents, media, archives, folders, other
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .images: "图片素材"
        case .pdf: "PDF文档"
        case .documents: "其他文档"
        case .media: "音视频"
        case .archives: "压缩包"
        case .folders: "文件夹"
        case .other: "其他文件"
        }
    }
    public var symbol: String {
        switch self {
        case .images: "photo"
        case .pdf: "doc.richtext"
        case .documents: "doc.text"
        case .media: "play.rectangle"
        case .archives: "archivebox"
        case .folders: "folder"
        case .other: "square.stack"
        }
    }
    public static func classify(_ url: URL, directory: Bool, package: Bool = false) -> Self {
        if package { return .other }
        if directory { return .folders }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg"].contains(ext) { return .archives }
        if ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "md", "csv", "pages", "numbers", "key"].contains(ext) {
            return .documents
        }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .movie) || type.conforms(to: .audio) { return .media }
        if type.conforms(to: .text) || type.conforms(to: .spreadsheet) || type.conforms(to: .presentation) {
            return .documents
        }
        return .other
    }
}

public enum BoardCategory: String, CaseIterable, Identifiable, Sendable {
    case fixedFolders, folders, images, files
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .fixedFolders: "固定文件夹"
        case .folders: "临时文件夹"
        case .images: "图片与音视频"
        case .files: "文件"
        }
    }
    public var symbol: String {
        switch self {
        case .fixedFolders: "folder.badge.gearshape"
        case .folders: "folder"
        case .images: "photo"
        case .files: "doc.text"
        }
    }
}

public enum BoardTheme: String, CaseIterable, Identifiable, Codable, Sendable {
    case soft = "柔和浅色"
    case candy = "轻糖果色"
    case focus = "专注深色"
    case minimal = "极简白"
    public var id: String { rawValue }
}

public enum BoardColor: String, CaseIterable, Identifiable, Codable, Sendable {
    case mint = "薄荷"
    case peach = "蜜桃"
    case sky = "天空"
    case lavender = "雾紫"
    case butter = "奶油"
    case slate = "石墨"
    public var id: String { rawValue }
}

public enum BoardIconSize: String, CaseIterable, Identifiable, Codable, Sendable {
    case small = "小"
    case standard = "标准"
    case large = "大"
    public var id: String { rawValue }
    public var pixel: Double {
        switch self {
        case .small: 56
        case .standard: 72
        case .large: 88
        }
    }
    public var tileWidth: Double {
        switch self {
        case .small: 88
        case .standard: 108
        case .large: 132
        }
    }
    public var tileHeight: Double {
        switch self {
        case .small: 118
        case .standard: 138
        case .large: 158
        }
    }
}

public struct DesktopItem: Identifiable, Sendable {
    public let id: String
    public let url: URL
    public let category: FileCategory
    public let firstSeen: Date
    public let changedAt: Date
    public let unavailableReason: String?
    public let isFixedFolder: Bool
    public var sortOrder: Int?
    public var board: BoardCategory {
        if category == .folders { return isFixedFolder ? .fixedFolders : .folders }
        return category == .images || category == .media ? .images : .files
    }
    public var name: String { url.lastPathComponent }
    public func isDue(days: Int, now: Date = Date()) -> Bool {
        !isFixedFolder && now.timeIntervalSince(firstSeen) >= Double(max(1, days)) * 86400
    }
    public init(id: String, url: URL, category: FileCategory, firstSeen: Date,
                changedAt: Date, unavailableReason: String?, isFixedFolder: Bool = false,
                sortOrder: Int? = nil) {
        self.id = id; self.url = url; self.category = category
        self.firstSeen = firstSeen; self.changedAt = changedAt; self.unavailableReason = unavailableReason
        self.isFixedFolder = category == .folders && isFixedFolder
        self.sortOrder = sortOrder
    }
}

public enum DesktopItemOrdering {
    public static func sorted(_ items: [DesktopItem]) -> [DesktopItem] {
        items.sorted { lhs, rhs in
            switch (lhs.sortOrder, rhs.sortOrder) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                let result = lhs.name.localizedStandardCompare(rhs.name)
                return result == .orderedSame ? lhs.id < rhs.id : result == .orderedAscending
            }
        }
    }
}

public struct ProjectFolder: Identifiable, Hashable, Sendable {
    public let url: URL
    public let root: URL
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
    public init(url: URL, root: URL) { self.url = url; self.root = root }
}

public enum ConflictPolicy: String, CaseIterable, Sendable {
    case skip, keepBoth
    public var title: String { self == .skip ? "跳过同名项" : "保留两份" }
}

public struct FileStamp: Codable, Equatable, Sendable {
    public let identity: String
    public let signature: String
    public init(identity: String, signature: String) { self.identity = identity; self.signature = signature }
}

public struct MovePlan: Identifiable, Sendable {
    public let id: UUID
    public let source: URL
    public let destination: URL
    public let project: URL
    public let stamp: FileStamp?
    public let problem: String?
    public var canMove: Bool { stamp != nil && problem == nil }
    public init(id: UUID = UUID(), source: URL, destination: URL, project: URL,
                stamp: FileStamp?, problem: String?) {
        self.id = id; self.source = source; self.destination = destination
        self.project = project; self.stamp = stamp; self.problem = problem
    }
}

public enum OrganizerError: LocalizedError {
    case unsafe(String)
    public var errorDescription: String? {
        switch self { case .unsafe(let message): message }
    }
}

public enum ReminderClock {
    public static func dueOccurrence(now: Date, enabledSince: Date, last: Date?,
                                     weekday: Int, hour: Int, minute: Int,
                                     calendar: Calendar = .current) -> Date? {
        let components = DateComponents(hour: hour, minute: minute, weekday: weekday)
        guard let occurrence = calendar.nextDate(
            after: now.addingTimeInterval(1), matching: components,
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .backward),
              occurrence <= now, occurrence >= enabledSince,
              last.map({ occurrence > $0 }) ?? true else { return nil }
        return occurrence
    }
}
