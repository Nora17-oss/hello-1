import Foundation
import OrganizerCore
import OrganizerStore
import Darwin

@main
struct StorageSmoke {
    @MainActor
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3 else { throw OrganizerError.unsafe("Expected init|resume|verify and a test directory") }
            let phase = CommandLine.arguments[1]
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            let source = root.appendingPathComponent("Desktop/sample.txt")
            let project = root.appendingPathComponent("Project")
            let destination = project.appendingPathComponent("sample.txt")
            if phase == "init" {
                guard !FileSafety.exists(root) else { throw OrganizerError.unsafe("Test directory must not already exist") }
                try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                try Data("process-persistence-fixture".utf8).write(to: source)
                let database = try OrganizerDatabase(url: root.appendingPathComponent("AppData/store"))
                database.preferences.days = 19
                database.preferences.boardTheme = BoardTheme.candy.rawValue
                database.preferences.boardOpacity = 0.64
                database.preferences.boardIconSize = BoardIconSize.large.rawValue
                database.preferences.boardColors = [BoardCategory.images.rawValue: BoardColor.peach.rawValue]
                let observation = Observation(identity: "fixed-fixture", path: "/fixture/folder", now: .now)
                observation.isFixedFolder = true
                observation.sortOrder = 3
                database.context.insert(observation)
                database.context.insert(BoardName(category: "folders", name: "待整理"))
                let service = ArchiveService(database: database)
                _ = try await service.execute([MovePlan(source: source, destination: destination,
                    project: project, stamp: try FileSafety.stamp(source), problem: nil)])
                guard try database.history().first?.status == "moved" else { throw OrganizerError.unsafe("First process failed") }
                print("PASS first process: saved preferences, intent, and successful move")
            } else if phase == "resume" {
                let database = try OrganizerDatabase(url: root.appendingPathComponent("AppData/store"))
                guard database.preferences.days == 19,
                      database.preferences.boardTheme == BoardTheme.candy.rawValue,
                      database.preferences.boardOpacity == 0.64,
                      database.preferences.boardIconSize == BoardIconSize.large.rawValue,
                      database.preferences.boardColors?[BoardCategory.images.rawValue] == BoardColor.peach.rawValue,
                      let record = try database.history().first,
                      record.status == "moved", !FileSafety.exists(source) else {
                    throw OrganizerError.unsafe("Second process did not recover persisted state")
                }
                let service = ArchiveService(database: database)
                guard let observation = try database.observations().first,
                      observation.isFixedFolder == true, observation.sortOrder == 3,
                      try database.boardNames().first?.name == "待整理" else {
                    throw OrganizerError.unsafe("Folder classification, display order, or board name did not survive restart")
                }
                observation.isFixedFolder = false
                observation.sortOrder = 4
                try database.boardNames().first?.name = "进行中"
                try await service.undo(record)
                guard record.status == "undone", FileSafety.exists(source), !FileSafety.exists(destination),
                      try String(contentsOf: source, encoding: .utf8) == "process-persistence-fixture" else {
                    throw OrganizerError.unsafe("Second process undo failed")
                }
                _ = try await service.execute([MovePlan(source: source, destination: destination,
                    project: project, stamp: try FileSafety.stamp(source), problem: nil)])
                guard try database.history().count == 2 else { throw OrganizerError.unsafe("Second process could not append history") }
                print("PASS second process: loaded state, safely undid, and appended a new batch")
            } else if phase == "verify" {
                let database = try OrganizerDatabase(url: root.appendingPathComponent("AppData/store"))
                let records = try database.history()
                guard let observation = try database.observations().first,
                      observation.isFixedFolder == false, observation.sortOrder == 4,
                      try database.boardNames().first?.name == "进行中" else {
                    throw OrganizerError.unsafe("Temporary folder classification, display order, or board name did not survive restart")
                }
                guard database.preferences.days == 19,
                      database.preferences.boardTheme == BoardTheme.candy.rawValue,
                      database.preferences.boardOpacity == 0.64,
                      database.preferences.boardIconSize == BoardIconSize.large.rawValue,
                      database.preferences.boardColors?[BoardCategory.images.rawValue] == BoardColor.peach.rawValue,
                      records.count == 2,
                      records.filter({ $0.status == "moved" }).count == 1,
                      records.filter({ $0.status == "undone" }).count == 1,
                      !FileSafety.exists(source),
                      try String(contentsOf: destination, encoding: .utf8) == "process-persistence-fixture" else {
                    throw OrganizerError.unsafe("Third process failed to verify durable final states")
                }
                print("PASS third process: preferences and both final journal states are durable")
            } else { throw OrganizerError.unsafe("Unknown phase") }
        } catch {
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }
}
