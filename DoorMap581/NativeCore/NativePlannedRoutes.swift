import Foundation

public struct DoorPlannedRoute: Codable, Equatable, Sendable {
    public struct Maneuver: Codable, Equatable, Sendable {
        public var type: String, modifier: String, name: String
        public var distance: Double
        public var location: DoorCoordinate?
        public var routeIndex: Int
        public init(type: String, modifier: String = "", name: String = "", distance: Double = 0, location: DoorCoordinate? = nil, routeIndex: Int = 0) {
            self.type = type; self.modifier = modifier; self.name = name; self.distance = distance; self.location = location; self.routeIndex = routeIndex
        }
    }
    public var coordinates: [DoorCoordinate]
    public var distance: Double, duration: Double
    public var maneuvers: [Maneuver]
    public var avoidApplied: [String], endpointExempt: [String]
    public var label: String
    public init(coordinates: [DoorCoordinate], distance: Double, duration: Double, maneuvers: [Maneuver] = [],
                avoidApplied: [String] = [], endpointExempt: [String] = [], label: String = "") {
        self.coordinates = coordinates; self.distance = distance; self.duration = duration; self.maneuvers = maneuvers
        self.avoidApplied = avoidApplied; self.endpointExempt = endpointExempt; self.label = label
    }
    public func validate() throws {
        guard coordinates.count >= 2, coordinates.count <= 100_000, coordinates.allSatisfy(\.isValid),
              distance.isFinite, distance >= 0, duration.isFinite, duration >= 0, maneuvers.count <= 10000 else { throw DoorPersonalError.invalidRoute }
    }
}

public enum DoorPersonalError: Error, Equatable, LocalizedError {
    case invalidRoute, invalidControlPoint, tooManyPoints, inactiveEditor, staleResult, unfinishedPlan
    case invalidMemory, invalidBackup, tooLarge, storageFailure
    public var errorDescription: String? {
        switch self {
        case .invalidRoute: return "路線資料不完整；原行程保留。"
        case .invalidControlPoint: return "控制點無效或已不存在。"
        case .tooManyPoints: return "這條路線最多 64 個控制點。"
        case .inactiveEditor: return "請先開啟編輯路線。"
        case .staleResult: return "這筆規劃已過期，未套用。"
        case .unfinishedPlan: return "新路線尚未完成，請稍候或撤銷錯誤點。"
        case .invalidMemory: return "路線記憶格式、來源或長度不符。"
        case .invalidBackup: return "不是可支援的 Door Map 個人備份。"
        case .tooLarge: return "個人備份超過 2.5 MB。"
        case .storageFailure: return "未能儲存，原資料未變更。"
        }
    }
}

