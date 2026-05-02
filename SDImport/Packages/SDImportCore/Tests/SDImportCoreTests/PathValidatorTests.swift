import Foundation
import Testing

@testable import SDImportCore

@Suite("Path validation")
struct PathValidatorTests {
    @Test("validates existing source directories")
    func validatesExistingSourceDirectory() throws {
        let directory = try temporaryDirectory()

        let result = PathValidator().validate(path: directory.path, purpose: .source)

        #expect(result.status == .ready)
        #expect(result.isUsable)
        #expect(result.message == "Ready")
    }

    @Test("reports missing source folders as unmounted cards")
    func reportsMissingSourceFolder() {
        let missingPath = "/tmp/SDImportCoreTests-missing-\(UUID().uuidString)"

        let result = PathValidator().validate(path: missingPath, purpose: .source)

        #expect(result.status == .missing)
        #expect(result.isUsable == false)
        #expect(result.message == "Card is not mounted")
    }

    @Test("reports missing destination folders")
    func reportsMissingDestinationFolder() {
        let missingPath = "/tmp/SDImportCoreTests-missing-\(UUID().uuidString)"

        let result = PathValidator().validate(path: missingPath, purpose: .destination)

        #expect(result.status == .missing)
        #expect(result.isUsable == false)
        #expect(result.message == "Folder does not exist")
    }

    @Test("reports plain files as invalid folders")
    func reportsPlainFilesAsInvalidFolders() throws {
        let directory = try temporaryDirectory()
        let fileURL = directory.appendingPathComponent("not-a-folder.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let result = PathValidator().validate(path: fileURL.path, purpose: .source)

        #expect(result.status == .notDirectory)
        #expect(result.isUsable == false)
        #expect(result.message == "Not a folder")
    }

    @Test("expands tilde before validation")
    func expandsTildeBeforeValidation() {
        let result = PathValidator().validate(path: "~", purpose: .destination)

        #expect(result.expandedPath == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(result.status == .ready)
    }
}
