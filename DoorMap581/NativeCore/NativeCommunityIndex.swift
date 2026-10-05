import Foundation

/// Decoder and ownership checks from the accepted official-communities v2 index.
/// Missing shape information never manufactures a community outline or entrance.
public struct DoorCommunityIndex: Decodable, Sendable {
    public let version: String
    public let records: [DoorSearchRecord]
    public let scopes: [String: String]
    private enum Keys: String, CodingKey { case version, rows }
    private struct Evidence: Decodable {
        let osmId: String
        let rule: String?
        let retainedOutsideBaselineIndex: Bool?
        let containedAddressKeys: [String]?
    }
    private struct Row: Decodable {
        let record: DoorSearchRecord
        let scope: String?
        let evidence: [Evidence]
        private enum K: String, CodingKey {
            case displayName, lat, lng, aliases, address, category, feature, osmKey, branch
            case locationHint, searchMetadata, source, communityId, osmAliases, identitySources, scope, identityEvidence
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            func text(_ key: K) throws -> String { try c.decodeIfPresent(String.self, forKey: key) ?? "" }
            let name = try c.decode(String.self, forKey: .displayName)
            let lat = try c.decode(Double.self, forKey: .lat), lng = try c.decode(Double.self, forKey: .lng)
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (23...25).contains(lat), (119...122).contains(lng) else {
                throw DecodingError.dataCorruptedError(forKey: .displayName, in: c, debugDescription: "Invalid public identity/coordinate")
            }
            let children = try c.decodeIfPresent([Row].self, forKey: .identitySources) ?? []
            // The accepted schema has only one level of source identity.
            guard children.allSatisfy({ $0.record.identitySources.isEmpty && $0.record.communityId == nil }) else {
                throw DoorOfflineError.invalidManifest
            }
            record = try DoorSearchRecord(displayName: name, lat: lat, lng: lng, aliases: text(.aliases),
                address: text(.address), category: text(.category), feature: text(.feature), osmKey: text(.osmKey),
                branch: text(.branch), locationHint: text(.locationHint), searchMetadata: text(.searchMetadata),
                source: c.decode(String.self, forKey: .source), communityId: c.decodeIfPresent(String.self, forKey: .communityId),
                osmAliases: c.decodeIfPresent([String].self, forKey: .osmAliases) ?? [], identitySources: children.map(\.record))
            scope = try c.decodeIfPresent(String.self, forKey: .scope)
            evidence = try c.decodeIfPresent([Evidence].self, forKey: .identityEvidence) ?? []
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = try c.decode(String.self, forKey: .version)
        let rows = try c.decode([Row].self, forKey: .rows)
        guard version == "tcg-community-1150630-v2", rows.count <= 20_000 else { throw DoorOfflineError.invalidManifest }
        var identities = Set<String>(), aliases = Set<String>(), scopes: [String: String] = [:]
        for row in rows {
            let r = row.record
            guard let id = r.communityId, !id.isEmpty, identities.insert(id).inserted,
                  r.source == "official-community", let scope = row.scope,
                  ["community", "building", "point"].contains(scope),
                  Set(r.osmAliases).count == r.osmAliases.count,
                  r.identitySources.count <= r.osmAliases.count,
                  row.evidence.count == r.osmAliases.count else { throw DoorOfflineError.invalidManifest }
            for alias in r.osmAliases {
                guard alias.range(of: "^(node|way|relation)/[0-9]+$", options: .regularExpression) != nil,
                      aliases.insert(alias).inserted else { throw DoorOfflineError.invalidManifest }
                let sources = r.identitySources.filter { $0.osmKey == alias && $0.source == "offline-index" }
                let evidence = row.evidence.filter { $0.osmId == alias }
                let outside = evidence.contains { $0.retainedOutsideBaselineIndex == true && !($0.containedAddressKeys ?? []).isEmpty }
                guard (sources.count == 1 || outside), evidence.filter({ !($0.rule ?? "").isEmpty }).count == 1 else {
                    throw DoorOfflineError.invalidManifest
                }
            }
            scopes[id] = scope
        }
        records = rows.map(\.record); self.scopes = scopes
    }
}
