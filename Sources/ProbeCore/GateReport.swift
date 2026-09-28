import Foundation

public enum Scenario: String, Codable, CaseIterable, Sendable {
    case behindApplications
    case showDesktop
    case switchSpaces
    case sleepWake
    case fileOpen
    case screenChange
    case iconSettingsRestore

    public var title: String {
        switch self {
        case .behindApplications: "普通应用可遮挡看板"
        case .showDesktop: "显示桌面后看板可见、可点击"
        case .switchSpaces: "切换桌面空间后看板可见"
        case .sleepWake: "休眠唤醒后看板正常"
        case .fileOpen: "文件双击打开正常"
        case .screenChange: "显示器或分辨率变化后位置正常"
        case .iconSettingsRestore: "系统图标隐藏及恢复正常"
        }
    }
}

public enum Verdict: String, Codable, CaseIterable, Sendable {
    case pending, passed, failed
    public var title: String {
        switch self {
        case .pending: "未验证"
        case .passed: "通过"
        case .failed: "失败"
        }
    }
}

public struct GateReport: Codable, Sendable {
    public var schemaVersion = 1
    public var updatedAt = Date()
    public var systemVersion: String
    public var automaticChecks: [String: Bool] = [:]
    public var scenarios: [String: Verdict] = [:]
    public var events: [String] = []
    public var notes = ""

    public init(systemVersion: String) {
        self.systemVersion = systemVersion
    }

    public var gatePassed: Bool {
        !automaticChecks.isEmpty
            && automaticChecks.values.allSatisfy { $0 }
            && Scenario.allCases.allSatisfy { scenarios[$0.rawValue] == .passed }
    }

    public mutating func record(_ event: String, at date: Date = Date()) {
        updatedAt = date
        events.append("\(date.ISO8601Format()) \(event)")
        events = Array(events.suffix(200))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
