import Foundation
import Testing

@testable import SDImportCore

@Suite("SettingsRepository and BookmarkStore")
struct SettingsRepositoryTests {
    @Test("stores and fetches app configuration")
    func storesAndFetchesAppConfiguration() throws {
        let pool = try migratedPool()
        let repository = SettingsRepository(pool: pool)
        let configuration = AppConfiguration(
            sourcePath: "/Volumes/CARD",
            photosPath: "/Users/example/Pictures",
            videosPath: "/Users/example/Movies",
            defaultLocation: "Gardens",
            historyRetention: .days(365),
            autoPromptEnabled: true,
            hasCompletedOnboarding: true
        )

        try repository.saveConfiguration(configuration)

        #expect(try repository.fetchConfiguration() == configuration)
    }

    @Test("stores and resolves folder bookmarks")
    func storesAndResolvesFolderBookmarks() throws {
        let pool = try migratedPool()
        let store = BookmarkStore(pool: pool)
        let folderURL = try temporaryDirectory()

        try store.saveBookmark(purpose: .photos, url: folderURL)

        let maybeResolved = try store.resolveBookmark(purpose: .photos)
        let resolved = try #require(maybeResolved)
        #expect(resolved.purpose == .photos)
        #expect(resolved.url.standardizedFileURL.path == folderURL.standardizedFileURL.path)
        #expect(try store.storedPath(purpose: .photos) == folderURL.path)
    }
}
