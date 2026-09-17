import Foundation
import Testing
@testable import SDImportCore

struct LocalizationTests {
    static let settings = [
        "en": "Settings", "zh-Hans": "设置", "zh-Hant": "設定",
        "ja": "設定", "ko": "설정", "de": "Einstellungen",
        "fr": "Réglages", "es": "Ajustes", "pt-BR": "Ajustes", "it": "Impostazioni"
    ]

    @Test
    func languagePickerOptionsMatchShippedLanguages() {
        let choices = AppLanguage.allCases.filter { $0 != .system }
        #expect(Set(choices.map(\.rawValue)) == Set(L10n.supportedLanguages))
        #expect(choices.allSatisfy { !$0.displayName.isEmpty })
        #expect(AppLanguage(rawValue: "unsupported") == nil)
    }

    @Test
    func savedLanguageDefaultsAndInvalidValuesUseSystem() throws {
        let suite = "SDImport.LanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AppLanguage.saved(in: defaults) == .system)
        defaults.set(AppLanguage.japanese.rawValue, forKey: L10n.languagePreferenceKey)
        #expect(AppLanguage.saved(in: defaults) == .japanese)
        defaults.set("unsupported", forKey: L10n.languagePreferenceKey)
        #expect(AppLanguage.saved(in: defaults) == .system)
    }

