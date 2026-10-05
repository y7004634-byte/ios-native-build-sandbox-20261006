import Foundation

struct NativeResolvedDestination: Sendable {
    let coordinate: DoorCoordinate
    let source: String
    let finalURL: String
    let targetText: String
    let placeName: String
    let addressText: String
    let floor: String
    let notice: String
    let verifiedAddress: Bool
    var title: String {
        for value in [placeName, targetText, addressText] {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return String(format: "%.6f, %.6f", coordinate.lat, coordinate.lng)
    }
}

enum NativeMapsInput {
    private static let hosts: Set<String> = [
        "maps.app.goo.gl", "maps.google.com", "www.google.com", "google.com",
        "maps.google.com.tw", "www.google.com.tw", "google.com.tw", "goo.gl", "consent.google.com"
    ]

    static func coordinate(_ text: String?) -> DoorCoordinate? {
        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: "′", with: "'").replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "″", with: "\"").replacingOccurrences(of: "”", with: "\"")
        if let match = value.firstMatch(#"^\s*\(?\s*(-?\d{1,2}(?:\.\d+)?)\s*[,，]\s*(-?\d{2,3}(?:\.\d+)?)\s*\)?\s*$"#),
           let lat = Double(match[1]), let lng = Double(match[2]) {
            let point = DoorCoordinate(lat: lat, lng: lng)
            return taiwan(point) ? point : nil
        }
        if let match = value.firstMatch(#"^(\d{1,2})\s*°\s*(\d{1,2})\s*'\s*(\d+(?:\.\d+)?)\s*"?\s*([NS])[\s,]+(\d{1,3})\s*°\s*(\d{1,2})\s*'\s*(\d+(?:\.\d+)?)\s*"?\s*([EW])$"#),
           let latD = Double(match[1]), let latM = Double(match[2]), let latS = Double(match[3]),
           let lngD = Double(match[5]), let lngM = Double(match[6]), let lngS = Double(match[7]),
           latM < 60, latS < 60, lngM < 60, lngS < 60 {
            let lat = (latD + latM / 60 + latS / 3600) * (match[4].uppercased() == "S" ? -1 : 1)
            let lng = (lngD + lngM / 60 + lngS / 3600) * (match[8].uppercased() == "W" ? -1 : 1)
            let point = DoorCoordinate(lat: lat, lng: lng)
            return taiwan(point) ? point : nil
        }
        return nil
    }

    static func extract(_ value: String) -> URL? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"https?://[^\s<>"'，。]+"#
        var raw: String?
        if let range = text.range(of: pattern, options: .regularExpression) { raw = String(text[range]) }
        else if text.range(of: #"^(?:maps\.|(?:www\.)?google\.|goo\.gl/maps)"#, options: [.regularExpression, .caseInsensitive]) != nil { raw = "https://" + text }
        guard var raw else { return nil }
        raw = raw.replacingOccurrences(of: #"[）)\]】。]+$"#, with: "", options: .regularExpression)
        guard var components = URLComponents(string: raw) else { return nil }
        if components.scheme?.lowercased() == "http" { components.scheme = "https" }
        guard let url = components.url, allowed(url) else { return nil }
        return url
    }

    static func allowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased(), hosts.contains(host) else { return false }
        if host == "goo.gl" { return url.path == "/maps" || url.path.hasPrefix("/maps/") }
        if ["www.google.com","google.com","www.google.com.tw","google.com.tw"].contains(host) {
            return url.path == "/maps" || url.path.hasPrefix("/maps/") || url.path == "/url"
        }
        return true
    }

    static func point(from url: URL) -> DoorCoordinate? {
        guard allowed(url) else { return nil }
        let decoded = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        func value(_ key: String) -> String? { queryItems.first(where: { $0.name == key })?.value }
        for key in ["destination","daddr","query","q"] {
            if key == "query", value("query_place_id") != nil { continue }
            if key == "destination", value("destination_place_id") != nil { continue }
            if let point = coordinate(value(key)) { return point }
        }
        let pairs = decoded.matches(#"!3d(-?\d{1,2}(?:\.\d+)?)!4d(-?\d{2,3}(?:\.\d+)?)"#).compactMap { row -> DoorCoordinate? in
            guard let lat = Double(row[1]), let lng = Double(row[2]) else { return nil }
            let p = DoorCoordinate(lat: lat, lng: lng); return taiwan(p) ? p : nil
        }
        if pairs.count == 1 { return pairs[0] }
        if pairs.count > 1, url.path.contains("/maps/dir/") || value("destination") != nil { return pairs.last }
        if pairs.count > 1 {
            let unique = Set(pairs.map { String(format: "%.7f,%.7f", $0.lat, $0.lng) })
            return unique.count == 1 ? pairs[0] : nil
        }
        let segments = url.path.split(separator: "/").map(String.init)
        if let i = segments.firstIndex(of: "place"), segments.indices.contains(i + 1),
           let point = coordinate(segments[i + 1].replacingOccurrences(of: "+", with: " ")) { return point }
        if let i = segments.firstIndex(of: "dir") {
            for segment in segments[(i + 1)...].reversed() where !segment.hasPrefix("@") && !segment.hasPrefix("data=") {
                if let point = coordinate(segment.replacingOccurrences(of: "+", with: " ")) { return point }
            }
        }
        return nil
    }

    static func targetText(from url: URL) -> String {
        guard allowed(url) else { return "" }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for key in ["destination","daddr","query","q"] {
            if let raw = items.first(where: { $0.name == key })?.value {
                let value = raw.replacingOccurrences(of: "+", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, coordinate(value) == nil, !value.lowercased().contains("http://"), !value.lowercased().contains("https://") { return value }
            }
        }
        let parts = url.path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(of: "place"), parts.indices.contains(i + 1) {
            let value = (parts[i + 1].removingPercentEncoding ?? parts[i + 1]).replacingOccurrences(of: "+", with: " ")
            if coordinate(value) == nil { return value }
        }
        return ""
    }

    private static func taiwan(_ p: DoorCoordinate) -> Bool { (20...27).contains(p.lat) && (117...123).contains(p.lng) }
}

final class NativeGoogleResolver {
    enum ResolveError: LocalizedError {
        case unsupported, http(Int, String), invalid
        var errorDescription: String? {
            switch self {
            case .unsupported: return "不是支援的 Google Maps 分享連結"
            case .http(let code, let text): return text.isEmpty ? "Google Maps 解析失敗 HTTP \(code)" : text
            case .invalid: return "Google Maps 連結沒有解析出有效台灣座標"
            }
        }
    }
    private struct Response: Decodable {
        let lat: Double, lng: Double
        let source: String?, finalUrl: String?, targetText: String?, placeName: String?, addressText: String?, floor: String?, notice: String?
        let verifiedAddress: Bool?
    }

    func resolve(_ raw: String) async throws -> NativeResolvedDestination {
        guard let url = NativeMapsInput.extract(raw) else { throw ResolveError.unsupported }
        if let point = NativeMapsInput.point(from: url) {
            return .init(coordinate: point, source: "google-local-url", finalURL: url.absoluteString,
                         targetText: NativeMapsInput.targetText(from: url), placeName: "", addressText: "", floor: "", notice: "", verifiedAddress: false)
        }
        var request = URLRequest(url: AppConfig.liveBaseURL.appendingPathComponent("api/google-resolve"))
        request.httpMethod = "POST"; request.cachePolicy = .reloadIgnoringLocalCacheData; request.timeoutInterval = 18
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(url.absoluteString.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ResolveError.invalid }
        guard (200..<300).contains(http.statusCode) else {
            throw ResolveError.http(http.statusCode, String(decoding: data.prefix(4096), as: UTF8.self))
        }
        guard data.count <= 2_000_000, let value = try? JSONDecoder().decode(Response.self, from: data) else { throw ResolveError.invalid }
        let point = DoorCoordinate(lat: value.lat, lng: value.lng)
        guard (20...27).contains(point.lat), (117...123).contains(point.lng) else { throw ResolveError.invalid }
        return .init(coordinate: point, source: value.source ?? "", finalURL: value.finalUrl ?? url.absoluteString,
                     targetText: value.targetText ?? "", placeName: value.placeName ?? "", addressText: value.addressText ?? "",
                     floor: value.floor ?? "", notice: value.notice ?? "", verifiedAddress: value.verifiedAddress ?? false)
    }
}

private extension String {
    func firstMatch(_ pattern: String) -> [String]? { matches(pattern).first }
    func matches(_ pattern: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(startIndex..., in: self)
        return expression.matches(in: self, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                let r = match.range(at: index)
                return r.location == NSNotFound ? "" : String(self[Range(r, in: self)!])
            }
        }
    }
}
