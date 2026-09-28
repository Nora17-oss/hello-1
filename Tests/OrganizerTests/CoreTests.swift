import Foundation
import CoreGraphics
import Testing
import OrganizerCore
import OrganizerStore
import Darwin

private func workspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("organizer-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

@Test func newBoardAvoidsExistingAndRestoredOverlaps() throws {
    let screen = CGRect(x: 54, y: 0, width: 1738, height: 1095)
    let existing = CGRect(x: 68, y: 730, width: 370, height: 350)
    let preferred = CGRect(x: 70, y: 727, width: 370, height: 350)
    let placed = try #require(BoardPlacement.availableFrame(preferred: preferred, screen: screen, occupied: [existing]))
    #expect(!placed.intersects(existing))
    #expect(screen.contains(placed))
    #expect(placed.size == preferred.size)
    #expect(BoardPlacement.availableFrame(preferred: placed, screen: screen, occupied: [existing]) == placed)
}

@Test func fourBoardsFindSeparatePositionsAndReportNoSpace() throws {
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let preferred = CGRect(x: 16, y: 434, width: 370, height: 350)
    var frames: [CGRect] = []
    for _ in 0..<4 {
        let placed = try #require(BoardPlacement.availableFrame(preferred: preferred, screen: screen, occupied: frames))
        #expect(frames.allSatisfy { !$0.intersects(placed) })
        frames.append(placed)
    }
    #expect(BoardPlacement.availableFrame(preferred: preferred, screen: screen, occupied: [screen]) == nil)
}

@Test func collapsingBoardKeepsItsTopEdgeAndRestoresItsHeight() {
    let expanded = CGRect(x: 70, y: 740, width: 370, height: 350)
    let collapsed = BoardGeometry.collapsed(expanded)
    #expect(collapsed.height == BoardGeometry.collapsedHeight)
    #expect(collapsed.maxY == expanded.maxY)
    #expect(collapsed.width == expanded.width)
    let restored = BoardGeometry.expanded(collapsed, height: expanded.height)
    #expect(restored == expanded)
}

@Test func oldBoardLayoutDefaultsToExpandedAndNewStateRoundTrips() throws {
    let oldJSON = #"{"category":"images","x":70,"y":740,"width":370,"height":350}"#
    let old = try JSONDecoder().decode(BoardLayout.self, from: Data(oldJSON.utf8))
    #expect(old.collapsed == nil)
    old.collapsed = true
    let restored = try JSONDecoder().decode(BoardLayout.self, from: JSONEncoder().encode(old))
    #expect(restored.collapsed == true)
    #expect(restored.height == 350)
}

@MainActor @Test func boardNamesAreSeparateFromLayoutAndRoundTrip() throws {
    let database = try OrganizerDatabase(inMemory: true)
    let name = BoardName(category: BoardCategory.folders.rawValue, name: "待整理")
    database.context.insert(name)
    try database.save()
    #expect(try database.boardNames().first?.storageKey == "boardName:folders")
    #expect(try database.boardNames().first?.name == "待整理")
    #expect(try database.layouts().isEmpty)
}

@Test func appearancePreferencesRoundTripAndOldSettingsStillDecode() throws {
    let oldJSON = #"{"key":"main","days":7,"weeklyEnabled":false,"weekday":6,"hour":20,"minute":0,"enabledSince":0,"iconGuideConfirmed":false}"#
    let old = try JSONDecoder().decode(Preferences.self, from: Data(oldJSON.utf8))
    #expect(old.boardTheme == nil)
    #expect(old.boardOpacity == nil)
    let current = Preferences()
    current.boardTheme = BoardTheme.candy.rawValue
    current.boardOpacity = 0.64
    current.boardIconSize = BoardIconSize.large.rawValue
    current.boardColors = [BoardCategory.images.rawValue: BoardColor.peach.rawValue]
    let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(current))
    #expect(restored.boardTheme == BoardTheme.candy.rawValue)
    #expect(restored.boardOpacity == 0.64)
    #expect(restored.boardIconSize == BoardIconSize.large.rawValue)
    #expect(restored.boardColors?[BoardCategory.images.rawValue] == BoardColor.peach.rawValue)
}

