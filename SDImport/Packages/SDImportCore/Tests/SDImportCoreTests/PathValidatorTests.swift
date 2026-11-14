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

    @Test("distinguishes permission denied from a missing folder")
    func reportsPermissionDeniedWhenParentCannotBeTraversed() throws {
        let root = try temporaryDirectory()
        let parent = root.appendingPathComponent("Protected", isDirectory: true)
        let child = parent.appendingPathComponent("Media", isDirectory: true)
        let link = root.appendingPathComponent("Card")
        let danglingLink = root.appendingPathComponent("Dangling")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: child, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: child)
        try fileManager.createSymbolicLink(at: danglingLink, withDestinationURL: root.appendingPathComponent("Absent"))
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: parent.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }

        let validator = PathValidator()
        let source = validator.validate(path: child.path, purpose: .source)
        let destination = validator.validate(path: child.path, purpose: .destination)

        #expect(source.status == .unreadable)
        #expect(destination.status == .unwritable)
        #expect(AppDistribution.macAppStore.requiresSourceAccess(for: source.status, hasAuthorizedAccess: false))
        #expect(validator.validate(path: link.path, purpose: .source).status == .unreadable)
        #expect(validator.validate(path: link.path, purpose: .destination).status == .unwritable)
        #expect(validator.validate(path: danglingLink.path, purpose: .source).status == .missing)
    }

    @Test("the selected directory must allow traversal")
    func rejectsSelectedDirectoryWithoutSearchPermission() throws {
        let root = try temporaryDirectory()
        let fileManager = FileManager.default
        try Data([1]).write(to: root.appendingPathComponent("IMG.JPG"))
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }

        let validator = PathValidator()
        #expect(validator.validate(path: root.path, purpose: .source).status == .unreadable)
        #expect(validator.validate(path: root.path, purpose: .destination).status == .unwritable)
        #expect(throws: (any Error).self) { try FileEnumerator().mediaCandidateFiles(in: root) }
    }

    @Test("reports volumes root as a placeholder source")
    func reportsVolumesRootAsPlaceholderSource() {
        let result = PathValidator().validate(path: "/Volumes", purpose: .source)

        #expect(result.status == .placeholder)
        #expect(result.isUsable == false)
        #expect(result.message == "Choose a specific card or source folder")
    }

    @Test("reports missing destination folders")
    func reportsMissingDestinationFolder() {
        let missingPath = "/tmp/SDImportCoreTests-missing-\(UUID().uuidString)"

        let result = PathValidator().validate(path: missingPath, purpose: .destination)

        #expect(result.status == .missing)
        #expect(result.isUsable == false)
        #expect(result.message == "Folder does not exist")
    }

    @Test("validates directories with trailing spaces in the folder name")
    func validatesDirectoryWithTrailingSpaceInName() throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("maylasia ", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let result = PathValidator().validate(path: destination.path, purpose: .destination)

        #expect(result.status == .ready)
        #expect(result.expandedPath == destination.path)
    }

    @Test("resolves missing paths to unambiguous trailing-space folder names")
    func resolvesMissingPathToTrailingSpaceFolderName() throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("maylasia ", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let visiblePath = directory.appendingPathComponent("maylasia", isDirectory: true).path

        let result = PathValidator().validate(path: visiblePath, purpose: .destination)

        #expect(result.status == .ready)
        #expect(result.expandedPath == destination.path)
    }

    @Test("does not resolve ambiguous whitespace-only folder name matches")
    func doesNotResolveAmbiguousWhitespaceFolderNameMatches() throws {
        let directory = try temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("trip ", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(" trip", isDirectory: true),
            withIntermediateDirectories: true
        )

        let result = PathValidator().validate(
            path: directory.appendingPathComponent("trip", isDirectory: true).path,
            purpose: .destination
        )

        #expect(result.status == .missing)
    }

    @Test("falls back to trimmed paths when the exact path is missing")
    func fallsBackToTrimmedPathWhenExactPathIsMissing() throws {
        let directory = try temporaryDirectory()
        let paddedPath = " \(directory.path) "

        let result = PathValidator().validate(path: paddedPath, purpose: .destination)

        #expect(result.status == .ready)
        #expect(result.expandedPath == directory.path)
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

    @Test("stored paths can require the original folder name")
    func storedPathsDoNotUseWhitespaceFallback() throws {
        let root = try temporaryDirectory()
        let replacement = root.appendingPathComponent("Card", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("Card ", isDirectory: true)
        let validator = PathValidator()
        #expect(validator.validate(path: original.path, purpose: .source).expandedPath == replacement.path)
        #expect(validator.validate(path: original.path, purpose: .source, allowsWhitespaceFallback: false).status == .missing)
    }

    @Test("expands tilde before validation")
    func expandsTildeBeforeValidation() {
        let result = PathValidator().validate(path: "~", purpose: .destination)

        #expect(result.expandedPath == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(result.status == .ready)
    }
}
