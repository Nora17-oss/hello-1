import Foundation
import SwiftData
import Observation
import OrganizerCore

public protocol StoreRecord: AnyObject, Codable {
    var storageKey: String { get }
}

public final class Preferences: StoreRecord {
    public var key = "main"
    public var days = 7
    public var weeklyEnabled = false
    public var weekday = 6
    public var hour = 20
    public var minute = 0
    public var enabledSince = Date()
    public var lastReminder: Date?
    public var iconGuideConfirmed = false
    public var boardTheme: String?
    public var boardOpacity: Double?
    public var boardIconSize: String?
    public var boardColors: [String: String]?
    public var storageKey: String { "preferences:\(key)" }
    public init() {}
}

public final class FolderGrant: StoreRecord {
    public var id: UUID
    public var role: String
    public var path: String
    public var bookmark: Data
    public var storageKey: String { "grant:\(id)" }
    public init(role: String, path: String, bookmark: Data) {
        id = UUID(); self.role = role; self.path = path; self.bookmark = bookmark
    }
}

public final class Observation: StoreRecord {
    public var identity: String
    public var path: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var present: Bool
    public var isFixedFolder: Bool?
    public var sortOrder: Int?
    public var storageKey: String { "observation:\(identity)" }
    public init(identity: String, path: String, now: Date) {
        self.identity = identity; self.path = path
        firstSeen = now; lastSeen = now; present = true
    }
}