@Test func categoriesRespectFoldersAndPackages() {
    #expect(FileCategory.classify(URL(fileURLWithPath: "/x.PNG"), directory: false) == .images)
    #expect(FileCategory.classify(URL(fileURLWithPath: "/x.pdf"), directory: false) == .pdf)
    #expect(FileCategory.classify(URL(fileURLWithPath: "/x.docx"), directory: false) == .documents)
    #expect(FileCategory.classify(URL(fileURLWithPath: "/x.mp3"), directory: false) == .media)
    #expect(FileCategory.classify(URL(fileURLWithPath: "/x.zip"), directory: false) == .archives)
    #expect(FileCategory.classify(URL(fileURLWithPath: "/x"), directory: true) == .folders)
    #expect(FileCategory.classify(URL(fileURLWithPath: "/x.app"), directory: true, package: true) == .other)
}

@Test func fourBoardsGroupMediaAndKeepDocumentsTogether() {
    #expect(BoardCategory.allCases.count == 4)
    for ext in ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "zip", "unknown"] {
        let url = URL(fileURLWithPath: "/example.\(ext)")
        let item = DesktopItem(id: ext, url: url,
            category: FileCategory.classify(url, directory: false), firstSeen: .distantPast,
            changedAt: .now, unavailableReason: nil, isFixedFolder: true)
        #expect(item.board == .files)
        #expect(!item.isFixedFolder)
    }
    let image = DesktopItem(id: "image", url: URL(fileURLWithPath: "/image.png"),
        category: .images, firstSeen: .now, changedAt: .now, unavailableReason: nil)
    #expect(image.board == .images)
    for ext in ["jpg", "png", "mp3", "wav", "m4a", "mp4", "mov"] {
        let url = URL(fileURLWithPath: "/example.\(ext)")
        let item = DesktopItem(id: ext, url: url,
            category: FileCategory.classify(url, directory: false), firstSeen: .now,
            changedAt: .now, unavailableReason: nil)
        #expect(item.board == .images)
    }
    #expect(BoardCategory.images.title == "图片与音视频")
}

@Test func customDisplayOrderOverridesNameAndLeavesNewItemsLast() {
    func item(_ id: String, _ name: String, _ order: Int?) -> DesktopItem {
        DesktopItem(id: id, url: URL(fileURLWithPath: "/\(name)"), category: .documents,
                    firstSeen: .now, changedAt: .now, unavailableReason: nil, sortOrder: order)
    }
    let ordered = DesktopItemOrdering.sorted([
        item("third", "A.txt", 2),
        item("new", "B.txt", nil),
        item("first", "Z.txt", 0),
        item("second", "C.txt", 1)
    ])
    #expect(ordered.map(\.id) == ["first", "second", "third", "new"])
}

@Test func fixedFoldersAreNotDueAndCannotBePlanned() async throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Desktop/folder")
    let project = root.appendingPathComponent("Project")
    try write("unchanged", to: folder.appendingPathComponent("child.txt"))
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let stamp = try FileSafety.stamp(folder)
    let fixed = DesktopItem(id: stamp.identity, url: folder, category: .folders,
        firstSeen: .distantPast, changedAt: .now, unavailableReason: nil, isFixedFolder: true)
    #expect(fixed.board == .fixedFolders)
    #expect(!fixed.isDue(days: 1))
    let plans = await ArchivePlanner.prepare(items: [fixed], project: project,
        specifiedFolder: project, conflict: .skip, stabilityDelay: 0)
    #expect(plans.count == 1)
    #expect(plans[0].problem?.contains("固定文件夹") == true)
    #expect(!plans[0].canMove)
    #expect(try FileSafety.stamp(folder) == stamp)
    let temporary = DesktopItem(id: stamp.identity, url: folder, category: .folders,
        firstSeen: .distantPast, changedAt: .now, unavailableReason: nil)
    #expect(temporary.board == .folders)
    #expect(temporary.isDue(days: 1))
    let allowed = await ArchivePlanner.prepare(items: [temporary], project: project,
        specifiedFolder: project, conflict: .skip, stabilityDelay: 0)
    #expect(allowed.first?.canMove == true)
}

