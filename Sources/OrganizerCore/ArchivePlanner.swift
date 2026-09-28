import Foundation

public enum ArchivePlanner {
    public static func prepare(items: [DesktopItem], project: URL, specifiedFolder: URL?,
                               conflict: ConflictPolicy, stabilityDelay: UInt64 = 2_000_000_000) async -> [MovePlan] {
        var baseline: [String: FileStamp] = [:]
        var failures: [String: String] = [:]
        for item in items {
            do {
                if item.isFixedFolder { throw OrganizerError.unsafe("固定文件夹不参与投递，请先改为临时文件夹") }
                if let reason = item.unavailableReason { throw OrganizerError.unsafe(reason) }
                baseline[item.id] = try FileSafety.stamp(item.url)
            } catch { failures[item.id] = error.localizedDescription }
        }
        do { try await Task.sleep(nanoseconds: stabilityDelay) }
        catch { return [] }
        var reserved = Set<String>()
        return items.map { item in
            let folder = specifiedFolder ?? project.appendingPathComponent(item.category.title, isDirectory: true)
            var destination = folder.appendingPathComponent(item.name)
            do {
                if let reason = failures[item.id] { throw OrganizerError.unsafe(reason) }
                let current = try FileSafety.stamp(item.url)
                guard baseline[item.id] == current else { throw OrganizerError.unsafe("文件正在变化，请稍后再试") }
                if conflict == .keepBoth { destination = FileSafety.availableName(destination, reserved: reserved) }
                guard !FileSafety.exists(destination), !reserved.contains(destination.path) else {
                    throw OrganizerError.unsafe("同名项已存在，将跳过")
                }
                try FileSafety.validateDestination(source: item.url, destination: destination, project: project)
                reserved.insert(destination.path)
                return MovePlan(source: item.url, destination: destination, project: project, stamp: current, problem: nil)
            } catch {
                return MovePlan(source: item.url, destination: destination, project: project,
                                stamp: nil, problem: error.localizedDescription)
            }
        }
    }
}
