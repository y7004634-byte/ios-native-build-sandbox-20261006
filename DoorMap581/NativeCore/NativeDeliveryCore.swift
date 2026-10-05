import Foundation

/// Literal, bounded port of accepted delivery-tools.js. No network, GPS listener,
/// timers, invented routes, or changes to the scooter router's access policy.
public struct DoorAvoidArea: Codable, Equatable, Sendable {
    public var id: String, name: String, note: String
    public var lat: Double, lng: Double, radius: Double
    public var enabled: Bool
    public var start: String, end: String
    public var createdAt: Double
    public var coordinate: DoorCoordinate { .init(lat: lat, lng: lng) }
    public init(id: String, name: String = "避開區域", note: String = "", lat: Double, lng: Double,
                radius: Double = 80, enabled: Bool = true, start: String = "00:00", end: String = "00:00", createdAt: Double = 0) {
        self.id = id; self.name = name; self.note = note; self.lat = lat; self.lng = lng; self.radius = radius
        self.enabled = enabled; self.start = start; self.end = end; self.createdAt = createdAt
    }
}

public enum DoorDeliveryCore {
    public static let referenceSHA256 = "2d52b86ad8025f4ce915b7eb36602da13324a185f8eb608177ffda13ca93933a"
    public static let maxAreas = 50, maxRequestedAreas = 8, maxViaPoints = 64
    public static func point(_ p: DoorCoordinate?) -> Bool {
        guard let p else { return false }
        return p.isValid && (20...27).contains(p.lat) && (117...123).contains(p.lng)
    }
    public static func meters(_ a: DoorCoordinate, _ b: DoorCoordinate) -> Double {
        DoorCameraGeometry.haversine(a, b)
    }
    public struct Projection: Codable, Equatable, Sendable {
        public let distance: Double, t: Double, coordinate: DoorCoordinate
    }
    public static func project(_ p: DoorCoordinate, _ a: DoorCoordinate, _ b: DoorCoordinate) -> Projection {
        let sx = 111320 * cos(p.lat * Double.pi / 180), sy = 111320.0
        let ax = (a.lng - p.lng) * sx, ay = (a.lat - p.lat) * sy
        let dx = (b.lng - a.lng) * sx, dy = (b.lat - a.lat) * sy
        let denominator = dx * dx + dy * dy
        let t = denominator > 0 ? min(1, max(0, -(ax * dx + ay * dy) / denominator)) : 0
        return .init(distance: hypot(ax + t * dx, ay + t * dy), t: t,
                     coordinate: .init(lat: a.lat + t * (b.lat - a.lat), lng: a.lng + t * (b.lng - a.lng)))
    }
    public struct Closest: Codable, Equatable, Sendable {
        public let distance: Double, t: Double, coordinate: DoorCoordinate
        public let index: Int, along: Double
    }
    public static func closest(_ coordinates: [DoorCoordinate], _ p: DoorCoordinate) -> Closest? {
        guard coordinates.count >= 2 else { return nil }
        var best: Closest?, along = 0.0
        for i in 1..<coordinates.count {
            let a = coordinates[i-1], b = coordinates[i], q = project(p, a, b), length = meters(a, b)
            if best == nil || q.distance < best!.distance {
                best = .init(distance: q.distance, t: q.t, coordinate: q.coordinate, index: i-1, along: along + q.t * length)
            }
            along += length
        }
        return best
    }
    public struct Detour: Codable, Equatable, Sendable {
        public let i: Int, j: Int, excess: Double, chord: Double, travelled: Double, center: DoorCoordinate
    }
    public struct Inspection: Codable, Equatable, Sendable {
        public let suspicious: Bool, reason: String, checked: Int, detour: Detour?
    }
    public static func inspect(_ coordinates: [DoorCoordinate]) -> Inspection {
        guard coordinates.count >= 3 else { return .init(suspicious: false, reason: "", checked: 0, detour: nil) }
        let step = max(1, Int(ceil(Double(coordinates.count) / 255)))
        var sampled = stride(from: 0, to: coordinates.count, by: step).map { coordinates[$0] }
        if (coordinates.count - 1) % step != 0 { sampled.append(coordinates.last!) }
        var distances = [0.0]
        for i in 1..<sampled.count { distances.append(distances.last! + meters(sampled[i-1], sampled[i])) }
        var best: Detour?, checked = 0
        for i in 0..<(sampled.count - 2) {
            for j in (i+2)..<min(sampled.count, i+33) {
                let travelled = distances[j] - distances[i]
                if travelled > 1800 { break }; if travelled < 350 { continue }
                checked += 1
                let chord = meters(sampled[i], sampled[j]), excess = travelled - chord
                if chord >= 40 && chord < travelled * 0.42 && excess >= 280 && (best == nil || excess > best!.excess) {
                    best = .init(i: i, j: j, excess: excess, chord: chord, travelled: travelled, center: sampled[(i+j)/2])
                }
            }
        }
        return .init(suspicious: best != nil, reason: best == nil ? "" : "possible_loop", checked: checked, detour: best)
    }
    public static func clearlyBetter(mainDistance: Double, mainDuration: Double, candidateDistance: Double, candidateDuration: Double) -> Bool {
        guard [mainDistance, mainDuration, candidateDistance, candidateDuration].allSatisfy(\.isFinite) else { return false }
        return mainDistance - candidateDistance >= max(150, mainDistance * 0.06) && candidateDuration <= mainDuration * 1.10 + 30
    }
    public static func validTime(_ value: String) -> Bool {
        value.range(of: "^(?:[01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil
    }
    public static func timeNumber(_ value: String) -> Int {
        let parts = value.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return 0 }
        return h * 60 + m
    }
    public static func sanitizeAreas(_ areas: [DoorAvoidArea]) -> [DoorAvoidArea] {
        let valid = areas.prefix(maxAreas).filter { point($0.coordinate) }
        return valid.enumerated().map { index, original in
            var value = original
            value.id = String((value.id.isEmpty ? "zone-\(index)" : value.id).prefix(80))
            value.name = String((value.name.isEmpty ? "避開區域" : value.name).prefix(40)); value.note = String(value.note.prefix(160))
            value.radius = min(200, max(30, value.radius.isFinite && value.radius != 0 ? value.radius : 80))
            if !validTime(value.start) { value.start = "00:00" }; if !validTime(value.end) { value.end = "00:00" }
            if !value.createdAt.isFinite { value.createdAt = 0 }
            return value
        }
    }
    public static func active(_ area: DoorAvoidArea, minute: Int) -> Bool {
        guard area.enabled else { return false }
        let a = timeNumber(area.start), b = timeNumber(area.end)
        return a == b || (a < b ? minute >= a && minute < b : minute >= a || minute < b)
    }
    public static func taipeiMinute(_ date: Date) -> Int {
        let offset = date.timeIntervalSince1970 + 8 * 3600
        let day = offset - floor(offset / 86400) * 86400
        return Int(floor(day / 60))
    }
    public struct Selection: Codable, Equatable, Sendable {
        public let areas: [DoorAvoidArea], endpointExempt: [DoorAvoidArea], overflow: Int
    }
    public static func choose(_ areas: [DoorAvoidArea], origin: DoorCoordinate?, destination: DoorCoordinate?, via: [DoorCoordinate] = [], minute: Int) -> Selection {
        let selected = sanitizeAreas(areas).filter { active($0, minute: minute) }
        let anchors = ([origin, destination].compactMap { $0 } + via).filter { point($0) }
        var exempt: [DoorAvoidArea] = [], candidates: [(Int, DoorAvoidArea)] = []
        for (i, area) in selected.enumerated() {
            if anchors.contains(where: { meters($0, area.coordinate) <= area.radius + 40 }) { exempt.append(area); continue }
            guard !anchors.isEmpty else { continue }
            let pad = 0.015
            if area.lat < anchors.map(\.lat).min()! - pad || area.lat > anchors.map(\.lat).max()! + pad ||
                area.lng < anchors.map(\.lng).min()! - pad || area.lng > anchors.map(\.lng).max()! + pad { continue }
            candidates.append((i, area))
        }
        if let reference = anchors.first {
            candidates.sort { a, b in
                let ad = meters(reference, a.1.coordinate), bd = meters(reference, b.1.coordinate)
                return ad == bd ? a.0 < b.0 : ad < bd
            }
        }
        return .init(areas: candidates.prefix(maxRequestedAreas).map(\.1), endpointExempt: exempt,
                     overflow: max(0, candidates.count - maxRequestedAreas))
    }
    public static func ring(_ area: DoorAvoidArea) -> [DoorCoordinate] {
        let n = 16, radius = area.radius / cos(Double.pi / 16)
        var points = (0..<n).map { i -> DoorCoordinate in
            let angle = Double(i) * 2 * Double.pi / Double(n)
            return .init(lat: area.lat + sin(angle) * radius / 111320,
                         lng: area.lng + cos(angle) * radius / (111320 * cos(area.lat * Double.pi / 180)))
        }
        points.append(points[0]); return points
    }
    public struct Constraint: Codable, Equatable, Sendable { public let ok: Bool, reason: String }
    public static func constraints(_ coordinates: [DoorCoordinate], via: [DoorCoordinate] = [], areas: [DoorAvoidArea] = []) -> Constraint {
        guard coordinates.count >= 2 else { return .init(ok: false, reason: "路線資料不足") }
        var lastAlong = -1.0
        for point in via {
            guard let q = closest(coordinates, point), q.distance <= 60, q.along >= lastAlong - 10 else {
                return .init(ok: false, reason: "無法確認路線依序經過指定位置；請把點放到道路上")
            }
            lastAlong = q.along
        }
        for area in areas {
            if let q = closest(coordinates, area.coordinate), q.distance < area.radius - 3 {
                return .init(ok: false, reason: "回傳路線仍穿過避開區域；未自動套用")
            }
        }
        return .init(ok: true, reason: "")
    }
    public struct SignalStyle: Codable, Equatable, Sendable { public let visible: Bool, opacity: Double }
    public static func signalStyle(mode: String, remaining: Double?) -> SignalStyle {
        if mode == "off" { return .init(visible: false, opacity: 0) }
        if mode == "on" { return .init(visible: true, opacity: 1) }
        guard let remaining, remaining.isFinite, remaining <= 500 else { return .init(visible: false, opacity: 0) }
        return .init(visible: true, opacity: min(1, max(0.28, 1 - (remaining - 250) / 350)))
    }
    public static func nextBoundaryMS(_ areas: [DoorAvoidArea], now: Date) -> Double? {
        let milliseconds = (now.timeIntervalSince1970 + 8 * 3600) * 1000
        let withinDay = milliseconds - floor(milliseconds / 86400000) * 86400000
        var next = Double.infinity
        for area in sanitizeAreas(areas) where area.enabled && area.start != area.end {
            for time in [area.start, area.end] {
                var delay = Double(timeNumber(time)) * 60000 - withinDay
                if delay <= 0 { delay += 86400000 }
                next = min(next, delay + 80)
            }
        }
        return next.isFinite ? next : nil
    }
    public static func editVias(_ via: [DoorCoordinate], picked: DoorCoordinate, replaceIndex: Int? = nil) -> [DoorCoordinate]? {
        guard via.count <= maxViaPoints, via.allSatisfy({ point($0) }), point(picked) else { return nil }
        var next = via
        if let index = replaceIndex { guard next.indices.contains(index) else { return nil }; next[index] = picked }
        else { guard next.count < maxViaPoints else { return nil }; next.append(picked) }
        return next
    }
}
