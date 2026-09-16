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

/// Shared by both distributions and the helper. Only presentation text belongs here;
/// persisted identifiers, user text and destination folder names remain unchanged.
public enum L10n {
    public static let supportedLanguages = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "es", "pt-BR", "it"]
    public static let languagePreferenceKey = "SDImport.interfaceLanguage"

    /// Keep one language for the lifetime of the process. Settings changes are applied
    /// on the next launch so existing views, menus, and dialogs never mix languages.
    public static let activeLanguage = AppLanguage.saved()

    /// Date presentation follows the selected language while retaining the Mac's
    /// region, except when a choice explicitly names a region (Portuguese/Brazil).
    public static var presentationLocale: Locale {
        presentationLocale(for: activeLanguage)
    }

    static func presentationLocale(for language: AppLanguage, systemLocale: Locale = .current) -> Locale {
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
