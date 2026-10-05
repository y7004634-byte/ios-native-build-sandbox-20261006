import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native client for the already accepted Door Map scooter route endpoint.
/// It never falls back to Apple driving routes or fabricates straight geometry.
final class NativeRoutePlanner {
    enum PlannerError: Error, Equatable {
        case invalidInput, invalidResponse, http(Int)
    }
    private struct Payload: Encodable {
        let from: String
        let to: String
        let via: [DoorCoordinate]
        let areas: [DoorAvoidArea]
        let variant: String
        let alternatives: Int
    }
    private struct Geometry: Decodable { let type: String; let coordinates: [[Double]] }
    private struct WireManeuver: Decodable {
        let type: String
        let modifier: String
        let name: String
        let distance: Double
        let location: [Double]?
    }
    private struct WireRoute: Decodable {
        let geometry: Geometry
        let distance: Double
        let duration: Double
        let engine: String
        let profile: String
        let maneuvers: [WireManeuver]
        let avoidApplied: [String]?
        let endpointExempt: [String]?
        let label: String?
    }
    private struct Envelope: Decodable { let routes: [WireRoute] }

    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    static func request(origin: DoorCoordinate, destination: DoorCoordinate, via: [DoorCoordinate],
                        areas: [DoorAvoidArea], alternatives: Int = 2, variant: String = "main",
                        minute: Int? = nil) throws -> (URLRequest, [DoorAvoidArea]) {
        guard DoorDeliveryCore.point(origin), DoorDeliveryCore.point(destination),
              via.count <= DoorDeliveryCore.maxViaPoints, via.allSatisfy({ DoorDeliveryCore.point($0) }),
              ["main","alt1","alt2"].contains(variant), alternatives >= 0, alternatives <= 2 else {
            throw PlannerError.invalidInput
        }
        let m = minute ?? DoorDeliveryCore.taipeiMinute(Date())
        let selected = DoorDeliveryCore.choose(areas, origin: origin, destination: destination, via: via, minute: m)
        let locale = Locale(identifier: "en_US_POSIX")
        let payload = Payload(from: String(format: "%.7f,%.7f", locale: locale, origin.lng, origin.lat),
                              to: String(format: "%.7f,%.7f", locale: locale, destination.lng, destination.lat),
                              via: via, areas: selected.areas, variant: variant, alternatives: alternatives)
        let bytes = try JSONEncoder().encode(payload)
        guard bytes.count <= 40_000 else { throw PlannerError.invalidInput }
        var request = URLRequest(url: AppConfig.liveBaseURL.appendingPathComponent("api/route"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
        request.httpMethod = "POST"; request.httpBody = bytes
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return (request, selected.areas)
    }

    static func decode(_ data: Data, via: [DoorCoordinate], areas: [DoorAvoidArea]) throws -> [DoorPlannedRoute] {
        guard data.count > 0, data.count <= 8 * 1024 * 1024 else { throw PlannerError.invalidResponse }
        let decoder = JSONDecoder()
        let wires: [WireRoute]
        if let envelope = try? decoder.decode(Envelope.self, from: data) { wires = envelope.routes }
        else if let single = try? decoder.decode(WireRoute.self, from: data) { wires = [single] }
        else { throw PlannerError.invalidResponse }
        guard !wires.isEmpty, wires.count <= 3 else { throw PlannerError.invalidResponse }
        return try wires.map { wire in
            guard wire.engine == "valhalla", wire.profile == "motor_scooter",
                  wire.geometry.type == "LineString", wire.geometry.coordinates.count >= 2,
                  wire.geometry.coordinates.count <= 100_000,
                  wire.distance.isFinite, wire.distance >= 0, wire.duration.isFinite, wire.duration >= 0 else {
                throw PlannerError.invalidResponse
            }
            let coordinates = try wire.geometry.coordinates.map { row -> DoorCoordinate in
                guard row.count >= 2 else { throw PlannerError.invalidResponse }
                let p = DoorCoordinate(lat: row[1], lng: row[0])
                guard DoorDeliveryCore.point(p) else { throw PlannerError.invalidResponse }
                return p
            }
            let constraint = DoorDeliveryCore.constraints(coordinates, via: via, areas: areas)
            guard constraint.ok else { throw PlannerError.invalidResponse }
            let maneuvers = wire.maneuvers.prefix(10_000).map { row -> DoorPlannedRoute.Maneuver in
                let location: DoorCoordinate? = {
                    guard let raw = row.location, raw.count >= 2 else { return nil }
                    let p = DoorCoordinate(lat: raw[1], lng: raw[0]); return p.isValid ? p : nil
                }()
                let index = location.flatMap { DoorDeliveryCore.closest(coordinates, $0)?.index } ?? 0
                return .init(type: row.type, modifier: row.modifier, name: row.name, distance: row.distance,
                             location: location, routeIndex: max(0, index))
            }
            let route = DoorPlannedRoute(coordinates: coordinates, distance: wire.distance, duration: wire.duration,
                                         maneuvers: maneuvers, avoidApplied: wire.avoidApplied ?? [],
                                         endpointExempt: wire.endpointExempt ?? [], label: wire.label ?? "")
            try route.validate()
            return route
        }
    }

    func plan(origin: DoorCoordinate, destination: DoorCoordinate, via: [DoorCoordinate] = [],
              areas: [DoorAvoidArea] = [], alternatives: Int = 2, variant: String = "main") async throws -> [DoorPlannedRoute] {
        let (request, selectedAreas) = try Self.request(origin: origin, destination: destination, via: via,
                                                        areas: areas, alternatives: alternatives, variant: variant)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlannerError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw PlannerError.http(http.statusCode) }
        return try Self.decode(data, via: via, areas: selectedAreas)
    }

    static func ridingManeuvers(_ route: DoorPlannedRoute) -> [DoorRouteManeuver] {
        route.maneuvers.map { .init(type: $0.type, modifier: $0.modifier, name: $0.name,
                                    routeIndex: $0.routeIndex, location: $0.location) }
    }
}
