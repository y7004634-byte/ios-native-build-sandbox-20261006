import Foundation
import MapKit

/// On-demand MapKit provider. Results stay in memory in the Apple main-map
/// search session; they are never written into the public/offline seed.
@MainActor final class NativeAppleSearchProvider {
    struct Plan {
        let term: String
        let alias: String?
        let acceptedNameTokens: [String]
        let brandKey: String?
    }
    private var active: MKLocalSearch?
    func cancel() { active?.cancel(); active = nil }
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_TW"))
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]", with: "", options: .regularExpression).lowercased()
    }
    static func plan(_ query: String) -> Plan {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let spec: (String, [String], String)?
        switch normalized(raw) {
        case "711", "7eleven", "統一超商": spec = ("7-Eleven", ["7eleven", "統一超商"], "7eleven")
        case "全家", "全家便利商店", "familymart": spec = ("FamilyMart", ["familymart", "全家"], "familymart")
        case "三媽", "三媽臭臭鍋": spec = ("三媽臭臭鍋", ["三媽"], "三媽")
        case "麥當勞", "mcdonald", "mcdonalds": spec = ("McDonald's", ["mcdonald", "麥當勞"], "mcdonalds")
        case "50嵐", "50lan": spec = ("50 Lan", ["50lan", "50嵐"], "50lan")
        case "清心福全", "chingshinfuchuan": spec = ("清心福全", ["清心福全", "chingshinfuchuan"], "清心福全")
        case "胖老爹", "fatdaddy": spec = ("Fat Daddy American Fried Chicken", ["fatdaddy", "胖老爹"], "fatdaddy")
        case "築間", "築間幸福鍋物", "jhujian", "zhujian": spec = ("築間幸福鍋物", ["築間", "jhujian", "zhujian"], "築間")
        default: spec = nil
        }
        guard let spec else { return Plan(term: raw, alias: nil, acceptedNameTokens: [], brandKey: nil) }
        return Plan(term: spec.0, alias: raw, acceptedNameTokens: spec.1, brandKey: spec.2)
    }
    func search(query: String, center: DoorCoordinate?, radiusM: Double) async throws -> [DoorSearchRecord] {
        cancel()
        try Task.checkCancellation()
        let plan = Self.plan(query), request = MKLocalSearch.Request()
        request.naturalLanguageQuery = plan.term
        request.resultTypes = [.pointOfInterest, .address]
        if let center, center.isValid {
            request.region = MKCoordinateRegion(center: .init(latitude: center.lat, longitude: center.lng),
                latitudinalMeters: min(8000, max(3000, radiusM)) * 2,
                longitudinalMeters: min(8000, max(3000, radiusM)) * 2)
        } else {
            request.region = MKCoordinateRegion(center: .init(latitude: 23.7, longitude: 120.95),
                span: .init(latitudeDelta: 4.5, longitudeDelta: 3))
        }
        let search = MKLocalSearch(request: request); active = search
        defer { if active === search { active = nil } }
        let response = try await search.start()
        guard active === search, !Task.isCancelled else { throw CancellationError() }
        // UI pages 30 rows; do not truncate the returned provider pool to a page.
        return response.mapItems.compactMap { item in
            let p = item.placemark, name = item.name ?? item.placemark.name ?? ""
            let normalizedName = Self.normalized(name)
            guard !name.isEmpty, CLLocationCoordinate2DIsValid(p.coordinate),
                  plan.acceptedNameTokens.isEmpty || plan.acceptedNameTokens.contains(where: { normalizedName.contains($0) }) else { return nil }
            let road = [p.thoroughfare, p.subThoroughfare].compactMap { $0 }.filter { !$0.isEmpty }.joined()
            let address = [p.administrativeArea, p.locality, p.subLocality, road].compactMap { $0 }.filter { !$0.isEmpty }.joined()
            return DoorSearchRecord(displayName: name, lat: p.coordinate.latitude, lng: p.coordinate.longitude,
                aliases: plan.alias ?? "", address: address,
                feature: item.pointOfInterestCategory?.rawValue.replacingOccurrences(of: "MKPOICategory", with: "").lowercased() ?? "",
                source: "apple-mklocalsearch", appleBrandKey: plan.brandKey)
        }
    }
}
