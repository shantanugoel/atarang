import AppIntents
import Foundation

struct ImportYouTubeURLIntent: AppIntent {
    static let title: LocalizedStringResource = "Import YouTube Link"
    static let description = IntentDescription(
        "Sends a YouTube video link to Atarang for stem separation."
    )
    static let openAppWhenRun = true

    @Parameter(title: "YouTube URL")
    var url: URL

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard YouTubeSource.canonicalKey(for: url) != nil else {
            throw ImportYouTubeIntentError.invalidURL
        }
        UserDefaults.standard.set(
            url.absoluteString,
            forKey: PendingYouTubeImport.defaultsKey
        )
        return .result(dialog: "Opening the link in Atarang.")
    }
}

enum PendingYouTubeImport {
    static let defaultsKey = "pendingYouTubeImportURL"
}

private enum ImportYouTubeIntentError: LocalizedError {
    case invalidURL

    var errorDescription: String? {
        "Choose a valid youtube.com or youtu.be video link."
    }
}
