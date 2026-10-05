import Foundation

/// Typed port of the accepted fitlock6 search-core; no WebKit/JavaScript runtime.
/// The original source name and identity are never rewritten for matching.
public struct DoorCoordinate: Codable, Equatable, Sendable {
    public var lat: Double
    public var lng: Double
    public init(lat: Double, lng: Double) { self.lat = lat; self.lng = lng }
    public var isValid: Bool { lat.isFinite && lng.isFinite && (-90...90).contains(lat) && (-180...180).contains(lng) }
}

public struct DoorSearchRecord: Codable, Equatable, Sendable {
    public var displayName: String
    public var aliases: String
    public var lat: Double
    public var lng: Double
    public var address: String
    public var category: String
    public var feature: String
    public var osmKey: String
    public var branch: String
    public var locationHint: String
    public var searchMetadata: String
    public var source: String
    public var communityId: String?
    public var osmAliases: [String]
    public var identitySources: [DoorSearchRecord]
    public var appleBrandKey: String?
    public var coordinate: DoorCoordinate { .init(lat: lat, lng: lng) }

    public init(displayName: String, lat: Double, lng: Double, aliases: String = "", address: String = "",
                category: String = "", feature: String = "", osmKey: String = "", branch: String = "",
                locationHint: String = "", searchMetadata: String = "", source: String = "offline-index",
                communityId: String? = nil, osmAliases: [String] = [], identitySources: [DoorSearchRecord] = [],
                appleBrandKey: String? = nil) {
        self.displayName = displayName; self.lat = lat; self.lng = lng; self.aliases = aliases
        self.address = address; self.category = category; self.feature = feature; self.osmKey = osmKey
        self.branch = branch; self.locationHint = locationHint; self.searchMetadata = searchMetadata
        self.source = source; self.communityId = communityId; self.osmAliases = osmAliases
        self.identitySources = identitySources; self.appleBrandKey = appleBrandKey
    }
}

public struct DoorSearchIndex: Decodable {
    public let version: String
    public let rowCount: Int
    public let rows: [DoorSearchRecord]
    private enum CodingKeys: String, CodingKey { case version, rowCount, rows }
    private struct Row: Decodable {
        let record: DoorSearchRecord
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            _ = try c.decode(String.self) // legacy normalized key; recompute with the shared rules
            let name = try c.decode(String.self), aliases = try c.decode(String.self)
            let lat = try c.decode(Double.self), lng = try c.decode(Double.self)
            let address = try c.decode(String.self), category = try c.decode(String.self)
            let feature = try c.decode(String.self), key = try c.decode(String.self)
            let branch = c.isAtEnd ? "" : try c.decode(String.self)
            let hint = c.isAtEnd ? "" : try c.decode(String.self)
            let metadata = c.isAtEnd ? "" : try c.decode(String.self)
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  DoorCoordinate(lat: lat, lng: lng).isValid else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid source name/coordinate")
            }
            record = .init(displayName: name, lat: lat, lng: lng, aliases: aliases, address: address,
                           category: category, feature: feature, osmKey: key, branch: branch,
                           locationHint: hint, searchMetadata: metadata)
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        rowCount = try c.decode(Int.self, forKey: .rowCount)
        rows = try c.decode([Row].self, forKey: .rows).map(\.record)
        guard rowCount == rows.count else {
            throw DecodingError.dataCorruptedError(forKey: .rowCount, in: c, debugDescription: "Index row count mismatch")
        }
    }
}

public enum DoorSearchCore {
    public static let referenceSHA256 = "8a05dba5db6837c3d26d18b0b3685f028fc23a192b6b78fadb4c4227ca6185d3"
    public static let radiusM = 3000.0
    private static let variants: [Unicode.Scalar: String] = ["臺":"台","湾":"灣","锅":"鍋","气":"氣","麦":"麥","当":"當","劳":"勞","岚":"嵐","妈":"媽","鸡":"雞","门":"門","号":"號","区":"區"]
    private static let removed = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
    // Alias families are normalization only, never lists of known store coordinates.
    private static let aliases = [["711","7eleven","7-Eleven","7-11","統一超商"], ["全家","全家便利商店","FamilyMart","Family Mart"]]
    private static let categories = [
        ["火鍋","鍋物","hotpot","hot_pot","shabu_shabu","涮涮鍋","臭臭鍋"],
        ["加油站","油站","fuel","gasstation","petrolstation"], ["咖啡","咖啡店","cafe","coffee_shop"],
        ["藥局","藥房","pharmacy"], ["超市","超級市場","supermarket"], ["便利商店","超商","convenience"],
        ["餐廳","餐館","restaurant"], ["銀行","bank"], ["醫院","hospital"], ["診所","clinic"]
    ]
    private static let families = (aliases + categories).map { $0.map(normalize) }

