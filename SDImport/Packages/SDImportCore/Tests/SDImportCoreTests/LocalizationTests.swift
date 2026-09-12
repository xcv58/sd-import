import Foundation
import Testing
@testable import SDImportCore

struct LocalizationTests {
    static let settings = [
        "en": "Settings", "zh-Hans": "设置", "zh-Hant": "設定",
        "ja": "設定", "ko": "설정", "de": "Einstellungen",
        "fr": "Réglages", "es": "Ajustes", "pt-BR": "Ajustes", "it": "Impostazioni"
    ]

    @Test(arguments: L10n.supportedLanguages)
    func languageResources(language: String) throws {
        #expect(L10n.tr("Settings", language: language) == Self.settings[language])
        let englishURL = try #require(L10n.resourceBundle.url(forResource: "en", withExtension: "lproj"))
        let localeURL = try #require(L10n.resourceBundle.url(forResource: language, withExtension: "lproj"))
        let english = try strings(at: englishURL)
        let translated = try strings(at: localeURL)
        #expect(!english.isEmpty)
        #expect(Set(english.keys) == Set(translated.keys))
        #expect(translated.values.allSatisfy { !$0.isEmpty })
    }

    @Test(arguments: [
        ("es-MX", "Ajustes"), ("fr-CA", "Réglages"), ("de-AT", "Einstellungen"),
        ("pt-PT", "Settings"), ("zh-CN", "设置"), ("zh-TW", "設定"),
        ("zh-HK", "設定"), ("nl-NL", "Settings"), ("ar", "Settings")
    ])
    func regionalPreferences(preference: String, expected: String) {
        #expect(L10n.tr("Settings", language: preference) == expected)
    }

    @Test(arguments: L10n.supportedLanguages)
    func interpolationPreservesValues(language: String) {
        let path = "/example/100% 家族/RAW %@.jpg"
        let detail = "Example error — 50%"
        let message = L10n.tr("Could not access \(path): \(detail)", language: language)
        #expect(message.contains(path))
        #expect(message.contains(detail))
        #expect(!message.contains("%1$@"))

        let free = "FREE_SENTINEL", used = "USED_SENTINEL", total = "TOTAL_SENTINEL"
        let capacity = L10n.tr("\(free) free, \(used) used of \(total)", language: language)
        for value in [free, used, total] { #expect(capacity.contains(value)) }
        if language == "ko" {
            #expect(capacity.range(of: total)!.lowerBound < capacity.range(of: used)!.lowerBound)
        }
    }

    @Test
    func nativePluralRules() {
        let one = 1, two = 2, zero = 0
        #expect(L10n.tr("\(one) files", language: "en") == "1 file")
        #expect(L10n.tr("\(two) files", language: "en") == "2 files")
        #expect(L10n.tr("\(one) files", language: "de") == "1 Datei")
        #expect(L10n.tr("\(two) files", language: "de") == "2 Dateien")
        #expect(L10n.tr("\(zero) files", language: "fr") == "0 fichier")
        #expect(L10n.tr("\(two) files", language: "fr") == "2 fichiers")
        #expect(L10n.tr("\(two) files", language: "ja") == "2 ファイル")
        #expect(L10n.tr("Import \(one) Files", language: "es") == "Importar 1 archivo")
        #expect(L10n.tr("\(one) days", language: "de") == "1 Tag")
        #expect(L10n.tr("\(one) photos", language: "fr") == "1 photo")
        #expect(L10n.tr("\(one) videos", language: "es") == "1 vídeo")
    }

    @Test
    func completeCountMessagesUsePluralRules() {
        let one = 1, two = 2
        #expect(L10n.tr("Scan complete. \(one) files were imported on another Mac", language: "en") == "Scan complete. 1 file was imported on another Mac")
        #expect(L10n.tr("Scan complete. \(two) files were imported on another Mac", language: "en") == "Scan complete. 2 files were imported on another Mac")
        #expect(L10n.tr("Scan complete. \(one) files were imported on another Mac", language: "de") == "Scan abgeschlossen. 1 Datei wurde auf einem anderen Mac importiert")
        #expect(L10n.tr("Scan complete. \(two) files were imported on another Mac", language: "de") == "Scan abgeschlossen. 2 Dateien wurden auf einem anderen Mac importiert")
        #expect(L10n.tr("Scan complete. \(one) files were imported on another Mac", language: "fr") == "Analyse terminée. 1 fichier a été importé sur un autre Mac")
        #expect(L10n.tr("Scan complete. \(two) files were imported on another Mac", language: "fr") == "Analyse terminée. 2 fichiers ont été importés sur un autre Mac")
        #expect(L10n.tr("\(one) old jobs would be deleted", language: "en") == "1 old job would be deleted")
        #expect(L10n.tr("Deleted \(one) old jobs", language: "en") == "Deleted 1 old job")
        #expect(L10n.tr("Portable receipt overridden for \(one) files", language: "en") == "Portable receipt overridden for 1 file")
        #expect(L10n.tr("Video + \(one) sidecars", language: "en") == "Video + 1 sidecar")
    }

    @Test
    func storedStatusCodes() {
        #expect(L10n.storedMessage("unsupported") == L10n.tr("Unsupported"))
        #expect(L10n.storedMessage("excluded_by_import_selection") == L10n.tr("Excluded"))
        #expect(L10n.storedMessage("no_destination") == L10n.tr("No destination"))
        #expect(L10n.storedMessage("already_exists_same_fingerprint") == L10n.tr("Already exists"))
        #expect(L10n.storedMessage("already_imported_fingerprint") == L10n.tr("Already imported"))
        #expect(L10n.storedMessage("already_imported_portable_receipt") == L10n.tr("Imported on another Mac"))
        #expect(L10n.storedMessage("cancelled") == L10n.tr("Cancelled"))
    }

    @Test
    func cocoaAndCustomErrorsUseUserFacingDescriptions() {
        let cocoaError: Error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoPermissionError,
            userInfo: [NSLocalizedDescriptionKey: "Zugriff auf /synthetic/100% Foto.jpg verweigert"]
        )
        #expect(L10n.errorMessage(for: cocoaError) == "Zugriff auf /synthetic/100% Foto.jpg verweigert")
        #expect(L10n.errorMessage(for: CustomError()) == "Custom localized failure")
    }

