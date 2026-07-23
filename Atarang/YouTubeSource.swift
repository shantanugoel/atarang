import Foundation

enum YouTubeSource {
    static func validatedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), canonicalKey(for: url) != nil else { return nil }
        return url
    }

    static func canonicalKey(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let videoID: String?

        if normalizedHost == "youtu.be" {
            videoID = url.pathComponents.dropFirst().first
        } else if normalizedHost == "youtube.com"
                    || normalizedHost == "m.youtube.com"
                    || normalizedHost.hasSuffix(".youtube.com") {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if url.path == "/watch" {
                videoID = components?.queryItems?.first(where: { $0.name == "v" })?.value
            } else {
                let path = url.pathComponents.filter { $0 != "/" }
                videoID = path.count >= 2 && ["shorts", "embed", "live"].contains(path[0])
                    ? path[1]
                    : nil
            }
        } else {
            return nil
        }

        guard let videoID else { return nil }
        let trimmed = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: allowed.inverted) == nil else { return nil }
        return "youtube:\(trimmed)"
    }
}
