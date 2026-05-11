import Foundation
import Testing

@testable import SDImportCore

@Suite("CrashReportLocator")
struct CrashReportLocatorTests {
    @Test("finds recent SD Import crash reports without matching unrelated files")
    func findsRecentSDImportCrashReports() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let older = directory.appendingPathComponent("SD Import_2026-05-10-120000.crash")
        let newer = directory.appendingPathComponent("com.xcv58.SDImport_2026-05-11-130000.ips")
        let unrelated = directory.appendingPathComponent("Other App_2026-05-11.crash")
        let wrongExtension = directory.appendingPathComponent("SD Import_2026-05-11.txt")

        try "older crash".write(to: older, atomically: true, encoding: .utf8)
        try "newer crash".write(to: newer, atomically: true, encoding: .utf8)
        try "other crash".write(to: unrelated, atomically: true, encoding: .utf8)
        try "not a crash".write(to: wrongExtension, atomically: true, encoding: .utf8)

        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: older.path
        )
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: newer.path
        )

        let reports = CrashReportLocator.findReports(in: directory, fileManager: fileManager)

        #expect(reports.map { $0.url.lastPathComponent } == [
            newer.lastPathComponent,
            older.lastPathComponent
        ])
        #expect(reports.allSatisfy { $0.byteCount > 0 })
    }

    @Test("default directory points at macOS diagnostic reports folder")
    func defaultDirectoryPointsAtDiagnosticReports() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        #expect(
            CrashReportLocator.defaultDirectory(homeDirectory: home).path
                == "/Users/tester/Library/Logs/DiagnosticReports"
        )
    }
}
