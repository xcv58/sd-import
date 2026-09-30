import Foundation

public enum AppSupport {
    public static let emailAddress = "sd-card-import@jenny.media"
    public static let privacyPolicyURL = URL(string: "https://sd.jenny.media/privacy.html")!
    public static let guideURL = URL(string: "https://sd.jenny.media/support.html")!

    public static func feedbackEmailURL(
        appName: String,
        appVersion: String,
        appBuild: String,
        osVersion: String
    ) -> URL? {
        let subject = L10n.tr("Feedback for \(appName)")
        let body = [
            L10n.tr("What happened, or what would you like to see?"),
            "",
            "",
            L10n.tr("If reporting a problem, please include what you expected and the steps to reproduce it."),
            "",
            "",
            "---",
            L10n.tr("App: \(appName)"),
            L10n.tr("Version: \(appVersion) (build \(appBuild))"),
            L10n.tr("macOS: \(osVersion)")
        ].joined(separator: "\r\n")

        // Encode UTF-8 and reserved characters once, including literal '+' signs.
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        guard
            let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: unreserved),
            let encodedBody = body.addingPercentEncoding(withAllowedCharacters: unreserved)
        else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = emailAddress
        components.percentEncodedQuery = "subject=\(encodedSubject)&body=\(encodedBody)"
        return components.url
    }
}
