import Foundation
import MapKit
import UIKit

struct NativeLayerBounds: Sendable {
    let north: Double, south: Double, east: Double, west: Double
    var valid: Bool {
        [north,south,east,west].allSatisfy(\.isFinite) && north >= south && east >= west &&
        north >= 20 && south <= 27 && east >= 117 && west <= 123
    }
}

struct NativeLayerFeature: Sendable {
    enum Kind: String, Sendable { case communityPoint, communityPolygon, road, building, doorplate }
    enum Geometry: Sendable {
        case point(DoorCoordinate)
        case line([DoorCoordinate])
        case polygon([[DoorCoordinate]])
    }
    let id: String
    let kind: Kind
    let geometry: Geometry
    let title: String
    let subtitle: String
}

struct NativePublicLayerSnapshot: Sendable {
    let features: [NativeLayerFeature]
    let communityCount: Int
    let roadCount: Int
    let buildingCount: Int
    let doorplateCount: Int
    let loadedTiles: Int
}

actor NativePublicLayerStore {
    private let resources: NativePublicResources
    private struct Manifest {
        let zoom: Int
        let paths: [String: String]
    }
    private var community: Manifest?
    private var official: Manifest?
    private var osm: Manifest?

    init(resources: NativePublicResources) { self.resources = resources }

    func snapshot(bounds: NativeLayerBounds, zoom: Double, route: [DoorCoordinate],
                  destination: DoorCoordinate?, rider: DoorCoordinate?, heading: Double?) async throws -> NativePublicLayerSnapshot {
        guard bounds.valid else { return .init(features: [], communityCount: 0, roadCount: 0, buildingCount: 0, doorplateCount: 0, loadedTiles: 0) }
        async let communityManifest = manifest(.community)
        async let osmManifest = manifest(.osm)
        async let officialManifest = manifest(.official)
        let (cm, om, am) = try await (communityManifest, osmManifest, officialManifest)
        var features: [NativeLayerFeature] = []
        var communities = 0, roads = 0, buildings = 0, doorplates = 0, loaded = 0

        if zoom >= 15 {
            for key in tileKeys(bounds: bounds, zoom: cm.zoom, style: .slash, limit: 24) {
                guard let path = cm.paths[key] else { continue }
                try Task.checkCancellation()
                let rows = try decodeGeoJSON(try await resources.data(path), source: .community)
                features.append(contentsOf: rows); communities += rows.count; loaded += 1
            }
        }
        if zoom >= 15.5 {
            for key in tileKeys(bounds: bounds, zoom: om.zoom, style: .dash, limit: 24) {
                guard let path = om.paths[key] else { continue }
                try Task.checkCancellation()
                let rows = try decodeGeoJSON(try await resources.data(path), source: .osm)
                for row in rows {
                    switch row.kind {
                    case .road:
                        if zoom >= 16.4 { features.append(row); roads += 1 }
                    case .building:
                        features.append(row); buildings += 1
                    default: break
                    }
                }
                loaded += 1
            }
        }
        if zoom >= 17.35 {
            var candidates: [NativeLayerFeature] = []
            for key in tileKeys(bounds: bounds, zoom: am.zoom, style: .slash, limit: 36) {
                guard let path = am.paths[key] else { continue }
                try Task.checkCancellation()
                candidates.append(contentsOf: try decodeDoorplates(try await resources.data(path)))
                loaded += 1
            }
            let chosen = chooseDoorplates(candidates, zoom: zoom, bounds: bounds, route: route,
                                          destination: destination, rider: rider, heading: heading)
            features.append(contentsOf: chosen); doorplates = chosen.count
        }
        return .init(features: features, communityCount: communities, roadCount: roads,
                     buildingCount: buildings, doorplateCount: doorplates, loadedTiles: loaded)
    }

    private enum ManifestKind { case community, official, osm }
    private enum KeyStyle { case slash, dash }

    private func manifest(_ kind: ManifestKind) async throws -> Manifest {
        switch kind {
        case .community:
            if let community { return community }
            let value = try decodeManifest(try await resources.data("offline/taichung-community-1150630-v2/manifest.json"),
                                           zoomKeys: ["tileZoom"], slashKeys: true)
            community = value; return value
        case .official:
            if let official { return official }
            let value = try decodeManifest(try await resources.data("offline/taichung-official-202608-v1/manifest.json"),
                                           zoomKeys: ["gridZoom"], slashKeys: true)
            official = value; return value
        case .osm:
            if let osm { return osm }
            let value = try decodeManifest(try await resources.data("native-data/osm-manifest.json"),
                                           zoomKeys: ["tileZoom"], slashKeys: false)
            osm = value; return value
        }
    }

    private func decodeManifest(_ data: Data, zoomKeys: [String], slashKeys: Bool) throws -> Manifest {
        guard data.count <= 8_000_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tiles = object["tiles"] as? [String: Any] else { throw DoorOfflineError.invalidManifest }
        let zoom = zoomKeys.compactMap { object[$0] as? Int }.first ?? 0
        guard (10...18).contains(zoom), tiles.count <= 20_000 else { throw DoorOfflineError.invalidManifest }
        var paths: [String: String] = [:]
        for (key, raw) in tiles {
            guard let row = raw as? [String: Any], let path = row["path"] as? String else { continue }
            let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
            guard DoorOfflineManifest.safePath(clean) else { throw DoorOfflineError.unsafePath }
            paths[key] = clean
        }
        guard !paths.isEmpty else { throw DoorOfflineError.invalidManifest }
        return .init(zoom: zoom, paths: paths)
    }

    private func tileKeys(bounds: NativeLayerBounds, zoom: Int, style: KeyStyle, limit: Int) -> [String] {
        let nw = tileXY(lat: bounds.north, lng: bounds.west, zoom: zoom)
        let se = tileXY(lat: bounds.south, lng: bounds.east, zoom: zoom)
        let minX = min(nw.x, se.x), maxX = max(nw.x, se.x)
        let minY = min(nw.y, se.y), maxY = max(nw.y, se.y)
        var keys: [String] = []
        for y in minY...maxY {
            for x in minX...maxX {
                keys.append(style == .slash ? "\(x)/\(y)" : "\(x)-\(y)")
                if keys.count >= limit { return keys }
            }
        }
        return keys
    }

    private func tileXY(lat: Double, lng: Double, zoom: Int) -> (x: Int, y: Int) {
        let n = pow(2.0, Double(zoom))
        let boundedLat = min(85.05112878, max(-85.05112878, lat))
        let x = Int(floor((lng + 180) / 360 * n))
        let rad = boundedLat * .pi / 180
        let y = Int(floor((1 - asinh(tan(rad)) / .pi) / 2 * n))
        let maxIndex = Int(n) - 1
        return (min(maxIndex, max(0, x)), min(maxIndex, max(0, y)))
    }

    private enum GeoSource: Equatable { case community, osm }

    private func decodeGeoJSON(_ data: Data, source: GeoSource) throws -> [NativeLayerFeature] {
        guard data.count <= 4_000_000,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["features"] as? [[String: Any]], rows.count <= 20_000 else { throw DoorOfflineError.invalidManifest }
        var out: [NativeLayerFeature] = []; out.reserveCapacity(rows.count)
        for row in rows {
            guard let id = row["id"] as? String,
                  let properties = row["properties"] as? [String: Any],
                  let geometry = row["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String else { continue }
            let name = (properties["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let address = properties["address"] as? String ?? ""
            if source == .community {
                let role = properties["role"] as? String ?? ""
                if type == "Point", let point = point(geometry["coordinates"]) {
                    out.append(.init(id: id, kind: .communityPoint, geometry: .point(point),
                                     title: name, subtitle: address))
                } else if ["Polygon","MultiPolygon"].contains(type), let rings = polygon(geometry) {
                    out.append(.init(id: id, kind: .communityPolygon, geometry: .polygon(rings),
                                     title: name, subtitle: address + (role.isEmpty ? "" : " · " + role)))
                }
            } else if properties["building"] != nil, ["Polygon","MultiPolygon"].contains(type), let rings = polygon(geometry) {
                out.append(.init(id: id, kind: .building, geometry: .polygon(rings), title: name, subtitle: "OSM 建物"))
            } else if properties["highway"] != nil, type == "LineString", let line = line(geometry["coordinates"]) {
                out.append(.init(id: id, kind: .road, geometry: .line(line), title: name, subtitle: properties["highway"] as? String ?? ""))
            }
        }
        return out
    }

    private func decodeDoorplates(_ data: Data) throws -> [NativeLayerFeature] {
        guard data.count <= 2_000_000,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["rows"] as? [[Any]], rows.count <= 12_000 else { throw DoorOfflineError.invalidManifest }
        var out: [NativeLayerFeature] = []; out.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            guard row.count >= 4, let lat = row[0] as? Double, let lng = row[1] as? Double,
                  let number = row[2] as? String, let road = row[3] as? String else { continue }
            let point = DoorCoordinate(lat: lat, lng: lng)
            guard point.isValid, !number.isEmpty else { continue }
            let parts = row.dropFirst(3).prefix(4).compactMap { $0 as? String }.filter { !$0.isEmpty }
            out.append(.init(id: "door:\(lat):\(lng):\(index)", kind: .doorplate, geometry: .point(point),
                             title: number, subtitle: parts.joined()))
        }
        return out
    }

    private func point(_ raw: Any?) -> DoorCoordinate? {
        guard let xy = raw as? [Double], xy.count >= 2 else { return nil }
        let point = DoorCoordinate(lat: xy[1], lng: xy[0]); return point.isValid ? point : nil
    }
    private func line(_ raw: Any?) -> [DoorCoordinate]? {
        guard let rows = raw as? [[Double]], rows.count >= 2 else { return nil }
        let points = rows.compactMap { point($0) }; return points.count >= 2 ? points : nil
    }
    private func polygon(_ geometry: [String: Any]) -> [[DoorCoordinate]]? {
        let type = geometry["type"] as? String ?? ""
        var rawRings: [[[Double]]] = []
        if type == "Polygon" { rawRings = geometry["coordinates"] as? [[[Double]]] ?? [] }
        else if type == "MultiPolygon" { rawRings = (geometry["coordinates"] as? [[[[Double]]]])?.flatMap { $0 } ?? [] }
        let rings = rawRings.compactMap { row -> [DoorCoordinate]? in
            let points = row.compactMap { point($0) }
            return points.count >= 3 ? points : nil
        }
        return rings.isEmpty ? nil : rings
    }

    private func chooseDoorplates(_ rows: [NativeLayerFeature], zoom: Double, bounds: NativeLayerBounds,
                                  route: [DoorCoordinate], destination: DoorCoordinate?,
                                  rider: DoorCoordinate?, heading: Double?) -> [NativeLayerFeature] {
        let center = DoorCoordinate(lat: (bounds.north + bounds.south) / 2, lng: (bounds.east + bounds.west) / 2)
        let routeSamples: [DoorCoordinate] = {
            guard route.count > 256 else { return route }
            let step = max(1, route.count / 256); return stride(from: 0, to: route.count, by: step).map { route[$0] }
        }()
        let limit = zoom >= 19.2 ? 180 : zoom >= 18.3 ? 110 : 60
        return rows.compactMap { feature -> (Double, NativeLayerFeature)? in
            guard case .point(let p) = feature.geometry else { return nil }
            var score = DoorSearchCore.meters(center, p)
            if let destination {
                let d = DoorSearchCore.meters(destination, p)
                if d <= 220 { score -= 6000 - d * 4 }
            }
            if !routeSamples.isEmpty {
                let d = routeSamples.map { DoorSearchCore.meters($0, p) }.min() ?? .infinity
                if d <= 85 { score -= 4500 - d * 8 }
                else if d <= 170 { score -= 1800 - d * 2 }
            }
            if let rider, let heading, heading.isFinite {
                let d = DoorSearchCore.meters(rider, p)
                if d <= 500 {
                    let bearing = Self.bearing(rider, p)
                    let delta = abs(((bearing - heading + 540).truncatingRemainder(dividingBy: 360)) - 180)
                    if delta <= 90 { score -= 350 }
                }
            }
            return (score, feature)
        }.sorted { $0.0 < $1.0 }.prefix(limit).map { $0.1 }
    }

    private static func bearing(_ a: DoorCoordinate, _ b: DoorCoordinate) -> Double {
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180, d = (b.lng - a.lng) * .pi / 180
        let y = sin(d) * cos(p2), x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(d)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}

@MainActor final class NativePublicLayerPresenter {
    struct Stats {
        var community = 0, roads = 0, buildings = 0, doorplates = 0, tiles = 0, refreshes = 0
    }
    private weak var map: MKMapView?
    private let store: NativePublicLayerStore
    private let scene = NativeSceneOverlay()
    private var renderer: NativeSceneRenderer?
    private var annotations: [NativeSceneAnnotation] = []
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private(set) var stats = Stats()
    var onChange: (() -> Void)?

    init(map: MKMapView, resources: NativePublicResources) {
        self.map = map; store = NativePublicLayerStore(resources: resources)
        map.addOverlay(scene, level: .aboveRoads)
    }

    func refresh(route: [DoorCoordinate], destination: DoorCoordinate?, rider: DoorCoordinate?) {
        guard let map, map.bounds.width > 0, map.bounds.height > 0 else { return }
        generation &+= 1; let ticket = generation
        task?.cancel()
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: map.bounds.maxX, y: 0),
                       CGPoint(x: map.bounds.maxX, y: map.bounds.maxY), CGPoint(x: 0, y: map.bounds.maxY)]
            .map { map.convert($0, toCoordinateFrom: map) }
        let bounds = NativeLayerBounds(north: corners.map(\.latitude).max() ?? 0,
                                       south: corners.map(\.latitude).min() ?? 0,
                                       east: corners.map(\.longitude).max() ?? 0,
                                       west: corners.map(\.longitude).min() ?? 0)
        let zoom = NativeCameraAdapter.measuredZoom(map), heading = map.camera.heading
        task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 140_000_000)
                guard !Task.isCancelled else { return }
                let snapshot = try await self?.store.snapshot(bounds: bounds, zoom: zoom, route: route,
                                                               destination: destination, rider: rider, heading: heading)
                guard let self, !Task.isCancelled, self.generation == ticket, let snapshot else { return }
                self.apply(snapshot)
            } catch is CancellationError { }
            catch { }
        }
    }

    private func apply(_ snapshot: NativePublicLayerSnapshot) {
        guard let map else { return }
        let rows = snapshot.features.compactMap(Self.sceneRow)
        let features = rows.compactMap(NativeSceneFeature.init)
        scene.features = features; renderer?.setNeedsDisplay()
        map.removeAnnotations(annotations)
        annotations = features.compactMap { feature in
            guard feature.kind == "symbol" || feature.kind == "circle" else { return nil }
            return NativeSceneAnnotation(feature: feature)
        }
        map.addAnnotations(annotations)
        stats.community = snapshot.communityCount; stats.roads = snapshot.roadCount
        stats.buildings = snapshot.buildingCount; stats.doorplates = snapshot.doorplateCount
        stats.tiles = snapshot.loadedTiles; stats.refreshes += 1; onChange?()
    }

    func annotationView(for annotation: MKAnnotation) -> MKAnnotationView? {
        guard let item = annotation as? NativeSceneAnnotation else { return nil }
        let id = "native-public-layer"
        let view = map?.dequeueReusableAnnotationView(withIdentifier: id) as? NativeSceneAnnotationView ??
            NativeSceneAnnotationView(annotation: item, reuseIdentifier: id)
        view.annotation = item; view.configure(item); return view
    }

    func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        guard overlay === scene else { return nil }
        let value = NativeSceneRenderer(overlay: scene); renderer = value; return value
    }

    func selection(for annotation: MKAnnotation?) -> (String, String)? {
        guard let item = annotation as? NativeSceneAnnotation else { return nil }
        return (item.title ?? "", item.subtitle ?? "")
    }

    func releaseVisible() {
        task?.cancel(); task = nil; generation &+= 1
        if let map { map.removeAnnotations(annotations) }
        annotations.removeAll(); scene.features.removeAll(); renderer?.setNeedsDisplay()
        stats = Stats(); onChange?()
    }

    func clear() {
        releaseVisible()
        if let map { map.removeOverlay(scene) }
        onChange = nil
    }

    private static func sceneRow(_ feature: NativeLayerFeature) -> [String: Any]? {
        let style: (String, [String: Any], [String: Any], [String: Any])
        switch feature.kind {
        case .communityPoint:
            style = ("symbol", [:], ["text-field": feature.title, "text-size": 12.0, "text-allow-overlap": false,
                                     "text-subtitle": feature.subtitle], ["text-color": "#8fd3ff", "text-halo-color": "#102030", "text-halo-width": 1.5])
        case .doorplate:
            style = ("symbol", [:], ["text-field": feature.title, "text-size": 12.0, "text-allow-overlap": false,
                                     "text-subtitle": feature.subtitle], ["text-color": "#ffffff", "text-halo-color": "#111111", "text-halo-width": 1.5])
        case .road:
            style = ("line", [:], [:], ["line-color": "#557087", "line-opacity": 0.30, "line-width": 1.1])
        case .building:
            style = ("fill-extrusion", [:], [:], ["fill-extrusion-color": "#7c93a3", "fill-extrusion-opacity": 0.45])
        case .communityPolygon:
            style = ("fill", [:], [:], ["fill-color": "#5ca7ff", "fill-opacity": 0.13, "fill-outline-color": "#6bb1ff"])
        }
        var geometry: [String: Any]
        switch feature.geometry {
        case .point(let p): geometry = ["type": "Point", "coordinates": [p.lng, p.lat]]
        case .line(let points): geometry = ["type": "LineString", "coordinates": points.map { [$0.lng, $0.lat] }]
        case .polygon(let rings): geometry = ["type": "Polygon", "coordinates": rings.map { $0.map { [$0.lng, $0.lat] } }]
        }
        return ["id": feature.id, "source": "native-public-data", "layer": feature.kind.rawValue,
                "type": style.0, "geometry": geometry, "paint": style.3, "layout": style.2]
    }

    deinit { task?.cancel() }
}
