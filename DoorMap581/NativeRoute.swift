import CoreLocation
import Foundation

// Same GET contract and scooter policy as the existing Door Map worker.
// There is deliberately no direct-provider fallback or Apple Directions call.
struct NativeRoute: Decodable {
    struct Geometry: Decodable { let type: String; let coordinates: [[Double]] }
    struct Maneuver: Decodable {
        let type: String
        let modifier: String
        let name: String
        let distance: Double
        let location: [Double]?
    }
    let geometry: Geometry
    let distance: Double
    let duration: Double
    let engine: String
    let profile: String
    let maneuvers: [Maneuver]

    var coordinates: [CLLocationCoordinate2D] {
        geometry.coordinates.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
    }

    func validate() throws {
        guard engine == "valhalla", profile == "motor_scooter",
              geometry.type == "LineString", geometry.coordinates.count >= 2,
              geometry.coordinates.count <= 100_000,
              distance.isFinite, distance >= 0, duration.isFinite, duration >= 0,
              geometry.coordinates.allSatisfy({ row in
                  row.count >= 2 && row[0].isFinite && row[1].isFinite &&
                  (-180...180).contains(row[0]) && (-90...90).contains(row[1])
              }) else { throw RouteError.invalidResponse }
    }

    static func request(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) throws -> URLRequest {
        guard CLLocationCoordinate2DIsValid(from), CLLocationCoordinate2DIsValid(to) else {
            throw RouteError.invalidResponse
        }
        var parts = URLComponents(url: AppConfig.liveBaseURL.appendingPathComponent("api/route"),
                                  resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "from", value: "\(from.longitude),\(from.latitude)"),
            URLQueryItem(name: "to", value: "\(to.longitude),\(to.latitude)"),
            URLQueryItem(name: "variant", value: "main")
        ]
        return URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
    }

    enum RouteError: LocalizedError {
        case invalidResponse, http(Int)
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "路線資料無效，未顯示替代直線。"
            case .http(let status): return "既有路由服務回覆 HTTP \(status)，請稍後重算。"
            }
        }
    }
}

// A native-test route cursor, independent of the production web FIT solver.
// Search locally along the path so nearby later crossings cannot skip a long loop.
struct NativeRouteProgress {
    private(set) var segment = 0
    private(set) var fraction = 0.0
    private(set) var travelled = 0.0
    let path: [CLLocationCoordinate2D]
    let lengths: [Double]
    let total: Double

    init(path: [CLLocationCoordinate2D]) {
        self.path = path
        lengths = zip(path, path.dropFirst()).map { pair in
            CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
        total = lengths.reduce(0, +)
    }

    mutating func update(_ position: CLLocationCoordinate2D, accuracy: Double) -> Double? {
        guard path.count >= 2, accuracy >= 0, accuracy <= 60 else { return nil }
        let scaleX = 111_320.0 * cos(position.latitude * .pi / 180)
        let scaleY = 110_540.0
        var best: (Int, Double, Double, Double)?
        var cumulative = lengths.prefix(segment).reduce(0, +)
        for i in segment..<min(lengths.count, segment + 80) {
            if cumulative > travelled + 350 { break }
            let a = path[i], b = path[i + 1]
            let ax = (a.longitude - position.longitude) * scaleX
            let ay = (a.latitude - position.latitude) * scaleY
            let dx = (b.longitude - a.longitude) * scaleX
            let dy = (b.latitude - a.latitude) * scaleY
            let denominator = dx * dx + dy * dy
            let f = denominator > 0 ? min(1, max(0, -(ax * dx + ay * dy) / denominator)) : 0
            let along = cumulative + f * lengths[i]
            let deviation = hypot(ax + f * dx, ay + f * dy)
            if along >= travelled - 0.5 && (best == nil || deviation < best!.2) {
                best = (i, f, deviation, along)
            }
            cumulative += lengths[i]
        }
        guard let match = best, match.2 <= max(35, accuracy * 1.5) else { return nil }
        if match.3 >= travelled {
            segment = match.0; fraction = match.1; travelled = match.3
        }
        return max(0, total - travelled)
    }

    var remaining: [CLLocationCoordinate2D] {
        guard path.count >= 2 else { return path }
        let a = path[segment], b = path[segment + 1]
        let start = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                                          longitude: a.longitude + (b.longitude - a.longitude) * fraction)
        return [start] + Array(path.dropFirst(segment + 1))
    }
}