@Test func oldObservationDefaultsToTemporaryFolder() throws {
    let oldJSON = #"{"identity":"legacy","path":"/Desktop/Folder","firstSeen":0,"lastSeen":0,"present":true}"#
    let old = try JSONDecoder().decode(Observation.self, from: Data(oldJSON.utf8))
    #expect(old.isFixedFolder == nil)
    #expect(old.sortOrder == nil)
    old.isFixedFolder = true
    old.sortOrder = 4
    let updated = try JSONDecoder().decode(Observation.self, from: JSONEncoder().encode(old))
    #expect(updated.isFixedFolder == true)
    #expect(updated.sortOrder == 4)
}

@Test func moveDoesNotOverwriteAndPreservesContents() throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Desktop/image.txt")
    let project = root.appendingPathComponent("Project")
    let destination = project.appendingPathComponent("Docs/image.txt")
    try write("original", to: source)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let stamp = try FileSafety.stamp(source)
    try FileSafety.move(source: source, destination: destination, project: project, expected: stamp)
    #expect(!FileSafety.exists(source))
    #expect(try FileSafety.stamp(destination) == stamp)
    try write("new", to: source)
    let newStamp = try FileSafety.stamp(source)
    #expect(throws: (any Error).self) {
        try FileSafety.move(source: source, destination: destination, project: project, expected: newStamp)
    }
    #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
    #expect(try String(contentsOf: source, encoding: .utf8) == "new")
}

@Test func mutationAfterPreflightIsBlocked() throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("a.txt"), project = root.appendingPathComponent("Project")
    try write("before", to: source)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let stamp = try FileSafety.stamp(source)
    try write("after!", to: source)
    #expect(throws: (any Error).self) {
        try FileSafety.move(source: source, destination: project.appendingPathComponent("a.txt"), project: project, expected: stamp)
    }
    #expect(FileSafety.exists(source))
}

@Test func destinationLinksAndSelfMovesAreRejected() throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("a.txt"), project = root.appendingPathComponent("Project")
    let outside = root.appendingPathComponent("Outside")
    try write("data", to: source)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("link"), withDestinationURL: outside)
    #expect(throws: (any Error).self) {
        try FileSafety.validateDestination(source: source, destination: project.appendingPathComponent("link/a.txt"), project: project)
    }
    #expect(throws: (any Error).self) {
        try FileSafety.validateDestination(source: project, destination: project.appendingPathComponent("nested"), project: project)
    }
}

@Test func plannerSkipsOrRenamesConflicts() async throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Desktop/a.txt"), project = root.appendingPathComponent("Project")
    try write("source", to: source); try write("existing", to: project.appendingPathComponent("a.txt"))
    let item = DesktopItem(id: "one", url: source, category: .documents, firstSeen: .now, changedAt: .now, unavailableReason: nil)
    let skip = await ArchivePlanner.prepare(items: [item], project: project, specifiedFolder: project, conflict: .skip, stabilityDelay: 1)
    #expect(skip.count == 1 && !skip[0].canMove)
    let keep = await ArchivePlanner.prepare(items: [item], project: project, specifiedFolder: project, conflict: .keepBoth, stabilityDelay: 1)
    #expect(keep[0].canMove)
    #expect(keep[0].destination.lastPathComponent == "a (2).txt")
    #expect(FileSafety.exists(source))
}

@Test func reminderDoesNotRepeatOrBackfillBeforeEnable() {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let enabled = ISO8601DateFormatter().date(from: "2026-09-21T00:00:00Z")!
    let now = ISO8601DateFormatter().date(from: "2026-09-27T10:00:00Z")!
    let due = ReminderClock.dueOccurrence(now: now, enabledSince: enabled, last: nil, weekday: 6, hour: 20, minute: 0, calendar: calendar)
    #expect(due == ISO8601DateFormatter().date(from: "2026-09-25T20:00:00Z"))
    #expect(ReminderClock.dueOccurrence(now: now, enabledSince: enabled, last: due, weekday: 6, hour: 20, minute: 0, calendar: calendar) == nil)
    #expect(ReminderClock.dueOccurrence(now: now, enabledSince: now, last: nil, weekday: 6, hour: 20, minute: 0, calendar: calendar) == nil)
}

