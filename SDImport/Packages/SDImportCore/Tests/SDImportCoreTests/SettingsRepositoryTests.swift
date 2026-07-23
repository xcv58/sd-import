import Foundation
import GRDB
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
            ejectAfterSuccessfulImport: true,
            hasCompletedOnboarding: true,
            lastWorkflowProfile: .footageBackup,
            lastMediaSelection: .videosOnly,
            lastDestinationLayout: .footageBackup,
            preferredMixedDestinationLayout: .separateMediaFolders,
            lastFolderGrouping: .oneShootFolder,
            themePreference: .dark,
            workflowProfilesByVolume: [
                "uuid:card": .photoImport
            ],
            hiddenRecentPaths: [
                "/Volumes/Old Card"
            ]
        )

        try repository.saveConfiguration(configuration)

        #expect(try repository.fetchConfiguration() == configuration)
    }

    @Test("decodes older app configuration without workflow fields")
    func decodesOlderConfigurationWithoutWorkflowFields() throws {
        let json = """
        {
          "sourcePath": "/Volumes/CARD",
          "photosPath": "/Users/example/Pictures",
          "videosPath": "/Users/example/Movies",
          "defaultLocation": "Gardens",
          "autoPromptEnabled": true,
          "hasCompletedOnboarding": true
        }
        """

        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))

        #expect(configuration.lastWorkflowProfile == .mixedShootSession)
        #expect(configuration.ejectAfterSuccessfulImport == false)
        #expect(configuration.lastMediaSelection == .photosAndVideos)
        #expect(configuration.lastDestinationLayout == .singleLibrary)
        #expect(configuration.preferredMixedDestinationLayout == .singleLibrary)
        #expect(configuration.lastFolderGrouping == .byDay)
        #expect(configuration.themePreference == .system)
        #expect(configuration.workflowProfilesByVolume.isEmpty)
        #expect(configuration.hiddenRecentPaths.isEmpty)
    }

    @Test("decodes preferred mixed destination from last non-video layout")
    func decodesPreferredMixedDestinationFromLastNonVideoLayout() throws {
        let json = """
        {
          "sourcePath": "/Volumes/CARD",
          "photosPath": "/Users/example/Pictures",
          "videosPath": "/Users/example/Movies",
          "defaultLocation": "Gardens",
          "lastWorkflowProfile": "photoImport",
          "lastMediaSelection": "photosOnly",
          "lastDestinationLayout": "separateMediaFolders"
        }
        """

        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))

        #expect(configuration.preferredMixedDestinationLayout == .separateMediaFolders)
    }

    @Test("does not use footage backup as the preferred mixed destination")
    func doesNotUseFootageBackupAsPreferredMixedDestination() throws {
        let json = """
        {
          "sourcePath": "/Volumes/CARD",
          "photosPath": "/Users/example/Pictures",
          "videosPath": "/Users/example/Movies",
          "defaultLocation": "Gardens",
          "lastWorkflowProfile": "footageBackup",
          "lastMediaSelection": "videosOnly",
          "lastDestinationLayout": "footageBackup",
          "preferredMixedDestinationLayout": "footageBackup"
        }
        """

        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))

        #expect(configuration.preferredMixedDestinationLayout == .singleLibrary)
    }

    @Test("maps legacy organization presets to destination layouts")
    func mapsLegacyOrganizationPresetsToDestinationLayouts() {
        #expect(ImportDestinationLayout(organizationPreset: .classicDatedFolders) == .separateMediaFolders)
        #expect(ImportDestinationLayout(organizationPreset: .shootSessionsByDate) == .singleLibrary)
        #expect(ImportDestinationLayout(organizationPreset: .footageBackup) == .footageBackup)

        #expect(ImportDestinationLayout.separateMediaFolders.organizationPreset == .classicDatedFolders)
        #expect(ImportDestinationLayout.singleLibrary.organizationPreset == .shootSessionsByDate)
        #expect(ImportDestinationLayout.footageBackup.organizationPreset == .footageBackup)
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

    @Test("falls back when a folder bookmark cannot resolve")
    func fallsBackWhenFolderBookmarkCannotResolve() throws {
        let pool = try migratedPool()
        let store = BookmarkStore(pool: pool)
        let fallback = "/Volumes/Untitled"

        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO bookmarks (id, purpose, bookmark_data, url, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    BookmarkPurpose.source.rawValue,
                    BookmarkPurpose.source.rawValue,
                    Data([0x00]),
                    "/Volumes/Missing",
                    DateCoding.string(from: Date())
                ]
            )
        }

        #expect(store.resolvedPath(purpose: .source, fallback: fallback) == fallback)
    }
}
