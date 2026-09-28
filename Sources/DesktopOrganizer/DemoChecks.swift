import Foundation
import OrganizerCore
import OrganizerStore

extension AppModel {
    func runDemoChecks() async {
        guard let demoRoot, let desktop,
              FileSafety.contains(demoRoot, desktop), let project = projectURL else { return }
        var checks: [String: Bool] = [:]
        do {
            checks["indexedDemoFiles"] = items.count >= 7
            let firstSeen = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.firstSeen) })
            await refresh()
            checks["firstSeenStable"] = items.allSatisfy { firstSeen[$0.id] == $0.firstSeen }
            if let folder = items.first(where: { $0.category == .folders }) {
                let stamp = try FileSafety.stamp(folder.url)
                await setFixed(true, items: [folder])
                checks["fixedFolderBoard"] = items.first { $0.id == folder.id }?.board == .fixedFolders
                checks["classificationDoesNotMove"] = try FileSafety.stamp(folder.url) == stamp
                let renamedFolder = folder.url.deletingLastPathComponent().appendingPathComponent("固定分类改名验证")
                try FileManager.default.moveItem(at: folder.url, to: renamedFolder)
                try Data("new child".utf8).write(to: renamedFolder.appendingPathComponent("分类新增验证.txt"))
                await refresh()
                checks["fixedSurvivesRenameAndNewChild"] = items.first { $0.id == folder.id }?.isFixedFolder == true
                try FileManager.default.removeItem(at: renamedFolder.appendingPathComponent("分类新增验证.txt"))
                try FileManager.default.moveItem(at: renamedFolder, to: folder.url)
                await refresh()
                await setFixed(false, items: [folder])
                checks["temporaryFolderBoard"] = items.first { $0.id == folder.id }?.board == .folders
            }
            let incoming = desktop.appendingPathComponent("新增观察测试-\(UUID()).txt")
            try Data("watcher fixture".utf8).write(to: incoming)
            try await Task.sleep(for: .seconds(2))
            checks["fileEventRefresh"] = items.contains { $0.url == incoming }
            let renamed = incoming.deletingLastPathComponent().appendingPathComponent("改名观察测试-\(UUID()).txt")
            try FileManager.default.moveItem(at: incoming, to: renamed)
            try await Task.sleep(for: .seconds(2))
            checks["renameRefresh"] = items.contains { $0.url == renamed } && !items.contains { $0.url == incoming }
            try FileManager.default.removeItem(at: renamed)
            try await Task.sleep(for: .seconds(2))
            checks["removalRefresh"] = !items.contains { $0.url == renamed }
            let moving = items.filter { [.images, .pdf, .folders].contains($0.category) }
            selected = Set(moving.map(\.id)); targetProject = project.path; byCategory = true
            await prepare()
            checks["preflightReady"] = !plans.isEmpty && plans.allSatisfy(\.canMove)
            guard checks["preflightReady"] == true else { throw OrganizerError.unsafe("示例预检未全部通过") }
            let prepared = plans
            let batch = try await archives.execute(prepared)
            reloadHistory(); await refresh()
            let entries = history.filter { $0.batchID == batch }
            checks["batchMoved"] = entries.count == moving.count && entries.allSatisfy { $0.status == "moved" }
            checks["originalPathsGone"] = prepared.allSatisfy { !FileSafety.exists($0.source) }
            for record in entries { try await archives.undo(record) }
            reloadHistory(); await refresh()
            checks["undoRestored"] = entries.allSatisfy { $0.status == "undone" }
                && prepared.allSatisfy { FileSafety.exists($0.source) && !FileSafety.exists($0.destination) }
            let reopened = try OrganizerDatabase(url: demoRoot.appendingPathComponent("AppData/Organizer.store"))
            checks["diskJournalReopened"] = try reopened.history().filter { $0.batchID == batch }.allSatisfy { $0.status == "undone" }
            selected = Set(items.filter { [.images, .pdf, .folders].contains($0.category) }.map(\.id))
            await prepare()
            let secondBatch = try await archives.execute(plans)
            reloadHistory()
            let secondEntries = history.filter { $0.batchID == secondBatch }
            checks["repeatedBatchMoved"] = secondEntries.count == moving.count && secondEntries.allSatisfy { $0.status == "moved" }
            for record in secondEntries { try await archives.undo(record) }
            checks["repeatedBatchUndone"] = secondEntries.allSatisfy { $0.status == "undone" }
            await refresh()
            selected = Set(items.filter { [.images, .pdf, .folders].contains($0.category) }.map(\.id))
            await prepare()
            tab = "archive"
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: demoRoot.appendingPathComponent("AppData/qa-result.json"), options: .atomic)
        } catch {
            let report: [String: Any] = ["passed": false, "checks": checks, "error": error.localizedDescription]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: demoRoot.appendingPathComponent("AppData/qa-result.json"), options: .atomic)
            message = "示例目录验证未通过：\(error.localizedDescription)"
        }
    }
}
