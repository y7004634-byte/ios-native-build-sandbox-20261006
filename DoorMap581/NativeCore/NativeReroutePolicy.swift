import Foundation

/// Typed port of fitlock6 maybeAutoReroute. It decides *when* to request
/// another route; callers keep the committed route until a new route succeeds.
public struct DoorReroutePolicy: Sendable {
    public enum Reason: String, Codable, Sendable { case missingRoute, missedTurn, hardDeviation, repeatedDeviation, headingMismatch }
    public struct Decision: Equatable, Sendable {
        public let reason: Reason
        public let force: Bool
        public let deviationM: Double
        public init(reason: Reason, force: Bool, deviationM: Double) {
            self.reason = reason; self.force = force; self.deviationM = deviationM
        }
    }
    public struct Preview: Equatable, Sendable {
        public let onRoute: Bool
        public let turnMeters: Double
        public let turnCoordinate: DoorCoordinate?
        public let turnBearingAfter: Double?
        public let projectionIndex: Int
        public let deviationM: Double
    }
    private struct ArmedTurn: Sendable {
        let coordinate: DoorCoordinate, bearingAfter: Double, armedAtMS: Double
    }

    public static let softDeviationM = 35.0
    public static let hardDeviationM = 65.0
    public static let minimumRequestIntervalMS = 7000.0

    public private(set) var deviationCount = 0
    public private(set) var headingMismatchCount = 0
    public private(set) var lastRequestMS = -Double.infinity
    public private(set) var lastReason: Reason?
    private var armedTurn: ArmedTurn?

    public init() {}

    public mutating func reset(acceptedAtMS: Double? = nil) {
        deviationCount = 0; headingMismatchCount = 0; armedTurn = nil; lastReason = nil
        if let acceptedAtMS, acceptedAtMS.isFinite { lastRequestMS = acceptedAtMS }
    }

    /// Called after a route request begins. Forced reroutes intentionally bypass
    /// the 7s ordinary missing-route cooldown, matching the accepted source.
    public mutating func requested(at nowMS: Double, reason: Reason) {
        if nowMS.isFinite { lastRequestMS = nowMS }
        lastReason = reason
        deviationCount = 0; headingMismatchCount = 0; armedTurn = nil
    }

    public mutating func evaluate(position: DoorCoordinate, accuracy: Double, heading: Double?,
                                  speed: Double, route: [DoorCoordinate], nowMS: Double) -> Decision? {
        guard position.isValid, nowMS.isFinite else { return nil }
        guard route.count >= 2 else {
            guard nowMS - lastRequestMS >= Self.minimumRequestIntervalMS else { return nil }
            return .init(reason: .missingRoute, force: false, deviationM: .infinity)
        }

        let accuracy = max(0, accuracy.isFinite ? accuracy : 0)
        let preview = Self.preview(position: position, accuracy: accuracy, speed: speed, route: route)
        let deviation = preview.deviationM
        let soft = max(Self.softDeviationM, accuracy * 1.35)
        let hard = max(Self.hardDeviationM, accuracy * 2.0)

        if preview.onRoute, preview.turnMeters <= 65, let coord = preview.turnCoordinate,
           let bearing = preview.turnBearingAfter, bearing.isFinite {
            armedTurn = .init(coordinate: coord, bearingAfter: bearing, armedAtMS: nowMS)
        }

        let heading = heading?.isFinite == true ? DoorCameraGeometry.heading(heading!) : nil
        var missed = false
        if let armed = armedTurn {
            let away = DoorCameraGeometry.haversine(position, armed.coordinate)
            let mismatch = heading.map { abs(DoorCameraGeometry.delta($0, armed.bearingAfter)) } ?? 0
            if away >= 35 && deviation >= 15 && mismatch >= 45 { missed = true }
            if away > 140 || nowMS - armed.armedAtMS > 30_000 { armedTurn = nil }
        }

        let segmentBearing: Double? = {
            let i = max(0, min(route.count - 2, preview.projectionIndex))
            guard route.indices.contains(i), route.indices.contains(i + 1) else { return nil }
            let value = DoorCameraGeometry.bearing(route[i], route[i + 1])
            return value.isFinite ? value : nil
        }()
        let mismatch = (heading != nil && segmentBearing != nil) ? abs(DoorCameraGeometry.delta(heading!, segmentBearing!)) : 0

        if missed {
            deviationCount = 0; headingMismatchCount = 0; armedTurn = nil
            return .init(reason: .missedTurn, force: true, deviationM: deviation)
        }

        if deviation >= hard { deviationCount = 2 }
        else if deviation >= soft { deviationCount += 1 }
        else { deviationCount = 0 }

        if deviation >= 15 && mismatch >= 50 { headingMismatchCount += 1 }
        else { headingMismatchCount = 0 }

        if deviationCount >= 2 {
            deviationCount = 0; headingMismatchCount = 0
            return .init(reason: deviation >= hard ? .hardDeviation : .repeatedDeviation, force: true, deviationM: deviation)
        }
        if headingMismatchCount >= 2 {
            deviationCount = 0; headingMismatchCount = 0
            return .init(reason: .headingMismatch, force: true, deviationM: deviation)
        }
        return nil
    }

    public static func preview(position: DoorCoordinate, accuracy: Double, speed: Double,
                               route: [DoorCoordinate]) -> Preview {
        guard route.count >= 2, let projection = DoorDeliveryCore.closest(route, position) else {
            return .init(onRoute: false, turnMeters: .infinity, turnCoordinate: nil,
                         turnBearingAfter: nil, projectionIndex: 0, deviationM: .infinity)
        }
        let onRouteThreshold = max(45, min(80, max(0, accuracy.isFinite ? accuracy : 0)))
        guard projection.distance <= onRouteThreshold else {
            return .init(onRoute: false, turnMeters: .infinity, turnCoordinate: nil,
                         turnBearingAfter: nil, projectionIndex: projection.index, deviationM: projection.distance)
        }

        let lookAhead = max(80, min(200, 80 + max(0, speed.isFinite ? speed : 0) * 9))
        let path = [projection.coordinate] + Array(route.dropFirst(projection.index + 1))
        var samples: [(DoorCoordinate, Double)] = [(path[0], 0)]
        var metres = 0.0, nextSample = 15.0

        if path.count >= 2 {
            for i in 1..<path.count where metres < lookAhead + 50 {
                let a = path[i - 1], b = path[i]
                let length = DoorCameraGeometry.haversine(a, b)
                guard length.isFinite, length >= 0.01 else { continue }
                while nextSample <= metres + length && nextSample <= lookAhead + 50 {
                    let t = (nextSample - metres) / length
                    samples.append((.init(lat: a.lat + (b.lat - a.lat) * t,
                                          lng: a.lng + (b.lng - a.lng) * t), nextSample))
                    nextSample += 15
                }
                metres += length
            }
        }

        if samples.count >= 3 {
            for i in 1..<(samples.count - 1) {
                let before = DoorCameraGeometry.bearing(samples[i - 1].0, samples[i].0)
                let after = DoorCameraGeometry.bearing(samples[i].0, samples[i + 1].0)
                if before.isFinite, after.isFinite, abs(DoorCameraGeometry.delta(after, before)) >= 30 {
                    return .init(onRoute: true, turnMeters: samples[i].1, turnCoordinate: samples[i].0,
                                 turnBearingAfter: after, projectionIndex: projection.index, deviationM: projection.distance)
                }
            }
        }
        return .init(onRoute: true, turnMeters: .infinity, turnCoordinate: nil,
                     turnBearingAfter: nil, projectionIndex: projection.index, deviationM: projection.distance)
    }
}