@Test @MainActor func journalMoveUndoAndRecovery() async throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let db = try OrganizerDatabase(inMemory: true)
    let service = ArchiveService(database: db)
    let source = root.appendingPathComponent("Desktop/a.txt"), project = root.appendingPathComponent("Project")
    try write("safe", to: source); try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let plan = MovePlan(source: source, destination: project.appendingPathComponent("a.txt"),
                        project: project, stamp: try FileSafety.stamp(source), problem: nil)
    _ = try await service.execute([plan])
    let record = try #require(db.history().first)
    #expect(record.status == "moved")
    try await service.undo(record)
    #expect(record.status == "undone")
    #expect(try String(contentsOf: source, encoding: .utf8) == "safe")
    let interrupted = MoveRecord(plan: plan, batchID: UUID())
    db.context.delete(record); db.context.insert(interrupted); try db.save()
    try FileSafety.move(source: source, destination: plan.destination, project: project, expected: plan.stamp!)
    try await service.recover()
    #expect(interrupted.status == "moved")
}

@Test @MainActor func undoRejectsChangedTargetAndExistingOriginal() async throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let db = try OrganizerDatabase(inMemory: true), source = root.appendingPathComponent("Desktop/a.txt")
    let project = root.appendingPathComponent("Project"), destination = root.appendingPathComponent("Project/a.txt")
    try write("safe", to: source); try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let service = ArchiveService(database: db)
    _ = try await service.execute([MovePlan(source: source, destination: destination, project: project,
                                           stamp: try FileSafety.stamp(source), problem: nil)])
    let record = try #require(db.history().first)
    try write("edited", to: destination)
    try await service.undo(record)
    #expect(record.status == "moved")
    #expect(!FileSafety.exists(source))
    #expect(try String(contentsOf: destination, encoding: .utf8) == "edited")
    try write("unrelated", to: source)
    await #expect(throws: (any Error).self) { try await service.undo(record) }
    #expect(try String(contentsOf: source, encoding: .utf8) == "unrelated")
}

@Test @MainActor func persistentSettingsObservationsAndLogSurviveReopen() throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("database.store")
    let observed = Date(timeIntervalSince1970: 1000)
    do {
        let db = try OrganizerDatabase(url: url)
        db.preferences.days = 12
        db.context.insert(Observation(identity: "fixture", path: "/sample/a.txt", now: observed))
        db.context.insert(FolderGrant(role: "project", path: "/sample/projects", bookmark: Data([1, 2])))
        db.context.insert(BoardLayout(category: "images", x: 14, y: 22, width: 310, height: 340))
        try db.save()
        db.preferences.hour = 18; try db.save()
    }
    let reopened = try OrganizerDatabase(url: url)
    #expect(reopened.preferences.days == 12)
    #expect(reopened.preferences.hour == 18)
    #expect(try reopened.observations().first?.firstSeen == observed)
    #expect(try reopened.grants().first?.bookmark == Data([1, 2]))
    #expect(try reopened.layouts().first?.width == 310)
    let grant = try #require(reopened.grants().first)
    reopened.context.delete(grant); try reopened.save()
    let again = try OrganizerDatabase(url: url)
    #expect(try again.grants().isEmpty)
}

@Test func nestedFolderIsMovedIntactAndEditsAreDetected() throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("素材包")
    let project = root.appendingPathComponent("Project")
    try write("nested", to: source.appendingPathComponent("子目录/a.txt"))
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let before = try FileSafety.stamp(source)
    let destination = project.appendingPathComponent("素材包")
    try FileSafety.move(source: source, destination: destination, project: project, expected: before)
    #expect(try FileSafety.stamp(destination) == before)
    try write("changed", to: destination.appendingPathComponent("子目录/a.txt"))
    #expect(try FileSafety.stamp(destination) != before)
}

@Test func partialDownloadsAndSymlinksAreBlocked() throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("download.crdownload")
    try write("partial", to: source)
    #expect(FileSafety.availability(source) != nil)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    #expect(throws: (any Error).self) { try FileSafety.stamp(link) }
}