    public static func normalize(_ value: String) -> String {
        let mapped = value.precomposedStringWithCompatibilityMapping.unicodeScalars.map { variants[$0] ?? String($0) }.joined().lowercased()
        return String(String.UnicodeScalarView(mapped.unicodeScalars.filter { !removed.contains($0) }))
    }
    public static func tokens(_ value: String) -> [String] {
        let nfkc = value.precomposedStringWithCompatibilityMapping.replacingOccurrences(of: "([0-9])[-－](?=[0-9])", with: "$1", options: .regularExpression)
        return nfkc.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，。．·・_()（）[]【】"))).map(normalize).filter { !$0.isEmpty }
    }
    public static func meters(_ a: DoorCoordinate, _ b: DoorCoordinate) -> Double {
        guard a.isValid, b.isValid else { return .infinity }
        return hypot((a.lng - b.lng) * 111320 * cos((a.lat + b.lat) * .pi / 360), (a.lat - b.lat) * 111320)
    }
    public static func oneEdit(_ a: String, _ b: String) -> Bool { oneEdit(Array(a.utf16), Array(b.utf16)) }
    private static func oneEdit(_ a: [UInt16], _ b: [UInt16]) -> Bool {
        if abs(a.count - b.count) > 1 { return false }
        if a == b { return true }
        var i = 0, j = 0, n = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            n += 1
            if n > 1 {
                return a.count == b.count && i > 0 && a[i] == b[i-1] && a[i-1] == b[i]
                    && Array(a.dropFirst(i+1)) == Array(b.dropFirst(i+1))
            }
            if a.count >= b.count { i += 1 }
            if b.count >= a.count { j += 1 }
        }
        return n + ((i < a.count || j < b.count) ? 1 : 0) <= 1
    }
    private static func fuzzyContains(_ field: String, _ token: String) -> Bool {
        let t = Array(token.utf16)
        guard t.count >= 4, !t.allSatisfy({ (48...57).contains($0) }) else { return false }
        let f = Array(field.utf16)
        for length in [t.count, t.count - 1, t.count + 1] where length >= 3 && length <= f.count {
            for i in 0...(f.count - length) where oneEdit(t, Array(f[i..<(i + length)])) { return true }
        }
        return false
    }
    public struct Plan: Sendable {
        fileprivate let tokens: [String]
        fileprivate let normalized: String
        fileprivate let parts: [(String, [String], Bool)]
    }
    public static func compile(_ query: String) -> Plan {
        let ts = tokens(query)
        let parts = ts.map { t -> (String, [String], Bool) in
            let matched = families.filter { $0.contains(t) }
            var seen = Set<String>()
            let expanded = ([t] + matched.flatMap { $0 }).filter { seen.insert($0).inserted }
            return (t, expanded, !matched.isEmpty)
        }
        return Plan(tokens: ts, normalized: normalize(query), parts: parts)
    }
    public struct Prepared: Sendable {
        public let record: DoorSearchRecord
        fileprivate let name: String, branch: String, combined: String
        fileprivate let names: [String], location: [String], meta: [String]
        fileprivate let sourceFields: [Prepared]
        public init(_ record: DoorSearchRecord) {
            self.record = record
            name = normalize(record.displayName); branch = normalize(record.branch)
            combined = normalize(record.displayName + record.branch)
            names = ([record.displayName] + record.aliases.components(separatedBy: "|") + [record.branch]).map(normalize).filter { !$0.isEmpty }
            location = [record.address, record.locationHint.components(separatedBy: "座標").first ?? ""].map(normalize).filter { !$0.isEmpty }
            meta = ([record.category,record.feature] + record.searchMetadata.components(separatedBy: CharacterSet(charactersIn: "|;"))).map(normalize).filter { !$0.isEmpty }
            sourceFields = record.communityId == nil ? [] : record.identitySources.filter { record.osmAliases.contains($0.osmKey) }.map { r in
                var leaf = r; leaf.identitySources = []; leaf.communityId = nil
                return Prepared(leaf)
            }
        }
    }
    public struct Match: Equatable, Sendable { public let fuzzy: Bool, exact: Bool, specific: Bool }
    private static func matchFields(_ f: Prepared, _ plan: Plan) -> Match? {
        guard !plan.tokens.isEmpty else { return nil }
        var fuzzy = false
        for (token, variants, identityOnly) in plan.parts {
            let hay = f.names + f.meta + [f.combined] + (identityOnly ? [] : f.location)
            if variants.contains(where: { t in hay.contains { $0.contains(t) } }) { continue }
            if f.names.contains(where: { fuzzyContains($0,token) }) { fuzzy = true; continue }
            return nil
        }
        let q = plan.normalized
        let specific = plan.tokens.count > 1 || q.utf16.count >= 5 || (!f.branch.isEmpty && f.branch == q)
        let exact = (!f.branch.isEmpty && f.branch == q) || (specific && (f.name == q || f.combined == q))
        return Match(fuzzy: fuzzy, exact: exact, specific: specific)
    }
    public static func match(_ f: Prepared, _ plan: Plan) -> Match? {
        var best = matchFields(f,plan)
        for source in f.sourceFields {
            guard let found = matchFields(source,plan) else { continue }
            if best == nil || (found.exact && !best!.exact) || (found.exact == best!.exact && best!.fuzzy && !found.fuzzy) { best = found }
        }
        return best
    }
    public static func key(_ r: DoorSearchRecord) -> String {
        if let id = r.communityId, !id.isEmpty { return "official-community:" + id }
        let pair = r.osmKey.components(separatedBy: CharacterSet(charactersIn: "/:"))
        if pair.count > 1, !pair[0].isEmpty, !pair[1].isEmpty {
            let type = pair[0].lowercased()
            return (["n":"node","w":"way","r":"relation"][type] ?? type) + ":" + pair[1]
        }
        return String(format: "%.5f:%.5f:", locale: Locale(identifier:"en_US_POSIX"), r.lat, r.lng) + r.displayName
    }
    public static func locationText(_ r: DoorSearchRecord) -> String {
        var items: [String] = []
        if !r.branch.isEmpty && !normalize(r.displayName).contains(normalize(r.branch)) { items.append(r.branch) }
        items.append(!r.address.isEmpty ? r.address : !r.locationHint.isEmpty ? r.locationHint : String(format:"座標 %.5f, %.5f",locale:Locale(identifier:"en_US_POSIX"),r.lat,r.lng))
        if r.source == "official-community" { items.append("官方社區地址點（非入口）") }
        return items.joined(separator:" · ")
    }
    public struct Result: Sendable, Equatable {
        public let record: DoorSearchRecord
        public let distanceM: Double?
        public let matchKind: String
        public fileprivate(set) var matchPriority: Int
        fileprivate let ordinal: Int
        public var id: String { key(record) }
    }
    public static func rank(_ groups: [[Prepared]], query: String, center: DoorCoordinate?) -> [Result] {
        let plan = compile(query)
        var officialOSM = Set<String>(), seen = Set<String>(), out: [Result] = []
        for group in groups {
            for f in group where f.record.communityId != nil && match(f,plan) != nil {
                for id in f.record.osmAliases { officialOSM.insert(key(.init(displayName:"",lat:0,lng:0,osmKey:id))) }
            }
        }
        for group in groups {
            for f in group {
                let r = f.record
                guard r.coordinate.isValid, let match = match(f,plan) else { continue }
                let id = key(r)
                if r.communityId == nil && officialOSM.contains(id) { continue }
                guard seen.insert(id).inserted else { continue }
                out.append(.init(record:r,distanceM:center.map { meters($0,r.coordinate) },matchKind:match.fuzzy ? "typo-tolerant":"direct",matchPriority:match.exact ? 0 : (match.specific && match.fuzzy ? 2:1),ordinal:out.count))
            }
        }
        if out.filter({ $0.matchPriority == 0 }).count > 2 {
            for i in out.indices where out[i].matchPriority == 0 { out[i].matchPriority = 1 }
        }
        out.sort {
            if $0.matchPriority != $1.matchPriority { return $0.matchPriority < $1.matchPriority }
            let a = $0.distanceM ?? .infinity, b = $1.distanceM ?? .infinity
            if a != b { return a < b }
            let cmp = $0.record.displayName.compare($1.record.displayName,options:[],locale:Locale(identifier:"zh_Hant"))
            return cmp == .orderedSame ? $0.ordinal < $1.ordinal : cmp == .orderedAscending
        }
        return out
    }
}