    @Test
    func helperRecordsStayStableAndTranslateAtDisplay() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BackgroundPromptAgentStateStore(fileURL: directory.appendingPathComponent("agent-state.json"))
        try store.recordLaunch(agentBuild: "test", agentBundlePath: "/synthetic/Agent.app")
        let messages = [
            "Could not locate the containing SD Import application",
            "Could not persist a mounted-card event",
            "Could not launch the containing SD Import application",
            "Could not mark the helper runtime QA lifecycle as active",
            "Unknown helper error /synthetic/100% Foto.jpg"
        ]
        for message in messages {
            try store.recordError(agentBuild: "test", agentBundlePath: "/synthetic/Agent.app", message: message)
            let state = try #require(try store.load())
            #expect(state.lastError == message)
            #expect(BackgroundPromptHealth.effectiveError(appError: nil, agentState: state) == L10n.storedMessage(message))
            #expect(BackgroundPromptHealth.effectiveError(appError: "App error", agentState: state) == "App error")
        }
    }

    @Test
    func typedErrorsUseLocalizedDescriptions() {
        let setupError: Error = SDImportError.missingApplicationSupportDirectory
        #expect(setupError.localizedDescription == L10n.tr("The application support folder is unavailable."))
        let expected: Int64 = 12, actual: Int64 = 4
        let copyError: Error = SDImportError.copySizeMismatch(expected: expected, actual: actual)
        #expect(copyError.localizedDescription == L10n.tr("Copy verification failed: expected \(expected) bytes, found \(actual) bytes."))
    }

    @Test
    func fallbackAndHistoricalText() {
        #expect(L10n.tr("A newly added message", language: "ja") == "A newly added message")
        let file = "/example/Untitled/Photos/100% RAW.jpg"
        #expect(L10n.storedMessage(file) == file)
        #expect(L10n.storedMessage("An unknown historic error") == "An unknown historic error")
        #expect(L10n.storedMessage("source file missing") == L10n.tr("Source file missing"))
        #expect(SDImportError.sourceFileMissing(URL(fileURLWithPath: file)).localizedDescription.contains(file))
    }

    private func strings(at folder: URL) throws -> [String: String] {
        let data = try Data(contentsOf: folder.appendingPathComponent("Localizable.strings"))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    private struct CustomError: LocalizedError {
        var errorDescription: String? { "Custom localized failure" }
    }
}
