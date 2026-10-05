import XCTest
@testable import DoorMap581

final class NativePublicLayerTests: XCTestCase {
    func testViewportLoadsVerifiedCommunityOSMAndDoorplatesWithoutMovingCoordinates() async throws {
        let resources = try NativePublicResources.makeForTestApp(bundle: .main)
        let store = NativePublicLayerStore(resources: resources)
        let bounds = NativeLayerBounds(north: 24.148, south: 24.128, east: 120.705, west: 120.668)
        let route = [
            DoorCoordinate(lat: 24.135, lng: 120.688),
            DoorCoordinate(lat: 24.140, lng: 120.692),
            DoorCoordinate(lat: 24.143, lng: 120.696)
        ]
        let snapshot = try await store.snapshot(bounds: bounds, zoom: 18.6, route: route,
                                                destination: route.last, rider: route.first, heading: 25)
        XCTAssertGreaterThan(snapshot.loadedTiles, 0)
        XCTAssertGreaterThan(snapshot.communityCount, 0)
        XCTAssertGreaterThan(snapshot.buildingCount + snapshot.roadCount, 0)
        XCTAssertGreaterThan(snapshot.doorplateCount, 0)
        XCTAssertLessThanOrEqual(snapshot.doorplateCount, 110)
        let labels = snapshot.features.filter { $0.kind == .doorplate }
        XCTAssertEqual(labels.count, snapshot.doorplateCount)
        for row in labels {
            guard case .point(let p) = row.geometry else { return XCTFail("doorplate must stay an exact point") }
            XCTAssertTrue((bounds.south...bounds.north).contains(p.lat))
            XCTAssertTrue((bounds.west...bounds.east).contains(p.lng))
            XCTAssertFalse(row.title.isEmpty)
        }
    }

    func testFarZoomDoesNotMaterializeDoorplateLabels() async throws {
        let resources = try NativePublicResources.makeForTestApp(bundle: .main)
        let store = NativePublicLayerStore(resources: resources)
        let bounds = NativeLayerBounds(north: 24.18, south: 24.10, east: 120.74, west: 120.62)
        let snapshot = try await store.snapshot(bounds: bounds, zoom: 16.2, route: [], destination: nil, rider: nil, heading: nil)
        XCTAssertEqual(snapshot.doorplateCount, 0)
        XCTAssertTrue(snapshot.features.allSatisfy { $0.kind != .doorplate })
    }
}
