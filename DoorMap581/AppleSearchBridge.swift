import Foundation
import MapKit
import WebKit

final class AppleSearchBridge {
    private struct QueryPlan {
        let term: String
        let alias: String?
        let acceptedNameTokens: [String]
        let brandKey: String?
    }

    weak var webView: WKWebView?
    private var activeSearch: MKLocalSearch?

    func cancel() { activeSearch?.cancel(); activeSearch = nil }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_TW"))
            .replacingOccurrences(
                of: "[^\\p{L}\\p{N}]",
                with: "",
                options: .regularExpression
            )
            .lowercased()
    }

    private func plan(for query: String) -> QueryPlan {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalized(raw)

        let spec: (String, [String], String)?
        switch key {
        case "711", "7eleven", "統一超商":
            spec = ("7-Eleven", ["7eleven", "統一超商"], "7eleven")
        case "全家", "全家便利商店", "familymart":
            spec = ("FamilyMart", ["familymart", "全家"], "familymart")
        case "三媽", "三媽臭臭鍋":
            spec = ("三媽臭臭鍋", ["三媽"], "三媽")
        case "麥當勞", "mcdonald", "mcdonalds":
            spec = ("McDonald's", ["mcdonald", "麥當勞"], "mcdonalds")
        case "50嵐", "50lan":
            spec = ("50 Lan", ["50lan", "50嵐"], "50lan")
        case "清心福全", "chingshinfuchuan":
            spec = ("清心福全", ["清心福全", "chingshinfuchuan"], "清心福全")
        case "胖老爹", "fatdaddy":
            spec = ("Fat Daddy American Fried Chicken", ["fatdaddy", "胖老爹"], "fatdaddy")
        case "築間", "築間幸福鍋物", "jhujian", "zhujian":
            spec = ("築間幸福鍋物", ["築間", "jhujian", "zhujian"], "築間")
        default:
            spec = nil
        }

        guard let spec else {
            return QueryPlan(term: raw, alias: nil, acceptedNameTokens: [], brandKey: nil)
        }
        return QueryPlan(
            term: spec.0,
            alias: raw,
            acceptedNameTokens: spec.1,
            brandKey: spec.2
        )
    }
    func search(
        requestID: String,
        query: String,
        latitude: Double?,
        longitude: Double?,
        radiusM: Double = 3000
    ) {
        activeSearch?.cancel()
        let plan = plan(for: query)

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = plan.term
        request.resultTypes = [.pointOfInterest, .address]

        if let latitude, let longitude {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                latitudinalMeters: min(8000, max(3000, radiusM)) * 2,
                longitudinalMeters: min(8000, max(3000, radiusM)) * 2
            )
        } else {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 23.7, longitude: 120.95),
                span: MKCoordinateSpan(latitudeDelta: 4.5, longitudeDelta: 3.0)
            )
        }

        let search = MKLocalSearch(request: request)
        activeSearch = search
        search.start { [weak self] response, error in
            guard let self else { return }

            if let error {
                self.resolve(
                    requestID: requestID,
                    ok: false,
                    payload: ["message": error.localizedDescription]
                )
                return
            }
            let items = response?.mapItems.prefix(30).compactMap { item -> [String: Any]? in
                let placemark = item.placemark
                let displayName = item.name ?? placemark.name ?? ""
                let normalizedName = self.normalized(displayName)

                if !plan.acceptedNameTokens.isEmpty &&
                    !plan.acceptedNameTokens.contains(where: { normalizedName.contains($0) }) {
                    return nil
                }

                let coordinate = placemark.coordinate
                guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

                let road = [placemark.thoroughfare, placemark.subThoroughfare]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: "")
                let address = [
                    placemark.administrativeArea,
                    placemark.locality,
                    placemark.subLocality,
                    road
                ]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "")

                var result: [String: Any] = [
                    "displayName": displayName,
                    "address": address,
                    "lat": coordinate.latitude,
                    "lng": coordinate.longitude,
                    "source": "apple-mklocalsearch",
                    "feature": item.pointOfInterestCategory?.rawValue.replacingOccurrences(of: "MKPOICategory", with: "").lowercased() ?? "",
                    "sourceLabel": "Apple 地圖"
                ]
                if let alias = plan.alias { result["aliases"] = alias }
                if let brandKey = plan.brandKey { result["appleBrandKey"] = brandKey }
                return result
            } ?? []
            self.resolve(
                requestID: requestID,
                ok: true,
                payload: [
                    "results": items,
                    "query": query,
                    "appleQuery": plan.term
                ]
            )
        }
    }

    private func resolve(requestID: String, ok: Bool, payload: [String: Any]) {
        let args: [Any] = [requestID, ok, payload]
        guard JSONSerialization.isValidJSONObject(args),
              let data = try? JSONSerialization.data(withJSONObject: args),
              let json = String(data: data, encoding: .utf8) else { return }

        let script = """
        window.Door581Native &&
        window.Door581Native._resolve &&
        window.Door581Native._resolve.apply(window.Door581Native, \(json));
        """

        DispatchQueue.main.async { [weak webView] in
            webView?.evaluateJavaScript(script)
        }
    }
}
