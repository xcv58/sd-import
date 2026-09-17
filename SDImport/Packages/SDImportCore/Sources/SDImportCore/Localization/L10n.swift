import Foundation

/// A display-language choice for the app. Stable raw values are stored in user defaults.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = ""
    case english = "en"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case japanese = "ja"
    case brazilianPortuguese = "pt-BR"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case italian = "it"
    case korean = "ko"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system:
            let name = Self.systemDefault().displayName
            return L10n.tr("System Default (\(name))")
        case .english: return "English"
        case .german: return "German / Deutsch"
        case .french: return "French / Français"
        case .spanish: return "Spanish / Español"
        case .japanese: return "Japanese / 日本語"
        case .brazilianPortuguese: return "Portuguese (Brazil) / Português (Brasil)"
        case .simplifiedChinese: return "Chinese, Simplified / 简体中文"
        case .traditionalChinese: return "Chinese, Traditional / 繁體中文"
        case .italian: return "Italian / Italiano"
        case .korean: return "Korean / 한국어"
        }
    }

    /// The language macOS would select if the app's own picker follows the system.
    public static func systemDefault(preferences: [String] = Locale.preferredLanguages) -> AppLanguage {
        let selected = Bundle.preferredLocalizations(
            from: L10n.supportedLanguages, forPreferences: preferences + ["en"]
        ).first ?? "en"
        return AppLanguage(rawValue: selected) ?? .english
    }

    public static func saved(in defaults: UserDefaults = .standard) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: L10n.languagePreferenceKey) ?? "") ?? .system
    }
}

/// In-memory byte counts for portable warnings, kept outside encoded import records.
public enum PortableReceiptSizeWarning: Hashable, Sendable {
    case ledgerTooLarge(Int64)
    case receiptTooLarge(Int64)
}

