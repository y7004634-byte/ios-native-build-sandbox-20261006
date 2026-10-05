import Foundation

enum DeepLinkPayload {
    case home
    case destination(String)
    case googleShare(String)
}

enum DeepLinkRouter {
    static func payload(from incomingURL: URL) -> DeepLinkPayload {
        let scheme = incomingURL.scheme?.lowercased() ?? ""
        if (scheme == "https" || scheme == "http") && isGoogleMapsURL(incomingURL) {
            return .googleShare(incomingURL.absoluteString)
        }
        if scheme == "waze",
           let destination = wazeDestination(incomingURL) {
            return .destination(destination)
        }
        guard scheme == "door581" || scheme == "door581-apple-test" else { return .home }

        let components = URLComponents(url: incomingURL, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        var values: [String: String] = [:]
        for item in items where values[item.name] == nil {
            values[item.name] = item.value ?? ""
        }

        if let lat = values["lat"], let lng = values["lng"], !lat.isEmpty, !lng.isEmpty {
            return .destination("\(lat),\(lng)")
        }
        if let dest = values["dest"], !dest.isEmpty {
            return .destination(dest)
        }
        if let gmap = values["gmap"], !gmap.isEmpty {
            return .googleShare(gmap)
        }
        if let rawURL = values["url"], !rawURL.isEmpty {
            return .googleShare(rawURL)
        }
        return .home
    }

    static func webURL(for payload: DeepLinkPayload) -> URL {
        switch payload {
        case .home:
            return AppConfig.initialURL()
        case .destination(let destination):
            return url(byAdding: [URLQueryItem(name: "dest", value: destination)])
        case .googleShare(let sharedURL):
            return url(byAdding: [URLQueryItem(name: "gmap", value: sharedURL)])
        }
    }

    private static func wazeDestination(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name.lowercased() == "ll" })?.value
        else { return nil }

        let parts = raw.split(separator: ",", maxSplits: 1).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count == 2,
              let lat = Double(parts[0]),
              let lng = Double(parts[1]),
              (20...27).contains(lat),
              (117...123).contains(lng) else { return nil }
        return "\(lat),\(lng)"
    }

    private static func isGoogleMapsURL(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host == "maps.app.goo.gl"
            || host == "goo.gl"
            || host == "maps.google.com"
            || host.hasSuffix(".google.com")
            || host.hasSuffix(".google.com.tw")
    }

    private static func url(byAdding items: [URLQueryItem]) -> URL {
        let baseURL = AppConfig.initialURL()
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var queryItems = components.queryItems ?? []
        queryItems.append(contentsOf: items)
        components.queryItems = queryItems
        return components.url ?? baseURL
    }
}
