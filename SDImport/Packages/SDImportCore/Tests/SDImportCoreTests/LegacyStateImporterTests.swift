import Foundation
import Testing

@testable import SDImportCore

@Suite("LegacyStateImporter")
struct LegacyStateImporterTests {
    @Test("detects legacy state without modifying it")
    func detectsLegacyStateWithoutModifyingIt() throws {
        let homeURL = try temporaryDirectory()
        let legacyDirectory = homeURL.appendingPathComponent(".sd-import", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )

        let legacyDatabase = legacyDirectory.appendingPathComponent("state.db")
        try Data("legacy".utf8).write(to: legacyDatabase)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: legacyDatabase.path)

        let location = LegacyStateImporter.defaultLegacyLocation(homeDirectory: homeURL)
        let importer = LegacyStateImporter(
            legacyLocation: location,
            nativeStateDirectory: homeURL.appendingPathComponent("Library/Application Support/SD Import", isDirectory: true)
        )

        #expect(importer.canImportLegacyState())
        #expect(location.databaseURL == legacyDatabase)

        let afterAttributes = try FileManager.default.attributesOfItem(atPath: legacyDatabase.path)
        #expect(originalAttributes[.size] as? Int == afterAttributes[.size] as? Int)
        #expect(try Data(contentsOf: legacyDatabase) == Data("legacy".utf8))
    }
}
