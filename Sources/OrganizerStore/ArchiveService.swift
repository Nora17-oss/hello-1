import Foundation
import OrganizerCore

@MainActor
public final class ArchiveService {
    private let database: OrganizerDatabase
    public init(database: OrganizerDatabase) { self.database = database }

    public func execute(_ plans: [MovePlan]) async throws -> UUID {
        let recorded = Set(try database.history().map(\.id))
        guard Set(plans.map(\.id)).count == plans.count,
              plans.allSatisfy({ !recorded.contains($0.id) }) else {
            throw OrganizerError.unsafe("该投递计划已登记，请重新预检；未重复执行")
        }
        let batch = UUID()
        let records = plans.map { MoveRecord(plan: $0, batchID: batch) }
        for record in records { database.context.insert(record) }
        // No filesystem mutation is permitted until the whole intent log is durable.
        try database.save()
        for (plan, record) in zip(plans, records) where plan.canMove {
            guard let stamp = plan.stamp else { continue }
            let result: String? = await Task.detached {
                do {
                    try FileSafety.move(source: plan.source, destination: plan.destination, project: plan.project, expected: stamp)
                    guard try FileSafety.stamp(plan.destination) == stamp else { return "移动后内容发生变化，需要人工核对" }
                    return nil
                } catch { return error.localizedDescription }
            }.value
            if let result {
                record.status = FileSafety.exists(plan.source) && !FileSafety.exists(plan.destination) ? "failed" : "review"
                record.detail = result
            } else {
                record.status = "moved"; record.detail = ""
            }
            // If saving fails, stop the batch; persisted pending intents will be reconciled at startup.
            try database.save()
        }
        return batch
    }

    public func undo(_ record: MoveRecord) async throws {
        guard record.status == "moved" else { throw OrganizerError.unsafe("该记录当前不可撤销") }
        let source = URL(fileURLWithPath: record.source)
        let destination = URL(fileURLWithPath: record.destination)
        let expected = record.stamp
        guard !FileSafety.exists(source) else { throw OrganizerError.unsafe("原位置已有同名项，撤销不会覆盖它") }
        record.status = "undoPending"
        try database.save()
        let result: String? = await Task.detached {
            do {
                try FileSafety.move(source: destination, destination: source,
                                    project: source.deletingLastPathComponent(), expected: expected)
                guard try FileSafety.stamp(source) == expected else { return "撤销后内容变化，需要人工核对" }
                return nil
            } catch { return error.localizedDescription }
        }.value
        if let result {
            record.status = FileSafety.exists(destination) && !FileSafety.exists(source) ? "moved" : "review"
            record.detail = "撤销未完成：\(result)"
        } else { record.status = "undone"; record.detail = "" }
        try database.save()
    }

    public func recover() async throws {
        for record in try database.history() where ["pending", "undoPending"].contains(record.status) {
            let undoing = record.status == "undoPending"
            let src = URL(fileURLWithPath: undoing ? record.destination : record.source)
            let dst = URL(fileURLWithPath: undoing ? record.source : record.destination)
            let expected = record.stamp
            let status = await Task.detached { () -> Int in
                if !FileSafety.exists(src), let actual = try? FileSafety.stamp(dst), actual == expected { return 1 }
                if !FileSafety.exists(dst), let actual = try? FileSafety.stamp(src), actual == expected { return 0 }
                return -1
            }.value
            switch status {
            case 1: record.status = undoing ? "undone" : "moved"; record.detail = "已核对中断前的操作"
            case 0: record.status = undoing ? "moved" : "failed"; record.detail = "操作未执行，未自动重试"
            default: record.status = "review"; record.detail = "状态不明确，请核对源与目标；未删除任何文件"
            }
            try database.save()
        }
    }
}