/// Shared by both distributions and the helper. Only presentation text belongs here;
/// persisted identifiers, user text and destination folder names remain unchanged.
public enum L10n {
    public static let supportedLanguages = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "es", "pt-BR", "it"]
    public static let languagePreferenceKey = "SDImport.interfaceLanguage"

    /// Read the current preference for each display operation so the in-app picker
    /// updates text and formatting without restarting either app edition.
    public static var activeLanguage: AppLanguage { AppLanguage.saved() }

    /// Date presentation follows the selected language while retaining the Mac's
    /// region, except when a choice explicitly names a region (Portuguese/Brazil).
    public static var presentationLocale: Locale {
        presentationLocale(for: activeLanguage)
    }

    public static func presentationLocale(for language: AppLanguage, systemLocale: Locale = .current) -> Locale {
        guard language != .system else { return systemLocale }
        var components = Locale.Components(locale: systemLocale)
        components.languageComponents = Locale.Language.Components(identifier: language.rawValue)
        components.region = Locale(identifier: language.rawValue).region ?? systemLocale.region
        return Locale(components: components)
    }

    public static func list(_ values: [String]) -> String {
        if activeLanguage == .system {
            return ListFormatter.localizedString(byJoining: values)
        }
        let formatter = ListFormatter()
        formatter.locale = presentationLocale
        return formatter.string(from: values) ?? values.joined(separator: ", ")
    }

    public static func fileSize(_ byteCount: Int64) -> String {
        if activeLanguage == .system {
            return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        }
        return byteCount.formatted(.byteCount(style: .file).locale(presentationLocale))
    }

    static func fileSize(_ byteCount: Int64, language: String?) -> String {
        guard let language, let selected = AppLanguage(rawValue: language), selected != .system else {
            return fileSize(byteCount)
        }
        return byteCount.formatted(.byteCount(style: .file).locale(presentationLocale(for: selected)))
    }

    // SwiftPM's generated accessor may fall back to an absolute build path. Prefer
    // the resource bundle shipped inside the application, including in direct builds.
    static let resourceBundle: Bundle = {
        if let url = Bundle.main.url(forResource: "SDImportCore_SDImportCore", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()

    public static func tr(_ value: String.LocalizationValue) -> String {
        if activeLanguage != .system {
            return tr(value, language: activeLanguage.rawValue)
        }
        return String(localized: value, bundle: resourceBundle)
    }

    public static func errorMessage(for error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    /// Re-render a completed app message after the picker changes. Only exact,
    /// argument-free catalog entries qualify; system errors and user text keep
    /// their original detail rather than being guessed from a translated string.
    public static func relocalizedStaticMessage(
        _ message: String,
        from previousLanguage: AppLanguage,
        to selectedLanguage: AppLanguage,
        systemPreferences: [String] = Locale.preferredLanguages
    ) -> String {
        let previous = previousLanguage == .system
            ? AppLanguage.systemDefault(preferences: systemPreferences) : previousLanguage
        let selected = selectedLanguage == .system
            ? AppLanguage.systemDefault(preferences: systemPreferences) : selectedLanguage
        guard previous != selected,
              let oldEntries = localizedEntries(for: previous.rawValue),
              let newEntries = localizedEntries(for: selected.rawValue) else {
            return message
        }

        let translations = Set(oldEntries.compactMap { entry -> String? in
            guard !entry.key.contains("%"), entry.value == message else { return nil }
            return newEntries[entry.key]
        })
        return translations.count == 1 ? (translations.first ?? message) : message
    }

    /// Portable receipt warnings are produced during a scan or import, then
    /// retained while the user may change languages. Recognize only the known
    /// app-owned warning formats and preserve opaque filesystem error details.
    public static func portableReceiptWarning(
        _ warning: String,
        sizeWarning: PortableReceiptSizeWarning? = nil,
        language: String? = nil
    ) -> String {
        if let translated = translatedPortableWarningPart(warning, sizeWarning: sizeWarning, language: language) {
            return translated
        }
        let parts = warning.components(separatedBy: ". ")
        guard parts.count > 1 else { return warning }
        return parts.map { translatedPortableWarningPart($0, sizeWarning: sizeWarning, language: language) ?? $0 }
            .joined(separator: ". ")
    }

    private static func translatedPortableWarningPart(
        _ value: String,
        sizeWarning: PortableReceiptSizeWarning?,
        language: String?
    ) -> String? {
        func render(_ value: String.LocalizationValue) -> String {
            language.map { tr(value, language: $0) } ?? tr(value)
        }
        let staticKeys = [
            "Portable import history cannot coordinate with other apps because this source does not support file locking",
            "Portable import history was not updated because the source changed during import",
            "Ignored 1 invalid or corrupted portable import record",
        ]
        for (sourceLanguage, entries) in portableWarningCatalogs {
            for key in staticKeys where entries[key] == value {
                switch key {
                case staticKeys[0]:
                    return render("Portable import history cannot coordinate with other apps because this source does not support file locking")
                case staticKeys[1]:
                    return render("Portable import history was not updated because the source changed during import")
                default:
                    return render("Ignored 1 invalid or corrupted portable import record")
                }
            }
            if let count = Int(value.filter(\.isNumber)), count > 1,
               tr("Ignored \(count) invalid or corrupted portable import records", language: sourceLanguage) == value {
                return render("Ignored \(count) invalid or corrupted portable import records")
            }
            for (key, kind) in [
                ("Portable import history is unavailable: %@", 0),
                ("Portable import history could not be updated: %@", 1),
            ] {
                guard let format = entries[key],
                      let detail = formattedArgument(in: value, matching: format) else { continue }
                let localizedDetail = translatedPortableLedgerError(
                    detail, sizeWarning: sizeWarning, language: language
                )
                return kind == 0
                    ? render("Portable import history is unavailable: \(localizedDetail)")
                    : render("Portable import history could not be updated: \(localizedDetail)")
            }
        }
        return nil
    }

    private static func translatedPortableLedgerError(
        _ detail: String,
        sizeWarning: PortableReceiptSizeWarning?,
        language: String?
    ) -> String {
        func render(_ value: String.LocalizationValue) -> String {
            language.map { tr(value, language: $0) } ?? tr(value)
        }
        if let sizeWarning {
            let key: String
            switch sizeWarning {
            case .ledgerTooLarge:
                key = "The portable import ledger is too large (%@)"
            case .receiptTooLarge:
                key = "The portable import receipt is too large (%@)"
            }
            if portableWarningCatalogs.contains(where: { catalog in
                catalog.1[key].flatMap { formattedArgument(in: detail, matching: $0) } != nil
            }) {
                switch sizeWarning {
                case .ledgerTooLarge(let bytes):
                    return render("The portable import ledger is too large (\(fileSize(bytes, language: language)))")
                case .receiptTooLarge(let bytes):
                    return render("The portable import receipt is too large (\(fileSize(bytes, language: language)))")
                }
            }
        }
        for (_, entries) in portableWarningCatalogs {
            if entries["The portable import receipt contains invalid or inconsistent file identity data"] == detail {
                return render("The portable import receipt contains invalid or inconsistent file identity data")
            }
            for (key, kind) in [
                ("The source is no longer available at %@", 0),
                ("The source is not a directory at %@", 1),
                ("The portable import ledger is too large (%@)", 2),
                ("The portable import receipt is too large (%@)", 3),
                ("The portable import ledger is not a regular file at %@", 4),
                ("The portable import ledger path is unsafe at %@", 5),
            ] {
                guard let format = entries[key],
                      let value = formattedArgument(in: detail, matching: format) else { continue }
                switch kind {
                case 0: return render("The source is no longer available at \(value)")
                case 1: return render("The source is not a directory at \(value)")
                case 2:
                    guard entries["The portable import receipt is too large (%@)"] != format else { return detail }
                    return render("The portable import ledger is too large (\(value))")
                case 3:
                    return render("The portable import receipt is too large (\(value))")
                case 4: return render("The portable import ledger is not a regular file at \(value)")
                default: return render("The portable import ledger path is unsafe at \(value)")
                }
            }
        }
        return detail
    }

    private static func formattedArgument(in value: String, matching format: String) -> String? {
        guard let marker = format.range(of: "%1$@") ?? format.range(of: "%@") else { return nil }
        let prefix = String(format[..<marker.lowerBound])
        let suffix = String(format[marker.upperBound...])
        guard value.hasPrefix(prefix), value.hasSuffix(suffix),
              value.count >= prefix.count + suffix.count else { return nil }
        return String(value.dropFirst(prefix.count).dropLast(suffix.count))
    }

    private static let portableWarningCatalogs: [(String, [String: String])] = supportedLanguages.compactMap { language in
        localizedEntries(for: language).map { (language, $0) }
    }

    private static func localizedEntries(for language: String) -> [String: String]? {
        guard let bundle = localizationBundle(for: language),
              let url = bundle.url(forResource: "Localizable", withExtension: "strings") else {
            return nil
        }
        return NSDictionary(contentsOf: url) as? [String: String]
    }

    /// These messages are persisted by import jobs. Translate recognized legacy
    /// values for display; never reinterpret unknown error text or user data.
    public static func storedMessage(_ value: String) -> String {
        switch value {
        case "source file missing": tr("Source file missing")
        case "source changed since scan; rescan required": tr("Source changed since scan; scan again")
        case "destination file exists with different content": tr("Destination file exists with different content")
        case "destination file name repeats in this import": tr("Destination file name repeats in this import")
        case "interrupted import": tr("Interrupted import")
        case "unsupported": tr("Unsupported")
        case "excluded_by_import_selection": tr("Excluded")
        case "no_destination": tr("No destination")
        case "already_exists_same_fingerprint": tr("Already exists")
        case "already_imported_fingerprint", "Already imported": tr("Already imported")
        case "already_imported_portable_receipt", "Imported on another Mac": tr("Imported on another Mac")
        case "cancelled": tr("Cancelled")
        // Helpers retain these stable messages because their language preference
        // can differ from the containing app's per-app preference.
        case "Could not locate the containing SD Import application":
            tr("Could not locate the containing SD Import application")
        case "Could not persist a mounted-card event":
            tr("Could not persist a mounted-card event")
        case "Could not launch the containing SD Import application":
            tr("Could not launch the containing SD Import application")
        case "Could not mark the helper runtime QA lifecycle as active":
            tr("Could not mark the helper runtime QA lifecycle as active")
        case "Size checked": tr("Size checked")
        case "Undated": tr("Undated")
        default: value
        }
    }

    /// Explicit selection supports deterministic tests and bundled-resource validation.
    /// Normal app presentation uses the system's preferred supported language.
    static func tr(_ value: String.LocalizationValue, language: String, locale: Locale? = nil) -> String {
        guard let bundle = localizationBundle(for: language) else {
            return String(localized: value, bundle: resourceBundle)
        }
        return String(localized: value, bundle: bundle, locale: locale ?? Locale(identifier: language))
    }

    static func localizationBundle(for language: String, in bundle: Bundle = resourceBundle) -> Bundle? {
        let selected = Bundle.preferredLocalizations(
            from: supportedLanguages, forPreferences: [language, "en"]
        ).first ?? "en"
        // SwiftPM versions differ in whether they preserve casing in lproj names.
        // Bundle resource lookup needs the spelling actually present in the bundle.
        guard let resourceLanguage = bundle.localizations.first(where: {
            $0.caseInsensitiveCompare(selected) == .orderedSame
        }), let url = bundle.url(forResource: resourceLanguage, withExtension: "lproj") else {
            return nil
        }
        return Bundle(url: url)
    }
}