public final class BoardLayout: StoreRecord {
    public var category: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var collapsed: Bool?
    public var storageKey: String { "layout:\(category)" }
    public init(category: String, x: Double, y: Double, width: Double, height: Double) {
        self.category = category; self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public final class BoardName: StoreRecord {
    public var category: String
    public var name: String
    public var storageKey: String { "boardName:\(category)" }
    public init(category: String, name: String) {
        self.category = category; self.name = name
    }
}

public final class MoveRecord: StoreRecord {
    public var id: UUID
    public var batchID: UUID
    public var date: Date
    public var source: String
    public var destination: String
    public var project: String
    public var identity: String
    public var signature: String
    public var status: String
    public var detail: String
    public var storageKey: String { "move:\(id)" }
    public init(plan: MovePlan, batchID: UUID) {
        id = plan.id; self.batchID = batchID; date = .now
        source = plan.source.path; destination = plan.destination.path; project = plan.project.path
        identity = plan.stamp?.identity ?? ""; signature = plan.stamp?.signature ?? ""
        status = plan.canMove ? "pending" : "skipped"; detail = plan.problem ?? ""
    }
    public var stamp: FileStamp { FileStamp(identity: identity, signature: signature) }
}

// Explicit PersistentModel conformance avoids the macro plugin omitted by CLT.
// Each versioned domain record is a SwiftData row committed by ModelContext.save().
final class PersistedRow: PersistentModel {
    // Fetched models also need the default backing initialization before assignment.
    private var backing: any BackingData<PersistedRow> = PersistedRow.createBackingData()
    var persistentBackingData: any BackingData<PersistedRow> {
        get { backing }
        set { backing = newValue }
    }
    private let registrar = ObservationRegistrar()
    static var schemaMetadata: [Schema.PropertyMetadata] {
        [
            .init(name: "recordKey", keypath: \PersistedRow.recordKey, defaultValue: ""),
            .init(name: "payload", keypath: \PersistedRow.payload, defaultValue: Data()),
            .init(name: "version", keypath: \PersistedRow.version, defaultValue: 1)
        ]
    }
    var recordKey: String {
        get { registrar.access(self, keyPath: \.recordKey); return getValue(forKey: \.recordKey) }
        set { registrar.withMutation(of: self, keyPath: \.recordKey) { setValue(forKey: \.recordKey, to: newValue) } }
    }
    var payload: Data {
        get { registrar.access(self, keyPath: \.payload); return getValue(forKey: \.payload) }
        set { registrar.withMutation(of: self, keyPath: \.payload) { setValue(forKey: \.payload, to: newValue) } }
    }
    var version: Int {
        get { registrar.access(self, keyPath: \.version); return getValue(forKey: \.version) }
        set { registrar.withMutation(of: self, keyPath: \.version) { setValue(forKey: \.version, to: newValue) } }
    }
    init(backingData: any BackingData<PersistedRow>) { persistentBackingData = backingData }
    init(key: String, payload: Data) {
        persistentBackingData.setValue(forKey: \.recordKey, to: key)
        persistentBackingData.setValue(forKey: \.payload, to: payload)
        persistentBackingData.setValue(forKey: \.version, to: 1)
    }
}

@MainActor
public final class RecordContext {
    fileprivate var records: [String: any StoreRecord] = [:]
    public func insert<T: StoreRecord>(_ record: T) { records[record.storageKey] = record }
    public func delete<T: StoreRecord>(_ record: T) { records.removeValue(forKey: record.storageKey) }
}

@MainActor
public final class OrganizerDatabase {
    private final class RowCache {
        var values: [String: PersistedRow] = [:]
        var loaded = false
        var usable = true
    }
    private static let sharedSchema = Schema([PersistedRow.self])
    // SwiftData's backing-data factory on macOS 15 depends on live containers.
    // Main-actor clients of a store share its container and context for their lifetime.
    private static var containers: [String: ModelContainer] = [:]
    private static var contexts: [String: ModelContext] = [:]
    private static var recordContexts: [String: RecordContext] = [:]
    private static var rowCaches: [String: RowCache] = [:]
    public let container: ModelContainer
    public let context: RecordContext
    public let preferences: Preferences
    private let modelContext: ModelContext
    private let rowCache: RowCache
    private var rows: [String: PersistedRow] {
        get { rowCache.values }
        set { rowCache.values = newValue }
    }
    public init(url: URL? = nil, inMemory: Bool = false) throws {
        let schema = Self.sharedSchema
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        }
        let containerKey = inMemory ? "memory:\(UUID())" : (url?.standardizedFileURL.path ?? "default")
        if let existing = Self.containers[containerKey] {
            container = existing
        } else {
            let created = try ModelContainer(for: schema, configurations: config)
            Self.containers[containerKey] = created
            container = created
        }
        if let existing = Self.contexts[containerKey] {
            modelContext = existing
        } else {
            let created = ModelContext(container)
            Self.contexts[containerKey] = created
            modelContext = created
        }
        if let existing = Self.recordContexts[containerKey] {
            context = existing
        } else {
            let created = RecordContext()
            Self.recordContexts[containerKey] = created
            context = created
        }
        modelContext.autosaveEnabled = false
        if let existing = Self.rowCaches[containerKey] {
            rowCache = existing
        } else {
            let created = RowCache()
            Self.rowCaches[containerKey] = created
            rowCache = created
        }
        let decoder = JSONDecoder()
        let fetched = rowCache.loaded ? [] : try modelContext.fetch(FetchDescriptor<PersistedRow>())
        for row in fetched {
            guard row.version == 1, rowCache.values[row.recordKey] == nil else {
                throw OrganizerError.unsafe("数据库包含不支持的版本或重复记录，已停止读取")
            }
            rowCache.values[row.recordKey] = row
            if context.records[row.recordKey] != nil { continue }
            let record: any StoreRecord
            switch row.recordKey.split(separator: ":").first {
            case "preferences": record = try decoder.decode(Preferences.self, from: row.payload)
            case "grant": record = try decoder.decode(FolderGrant.self, from: row.payload)
            case "observation": record = try decoder.decode(Observation.self, from: row.payload)
            case "layout": record = try decoder.decode(BoardLayout.self, from: row.payload)
            case "boardName": record = try decoder.decode(BoardName.self, from: row.payload)
            case "move": record = try decoder.decode(MoveRecord.self, from: row.payload)
            default: throw OrganizerError.unsafe("发现不支持的数据类型，已停止读取")
            }
            guard record.storageKey == row.recordKey else { throw OrganizerError.unsafe("数据库记录身份不一致") }
            context.records[row.recordKey] = record
        }
        rowCache.loaded = true
        preferences = context.records["preferences:main"] as? Preferences ?? Preferences()
        context.insert(preferences)
        try save()
    }
    public func save() throws {
        guard rowCache.usable else { throw OrganizerError.unsafe("数据库保存已中断，请退出并重新打开应用后核对记录") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try context.records.mapValues { try encoder.encode($0) }
        for (key, row) in rows where encoded[key] == nil { modelContext.delete(row) }
        for (key, payload) in encoded {
            if let row = rows[key] {
                if row.payload != payload { row.payload = payload }
            } else {
                let row = PersistedRow(key: key, payload: payload)
                rows[key] = row
                modelContext.insert(row)
            }
        }
        do {
            try modelContext.save()
            rows = rows.filter { encoded[$0.key] != nil }
        } catch {
            rowCache.usable = false
            throw error
        }
    }
    public func observations() throws -> [Observation] { context.records.values.compactMap { $0 as? Observation } }
    public func grants() throws -> [FolderGrant] { context.records.values.compactMap { $0 as? FolderGrant } }
    public func layouts() throws -> [BoardLayout] { context.records.values.compactMap { $0 as? BoardLayout } }
    public func boardNames() throws -> [BoardName] { context.records.values.compactMap { $0 as? BoardName } }
    public func history() throws -> [MoveRecord] {
        context.records.values.compactMap { $0 as? MoveRecord }.sorted { $0.date > $1.date }
    }
}