    @Test
    func completedAppMessagesChangeLanguageWithoutRewritingExternalDetails() {
        let ready = L10n.tr("Ready", language: "en")
        let scan = L10n.tr("Scan complete", language: "en")
        let helperError = L10n.tr("Could not read background helper diagnostics", language: "en")
        let purchaseError = L10n.tr("The App Store returned an unknown purchase result.", language: "en")

        #expect(L10n.relocalizedStaticMessage(ready, from: .english, to: .french)
            == L10n.tr("Ready", language: "fr"))
        #expect(L10n.relocalizedStaticMessage(scan, from: .english, to: .simplifiedChinese)
            == L10n.tr("Scan complete", language: "zh-Hans"))
        #expect(L10n.relocalizedStaticMessage(helperError, from: .english, to: .german)
            == L10n.tr("Could not read background helper diagnostics", language: "de"))
        #expect(L10n.relocalizedStaticMessage(purchaseError, from: .english, to: .japanese)
            == L10n.tr("The App Store returned an unknown purchase result.", language: "ja"))
        #expect(L10n.relocalizedStaticMessage(scan, from: .system, to: .french,
            systemPreferences: ["en-US"]) == L10n.tr("Scan complete", language: "fr"))

        let externalError = "Access denied to /Users/example/100% RAW %@.jpg"
        #expect(L10n.relocalizedStaticMessage(externalError, from: .english, to: .french)
            == externalError)
    }

    @Test
    func retainedSettingsErrorRerendersAfterAnUnrelatedStatusChange() {
        var language = "en"
        let detail = "The destination is unavailable"
        let render = { L10n.tr("Could not save settings: \(detail)", language: language) }
        var feedback = RelocalizableMessage(render(), render: render)

        // Copy Diagnostics replaces the status while the Settings error remains visible.
        let currentStatus = L10n.tr("Diagnostics copied", language: language)
        #expect(feedback.text != currentStatus)

        language = "fr"
        feedback = feedback.relocalized(from: .english, to: .french)
        #expect(feedback.text == L10n.tr("Could not save settings: \(detail)", language: "fr"))
        #expect(feedback.text != currentStatus)

        language = "en"
        feedback = feedback.relocalized(from: .french, to: .english)
        #expect(feedback.text == L10n.tr("Could not save settings: \(detail)", language: "en"))
    }

    @Test
    func retainedHelperErrorRerendersItsWrapper() {
        var language = "en"
        let detail = "Unable to authorize com.example.helper"
        let render = { L10n.tr("Could not authorize the background helper: \(detail)", language: language) }
        var error = RelocalizableMessage(render(), render: render)

        language = "ja"
        error = error.relocalized(from: .english, to: .japanese)
        #expect(error.text == L10n.tr("Could not authorize the background helper: \(detail)", language: "ja"))

        language = "fr"
        error = error.relocalized(from: .japanese, to: .french)
        #expect(error.text == L10n.tr("Could not authorize the background helper: \(detail)", language: "fr"))
    }

    @Test
    func retainedSetupErrorRerendersAfterStatusChanges() {
        var language = "en"
        let render = { L10n.tr("The application support folder is unavailable.", language: language) }
        var error = RelocalizableMessage(render(), render: render)

        // Diagnostics keeps the setup failure visible even after another status replaces "Setup failed".
        let currentStatus = L10n.tr("Diagnostics copied", language: language)
        #expect(error.text != currentStatus)

        language = "fr"
        error = error.relocalized(from: .english, to: .french)
        #expect(error.text == L10n.tr("The application support folder is unavailable.", language: "fr"))

        language = "en"
        error = error.relocalized(from: .french, to: .english)
        #expect(error.text == L10n.tr("The application support folder is unavailable.", language: "en"))

        let opaqueError = RelocalizableMessage("External disk error 42")
        #expect(opaqueError.relocalized(from: .english, to: .french).text == opaqueError.text)
    }

    @Test @MainActor
    func helperPresentationRefreshesMessageAndRoleTogether() {
        final class State {
            var language = "en"
            var running = false
        }
        let state = State()
        let render: @MainActor () -> (message: String, isError: Bool) = {
            state.running
                ? (L10n.tr("The background helper is registered with macOS.", language: state.language), false)
                : (L10n.tr("The saved setting is on, but the background helper is not registered.", language: state.language), true)
        }

        var presentation = LivePresentation(render)
        #expect(presentation.value.isError)
        #expect(presentation.value.message == L10n.tr(
            "The saved setting is on, but the background helper is not registered.", language: "en"
        ))

        state.running = true
        presentation = presentation.refreshed()
        #expect(!presentation.value.isError)
        #expect(presentation.value.message == L10n.tr("The background helper is registered with macOS.", language: "en"))

        state.language = "fr"
        presentation = presentation.refreshed()
        #expect(!presentation.value.isError)
        #expect(presentation.value.message == L10n.tr("The background helper is registered with macOS.", language: "fr"))

        state.running = false
        state.language = "de"
        presentation = presentation.refreshed()
        #expect(presentation.value.isError)
        #expect(presentation.value.message == L10n.tr(
            "The saved setting is on, but the background helper is not registered.", language: "de"
        ))
    }

    @Test(arguments: L10n.supportedLanguages)
    func completedPortableWarningsRerenderInSelectedLanguage(language: String) {
        let count = 2
        let detail = "The file /synthetic/100% RAW %@.jpg could not be opened. Try again."
        let oldStatic = L10n.tr(
            "Portable import history was not updated because the source changed during import",
            language: "en"
        )
        let oldCount = L10n.tr("Ignored \(count) invalid or corrupted portable import records", language: "en")
        let oldLock = L10n.tr(
            "Portable import history cannot coordinate with other apps because this source does not support file locking",
            language: "en"
        )
        let oldDynamic = L10n.tr("Portable import history is unavailable: \(detail)", language: "en")

        #expect(L10n.portableReceiptWarning(oldStatic, language: language) == L10n.tr(
            "Portable import history was not updated because the source changed during import",
            language: language
        ))
        #expect(L10n.portableReceiptWarning("\(oldCount). \(oldLock)", language: language) == [
            L10n.tr("Ignored \(count) invalid or corrupted portable import records", language: language),
            L10n.tr(
                "Portable import history cannot coordinate with other apps because this source does not support file locking",
                language: language
            )
        ].joined(separator: ". "))
        #expect(L10n.portableReceiptWarning(oldDynamic, language: language)
            == L10n.tr("Portable import history is unavailable: \(detail)", language: language))

        let path = "/synthetic/100% RAW %@.jpg"
        let oldLedgerError = L10n.tr("The source is no longer available at \(path)", language: "en")
        let oldNestedWarning = L10n.tr("Portable import history is unavailable: \(oldLedgerError)", language: "en")
        let localizedLedgerError = L10n.tr("The source is no longer available at \(path)", language: language)
        #expect(L10n.portableReceiptWarning(oldNestedWarning, language: language)
            == L10n.tr("Portable import history is unavailable: \(localizedLedgerError)", language: language))
    }

    @Test
    func portableSizeWarningsUseRawBytesAfterLanguageSwitch() throws {
        let ledgerBytes: Int64 = 70 * 1_024 * 1_024
        let receiptBytes: Int64 = 20_000
        for sourceLanguage in ["fr", "es", "pt-BR"] {
            for (sizeWarning, key) in [
                (PortableReceiptSizeWarning.ledgerTooLarge(ledgerBytes), 0),
                (PortableReceiptSizeWarning.receiptTooLarge(receiptBytes), 1),
            ] {
                let bytes = key == 0 ? ledgerBytes : receiptBytes
                let oldSize = L10n.fileSize(bytes, language: sourceLanguage)
                let newSize = L10n.fileSize(bytes, language: "en")
                let oldDetail = key == 0
                    ? L10n.tr("The portable import ledger is too large (\(oldSize))", language: sourceLanguage)
                    : L10n.tr("The portable import receipt is too large (\(oldSize))", language: sourceLanguage)
                let newDetail = key == 0
                    ? L10n.tr("The portable import ledger is too large (\(newSize))", language: "en")
                    : L10n.tr("The portable import receipt is too large (\(newSize))", language: "en")
                let oldWarning = L10n.tr("Portable import history is unavailable: \(oldDetail)", language: sourceLanguage)
                let expected = L10n.tr("Portable import history is unavailable: \(newDetail)", language: "en")
                #expect(L10n.portableReceiptWarning(oldWarning, sizeWarning: sizeWarning, language: "en") == expected)
            }
        }
        #expect(PortableReceiptSizeWarning(error: PortableImportReceiptLedgerError.ledgerTooLarge(ledgerBytes))
            == .ledgerTooLarge(ledgerBytes))
        #expect(PortableReceiptSizeWarning(error: PortableImportReceiptLedgerError.recordTooLarge(Int(receiptBytes)))
            == .receiptTooLarge(receiptBytes))

        let summary = ScanSummary(
            jobID: "synthetic", mountPath: "/synthetic", volumeName: nil, volumeUUID: nil,
            location: "test", scannedFiles: 0, newFiles: 0, knownFiles: 0,
            unsupportedFiles: 0, conflictFiles: 0,
            portableReceiptWarning: "synthetic warning",
            portableReceiptSizeWarning: .ledgerTooLarge(ledgerBytes)
        )
        let result = ImportResult(
            jobID: "synthetic", importedFiles: 0, skippedFiles: 0, failedFiles: 0,
            progressPath: nil, portableReceiptWarning: "synthetic warning",
            portableReceiptSizeWarning: .receiptTooLarge(receiptBytes)
        )
        for data in [try JSONEncoder().encode(summary), try JSONEncoder().encode(result)] {
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["portableReceiptSizeWarning"] == nil)
        }
        let decodedSummary = try JSONDecoder().decode(ScanSummary.self, from: JSONEncoder().encode(summary))
        let decodedResult = try JSONDecoder().decode(ImportResult.self, from: JSONEncoder().encode(result))
        #expect(decodedSummary.portableReceiptSizeWarning == nil)
        #expect(decodedResult.portableReceiptSizeWarning == nil)
    }

    @Test
    func datePresentationUsesSelectedLanguageAndRegion() {
        let us = Locale(identifier: "en_US")
        #expect(L10n.presentationLocale(for: .system, systemLocale: us).identifier == us.identifier)
        let japanese = L10n.presentationLocale(for: .japanese, systemLocale: us)
        #expect(japanese.language.languageCode?.identifier == "ja")
        #expect(japanese.region?.identifier == "US")
        let portuguese = L10n.presentationLocale(for: .brazilianPortuguese, systemLocale: us)
        #expect(portuguese.language.languageCode?.identifier == "pt")
        #expect(portuguese.region?.identifier == "BR")
    }

    @Test(arguments: [
        (["de-DE", "en-US"], AppLanguage.german),
        (["fr-CA", "en-US"], AppLanguage.french),
        (["zh-HK", "en-US"], AppLanguage.traditionalChinese),
        (["zh-CN", "en-US"], AppLanguage.simplifiedChinese),
        (["pt-BR", "en-US"], AppLanguage.brazilianPortuguese),
        (["nl-NL"], AppLanguage.english)
    ])
    func systemDefaultResolvesSupportedLanguage(preferences: [String], expected: AppLanguage) {
        #expect(AppLanguage.systemDefault(preferences: preferences) == expected)
    }

    @Test(arguments: L10n.supportedLanguages)
    func languageResources(language: String) throws {
        #expect(L10n.tr("Settings", language: language) == Self.settings[language])
        let englishURL = try #require(L10n.localizationBundle(for: "en")).bundleURL
        let localeURL = try #require(L10n.localizationBundle(for: language)).bundleURL
        let english = try strings(at: englishURL)
        let translated = try strings(at: localeURL)
        #expect(!english.isEmpty)
        #expect(Set(english.keys) == Set(translated.keys))
        #expect(translated.values.allSatisfy { !$0.isEmpty })
    }

    @Test(arguments: [false, true])
    func localizationFolderCasing(lowercase: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appendingPathComponent("Fixture.bundle/Contents")
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleDevelopmentRegion": "en", "CFBundleIdentifier": "example.localization.\(UUID().uuidString)"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        for language in ["en", "zh-Hans", "zh-Hant", "pt-BR"] {
            let name = lowercase ? language.lowercased() : language
            let folder = resources.appendingPathComponent("\(name).lproj")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let translations = ["Settings": try #require(Self.settings[language])]
            try PropertyListSerialization.data(fromPropertyList: translations, format: .xml, options: 0)
                .write(to: folder.appendingPathComponent("Localizable.strings"))
        }
        let fixture = try #require(Bundle(url: contents.deletingLastPathComponent()))
        for (preference, expected) in [
            ("zh-Hans", "设置"), ("zh-CN", "设置"), ("zh-Hant", "設定"),
            ("zh-HK", "設定"), ("pt-BR", "Ajustes"), ("nl-NL", "Settings")
        ] {
            let selected = try #require(L10n.localizationBundle(for: preference, in: fixture))
            #expect(String(localized: "Settings", bundle: selected) == expected)
        }
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