/// Planning-only edit state. It has no GPS input or passive learning path.
public struct DoorRouteEditor: Sendable {
    public struct Snapshot: Codable, Equatable, Sendable {
        public var via: [DoorCoordinate], record: DoorPlannedRoute, alternates: [DoorPlannedRoute]
        public var validVia: [DoorCoordinate], error: String
        public init(via: [DoorCoordinate], record: DoorPlannedRoute, alternates: [DoorPlannedRoute] = [], validVia: [DoorCoordinate]? = nil, error: String = "") {
            self.via = via; self.record = record; self.alternates = alternates; self.validVia = validVia ?? via; self.error = error
        }
    }
    public enum Change: Sendable { case add(DoorCoordinate), move(Int, DoorCoordinate), delete(Int) }
    public struct Finished: Sendable { public let snapshot: Snapshot, base: Snapshot, changed: Bool }
    public private(set) var active = false
    public private(set) var version: UInt64 = 0
    public private(set) var selected: Int?
    public private(set) var current: Snapshot?
    public private(set) var base: Snapshot?
    public private(set) var history: [Snapshot] = []
    public var ready: Bool { active && current?.error == "" && current?.via == current?.validVia && (current?.record.coordinates.count ?? 0) > 1 }
    public var changed: Bool { active && current?.via != base?.via }
    public init() {}
    @discardableResult public mutating func begin(_ snapshot: Snapshot) throws -> UInt64 {
        guard snapshot.via.count <= 64, snapshot.via.allSatisfy({ DoorDeliveryCore.point($0) }) else { throw DoorPersonalError.invalidControlPoint }
        try snapshot.record.validate()
        version &+= 1; active = true; base = snapshot; current = snapshot
        current?.validVia = snapshot.via; current?.error = ""; selected = nil; history = []; return version
    }
    @discardableResult public mutating func change(_ change: Change) throws -> UInt64 {
        guard active, var snapshot = current else { throw DoorPersonalError.inactiveEditor }
        switch change {
        case .add(let point):
            guard DoorDeliveryCore.point(point) else { throw DoorPersonalError.invalidControlPoint }
            guard snapshot.via.count < 64 else { throw DoorPersonalError.tooManyPoints }; snapshot.via.append(point)
        case .move(let index, let point):
            guard snapshot.via.indices.contains(index), DoorDeliveryCore.point(point) else { throw DoorPersonalError.invalidControlPoint }
            snapshot.via[index] = point
        case .delete(let index):
            guard snapshot.via.indices.contains(index) else { throw DoorPersonalError.invalidControlPoint }; snapshot.via.remove(at: index)
        }
        history.append(current!); if history.count > 100 { history.removeFirst() }
        snapshot.error = ""; current = snapshot; selected = nil; version &+= 1; return version
    }
    @discardableResult public mutating func undo() -> Bool {
        guard active, let snapshot = history.popLast() else { return false }
        current = snapshot; selected = nil; version &+= 1; return true
    }
    public mutating func clear() {
        guard active, let base, let current else { return }
        history.append(current); self.current = base; self.current?.validVia = base.via; self.current?.error = ""
        selected = nil; version &+= 1
    }
    @discardableResult public mutating func accept(version: UInt64, route: DoorPlannedRoute, alternates: [DoorPlannedRoute] = []) throws -> Bool {
        guard active, self.version == version, var snapshot = current else { return false }
        try route.validate()
        guard DoorDeliveryCore.constraints(route.coordinates, via: snapshot.via).ok else { throw DoorPersonalError.invalidRoute }
        snapshot.record = route; snapshot.alternates = alternates; snapshot.validVia = snapshot.via; snapshot.error = ""; current = snapshot; return true
    }
    public mutating func fail(version: UInt64, message: String) { if active && self.version == version { current?.error = message.isEmpty ? "規劃失敗" : message } }
    public mutating func cancel() -> Snapshot? {
        guard active else { return nil }; active = false; version &+= 1; history = []; selected = nil; return base
    }
    public mutating func finish() throws -> Finished {
        guard ready, let current, let base else { throw DoorPersonalError.unfinishedPlan }
        let result = Finished(snapshot: current, base: base, changed: changed)
        active = false; version &+= 1; history = []; selected = nil; return result
    }
}

public struct DoorRouteMemory: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case edit, alternative }
    public var id: String, source: Source, points: [DoorCoordinate], heading: Double, count: Int, updatedAt: Double
    public init(id: String, source: Source, points: [DoorCoordinate], heading: Double, count: Int = 1, updatedAt: Double) {
        self.id = id; self.source = source; self.points = points; self.heading = heading; self.count = count; self.updatedAt = updatedAt
    }
}