@Test func permissionAndCrossVolumeChecksDoNotMutate() throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("a.txt"), project = root.appendingPathComponent("ReadOnly")
    try write("safe", to: source)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: project.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.path) }
    #expect(throws: (any Error).self) {
        try FileSafety.validateDestination(source: source, destination: project.appendingPathComponent("a.txt"), project: project)
    }
    let otherVolume = URL(fileURLWithPath: "/dev")
    #expect(try FileSafety.metadata(source).st_dev != FileSafety.metadata(otherVolume).st_dev)
    #expect(throws: (any Error).self) {
        try FileSafety.validateDestination(source: source, destination: otherVolume.appendingPathComponent("never-created"), project: otherVolume)
    }
    #expect(FileSafety.exists(source))
}

@Test @MainActor func interruptedAmbiguousMovePreservesBothCopies() async throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("a.txt"), project = root.appendingPathComponent("Project")
    let destination = project.appendingPathComponent("a.txt")
    try write("source", to: source); try write("unrelated", to: destination)
    let db = try OrganizerDatabase(inMemory: true)
    let record = MoveRecord(plan: MovePlan(source: source, destination: destination, project: project,
        stamp: try FileSafety.stamp(source), problem: nil), batchID: UUID())
    db.context.insert(record); try db.save()
    try await ArchiveService(database: db).recover()
    #expect(record.status == "review")
    #expect(try String(contentsOf: source, encoding: .utf8) == "source")
    #expect(try String(contentsOf: destination, encoding: .utf8) == "unrelated")
}

@Test @MainActor func partialBatchNeverRetriesSuccessfulItems() async throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("Project")
    let first = root.appendingPathComponent("a.txt"), second = root.appendingPathComponent("b.txt")
    try write("a", to: first); try write("b", to: second)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let plans = try [first, second].map {
        MovePlan(source: $0, destination: project.appendingPathComponent($0.lastPathComponent),
                 project: project, stamp: try FileSafety.stamp($0), problem: nil)
    }
    try write("changed", to: second)
    let db = try OrganizerDatabase(inMemory: true)
    let service = ArchiveService(database: db)
    _ = try await service.execute(plans)
    #expect(try db.history().filter { $0.status == "moved" }.count == 1)
    #expect(try db.history().filter { $0.status == "failed" }.count == 1)
    try await service.recover()
    #expect(!FileSafety.exists(first))
    #expect(try String(contentsOf: second, encoding: .utf8) == "changed")
}

@Test @MainActor func originalDatabaseRemainsWritableAfterSecondaryReaderCloses() throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("database.store")
    let db = try OrganizerDatabase(url: url)
    do {
        let reader = try OrganizerDatabase(url: url)
        #expect(reader.preferences.days == 7)
    }
    db.context.insert(Observation(identity: "new-after-reader", path: "/sample", now: .now))
    try db.save()
    #expect(try db.observations().count == 1)
    let reader = try OrganizerDatabase(url: url)
    db.context.insert(Observation(identity: "later", path: "/sample2", now: .now))
    try db.save()
    reader.preferences.days = 15
    try reader.save()
    #expect(try db.observations().count == 2)
    #expect(db.preferences.days == 15)
}

@Test func dueMarkerUsesObservedTimeAndExactBoundary() {
    let first = Date(timeIntervalSince1970: 1000)
    let item = DesktopItem(id: "1", url: URL(fileURLWithPath: "/sample"), category: .other,
                           firstSeen: first, changedAt: .distantPast, unavailableReason: nil)
    #expect(!item.isDue(days: 7, now: first.addingTimeInterval(7 * 86400 - 1)))
    #expect(item.isDue(days: 7, now: first.addingTimeInterval(7 * 86400)))
}

@Test @MainActor func samePlanCannotBeExecutedTwice() async throws {
    let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("a.txt"), project = root.appendingPathComponent("Project")
    try write("original", to: source)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let plan = MovePlan(source: source, destination: project.appendingPathComponent("a.txt"),
                       project: project, stamp: try FileSafety.stamp(source), problem: nil)
    let db = try OrganizerDatabase(inMemory: true), service = ArchiveService(database: db)
    _ = try await service.execute([plan])
    await #expect(throws: (any Error).self) { _ = try await service.execute([plan]) }
    #expect(try db.history().count == 1)
    #expect(try db.history().first?.status == "moved")
}
