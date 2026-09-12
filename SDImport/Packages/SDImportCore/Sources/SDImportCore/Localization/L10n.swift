import Foundation

/// Shared by both distributions and the helper. Only presentation text belongs here;
/// persisted identifiers, user text and destination folder names remain unchanged.
public enum L10n {
    public static let supportedLanguages = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "es", "pt-BR", "it"]

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
        String(localized: value, bundle: resourceBundle)
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
        let selected = Bundle.preferredLocalizations(
            from: supportedLanguages, forPreferences: [language, "en"]
        ).first ?? "en"
        guard let url = resourceBundle.url(forResource: selected, withExtension: "lproj"),
              let bundle = Bundle(url: url) else {
            return String(localized: value, bundle: resourceBundle)
        }
        return String(localized: value, bundle: bundle, locale: locale ?? Locale(identifier: language))
    }
}