public enum DoorPlannedMemory {
    public static let maxMemories = 1000
    public static func length(_ points: [DoorCoordinate]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + DoorDeliveryCore.meters($1.0, $1.1) }
    }
    public static func heading(_ a: DoorCoordinate, _ b: DoorCoordinate) -> Double {
        let value = atan2((b.lng - a.lng) * cos(a.lat * Double.pi / 180), b.lat - a.lat) * 180 / Double.pi + 360
        return value.truncatingRemainder(dividingBy: 360)
    }
    public static func angle(_ a: Double, _ b: Double) -> Double { abs(DoorCameraGeometry.delta(a, b)) }
    /// Iterative RDP produces the original ordering without recursive stack risk.
    public static func simplify(_ points: [DoorCoordinate], tolerance: Double = 18) -> [DoorCoordinate] {
        guard points.count >= 3 else { return points }
        var kept = Set([0, points.count - 1]), stack = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last - first >= 2 else { continue }
            var maximum = 0.0, at = first
            for i in (first+1)..<last {
                let d = DoorDeliveryCore.project(points[i], points[first], points[last]).distance
                if d > maximum { maximum = d; at = i }
            }
            if maximum > tolerance { kept.insert(at); stack.append((at, last)); stack.append((first, at)) }
        }
        return kept.sorted().map { points[$0] }
    }
    public static func memoryID(_ points: [DoorCoordinate]) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        let encoded = points.map { [String(format: "%.5f", locale: locale, $0.lng), String(format: "%.5f", locale: locale, $0.lat)] }
        let bytes = (try? JSONSerialization.data(withJSONObject: encoded, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        var hash: UInt32 = 2166136261
        for byte in bytes { hash ^= UInt32(byte); hash = hash &* 16777619 }
        return "p-" + String(hash, radix: 16)
    }
    public static func differences(before: DoorPlannedRoute, after: DoorPlannedRoute, source: DoorRouteMemory.Source, nowMS: Double) -> [DoorRouteMemory] {
        let a = before.coordinates, b = after.coordinates
        guard a.count >= 2 && b.count >= 2 else { return [] }
        let sampled = simplify(b, tolerance: 10); guard sampled.count <= 800 else { return [] }
        let different = sampled.map { (DoorDeliveryCore.closest(a, $0)?.distance ?? 0) > 35 }
        var groups: [DoorRouteMemory] = [], i = 0
        while i < sampled.count {
            defer { i += 1 }
            if !different[i] { continue }
            let start = max(0, i - 1)
            while i + 1 < sampled.count && different[i+1] { i += 1 }
            let end = min(sampled.count - 1, i + 1), path = Array(sampled[start...end])
            guard !different[start], !different[end], path.count >= 3, length(path) <= 3000, length(path) >= 45 else { continue }
            let compact = simplify(path, tolerance: 20)
            guard compact.count <= 18, DoorDeliveryCore.meters(compact[0], compact.last!) >= 40 else { continue }
            groups.append(.init(id: memoryID(compact), source: source, points: compact, heading: heading(compact[0], compact.last!), updatedAt: nowMS))
        }
        return Array(groups.prefix(8))
    }
    public static func sanitize(_ values: [DoorRouteMemory], nowMS: Double) throws -> [DoorRouteMemory] {
        guard values.count <= maxMemories else { throw DoorPersonalError.invalidMemory }
        return try values.map { original in
            var row = original
            guard row.points.count >= 3, row.points.count <= 18, row.points.allSatisfy({ DoorDeliveryCore.point($0) }), length(row.points) <= 3500 else { throw DoorPersonalError.invalidMemory }
            row.id = memoryID(row.points); row.heading = heading(row.points[0], row.points.last!)
            row.count = max(1, min(1000, row.count))
            row.updatedAt = max(0, min(nowMS + 86400000, row.updatedAt.isFinite ? row.updatedAt : 0))
            return row
        }
    }
    public struct Candidate: Equatable, Sendable { public let row: DoorRouteMemory, along: Double }
    public static func candidates(_ values: [DoorRouteMemory], route: DoorPlannedRoute) -> [Candidate] {
        let cs = route.coordinates; guard cs.count >= 2 else { return [] }
        var index: [String: [DoorRouteMemory]] = [:]
        func key(_ x: Int, _ y: Int) -> String { "\(x):\(y)" }
        for row in values where !row.points.isEmpty {
            let p = row.points[0], x = Int(floor(p.lng * 100)), y = Int(floor(p.lat * 100))
            index[key(x, y), default: []].append(row)
        }
        var found: [String: DoorRouteMemory] = [:], order: [String] = []
        let step = max(1, Int(ceil(Double(cs.count) / 200)))
        for i in stride(from: 0, to: cs.count, by: step) {
            let x = Int(floor(cs[i].lng * 100)), y = Int(floor(cs[i].lat * 100))
            for dx in -1...1 { for dy in -1...1 {
                for row in index[key(x+dx, y+dy)] ?? [] {
                    if found[row.id] == nil { order.append(row.id) }; found[row.id] = row
                }
            }}
        }
        let recent = order.enumerated().compactMap { i, id -> (Int, DoorRouteMemory)? in found[id].map { (i, $0) } }
            .sorted { $0.1.updatedAt == $1.1.updatedAt ? $0.0 < $1.0 : $0.1.updatedAt > $1.1.updatedAt }.prefix(96)
        var output: [(Int, Candidate)] = []
        for (i, row) in recent {
            guard let enter = DoorDeliveryCore.closest(cs, row.points[0]), let exit = DoorDeliveryCore.closest(cs, row.points.last!),
                  enter.distance <= 85, exit.distance <= 85, exit.along - enter.along >= 45,
                  angle(heading(enter.coordinate, exit.coordinate), row.heading) <= 55 else { continue }
            if row.points.dropFirst().dropLast().allSatisfy({ (DoorDeliveryCore.closest(cs, $0)?.distance ?? 0) < 25 }) { continue }
            output.append((i, .init(row: row, along: enter.along)))
        }
        output.sort { a, b in
            if a.1.row.source != b.1.row.source { return a.1.row.source == .edit }
            if a.1.row.count != b.1.row.count { return a.1.row.count > b.1.row.count }
            if a.1.row.updatedAt != b.1.row.updatedAt { return a.1.row.updatedAt > b.1.row.updatedAt }
            return a.0 < b.0
        }
        return output.prefix(3).map(\.1)
    }
    public static func reasonable(baseline: DoorPlannedRoute, candidate: DoorPlannedRoute) -> Bool {
        candidate.distance.isFinite && candidate.duration.isFinite && candidate.distance <= baseline.distance * 1.18 + 120 && candidate.duration <= baseline.duration * 1.20 + 35
    }
}
