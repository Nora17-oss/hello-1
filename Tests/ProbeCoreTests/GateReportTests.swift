import Foundation
import Testing
@testable import ProbeCore

@Test func newReportNeverPasses() {
    #expect(!GateReport(systemVersion: "test").gatePassed)
}

@Test func configurationAloneDoesNotPassVisualGate() {
    var report = GateReport(systemVersion: "test")
    report.automaticChecks = ["level": true]
    #expect(!report.gatePassed)
}

@Test func everyScenarioMustPass() {
    var report = GateReport(systemVersion: "test")
    report.automaticChecks = ["level": true]
    for scenario in Scenario.allCases { report.scenarios[scenario.rawValue] = .passed }
    #expect(report.gatePassed)
    report.scenarios[Scenario.sleepWake.rawValue] = .failed
    #expect(!report.gatePassed)
    report.scenarios[Scenario.sleepWake.rawValue] = .pending
    #expect(!report.gatePassed)
}

@Test func automaticFailureBlocksGate() {
    var report = GateReport(systemVersion: "test")
    for scenario in Scenario.allCases { report.scenarios[scenario.rawValue] = .passed }
    report.automaticChecks = ["level": false]
    #expect(!report.gatePassed)
}

@Test func reportRoundTripAndBoundedEvents() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("report.json")
    var report = GateReport(systemVersion: "test")
    for index in 0..<250 { report.record("event \(index)") }
    report.scenarios[Scenario.fileOpen.rawValue] = .passed
    try report.save(to: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(GateReport.self, from: Data(contentsOf: url))
    #expect(decoded.events.count == 200)
    #expect(decoded.scenarios[Scenario.fileOpen.rawValue] == .passed)
    #expect(!decoded.gatePassed)
}
