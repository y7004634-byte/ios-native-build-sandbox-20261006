import MapKit
import XCTest
@testable import DoorMap581

final class MapPreferencesTests: XCTestCase {
    func testPreferencesSurviveStoreReloadAndInvalidValuesAreClamped() throws {
        let name = "door581-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var preferences = MapPreferences()
        preferences.appearance = .system; preferences.muted = true; preferences.traffic = true
        preferences.stations = true; preferences.miniMode = .hidden; preferences.routeMemoryEnabled = false; preferences.avatarMode = .goku
        preferences.rotateGestures = false; preferences.pitch = 38; preferences.heading = 123; preferences.distance = 920
        preferences.allPOI = false; preferences.poiCategories = ["cafe", "store"]
        preferences.save(defaults)
        let restored = MapPreferences.load(defaults)
        XCTAssertEqual(restored.appearance, .system)
        XCTAssertTrue(restored.muted && restored.traffic && restored.stations)
        XCTAssertEqual(restored.miniMode, .hidden); XCTAssertFalse(restored.rotateGestures); XCTAssertFalse(restored.memoryEnabled); XCTAssertEqual(restored.avatar, .goku)
        XCTAssertEqual(restored.pitch, 38); XCTAssertEqual(restored.heading, 123); XCTAssertEqual(restored.distance, 920)
        XCTAssertTrue(restored.filter.includes(.cafe)); XCTAssertFalse(restored.filter.includes(.restaurant))
        var corrupt = restored; corrupt.pitch = -100; corrupt.heading = 721; corrupt.distance = -1
        corrupt.poiCategories = ["cafe", "not-a-supported-category"]; corrupt.save(defaults)
        let sanitized = MapPreferences.load(defaults)
        XCTAssertEqual(sanitized.pitch, 0); XCTAssertEqual(sanitized.heading, 1); XCTAssertEqual(sanitized.distance, 80)
        XCTAssertEqual(sanitized.poiCategories, ["cafe"])
    }
    func testApplePOIDisplayModesHaveEffectiveFilters() {
        var preferences = MapPreferences()
        XCTAssertTrue(preferences.filter.includes(.restaurant))
        preferences.showsPOI = false; XCTAssertFalse(preferences.filter.includes(.restaurant))
        preferences.showsPOI = true; preferences.allPOI = false; preferences.poiCategories = []
        XCTAssertFalse(preferences.filter.includes(.cafe))
        preferences.poiCategories = ["pharmacy"]
        XCTAssertTrue(preferences.filter.includes(.pharmacy)); XCTAssertFalse(preferences.filter.includes(.store))
    }
    func testStationFallbackContainsOnlyValidatedSavedPositions() throws {
        let bundle = Bundle(for: NativeAppleMapViewController.self)
        let url = try XCTUnwrap(bundle.url(forResource: "battery-stations-fallback", withExtension: "json"))
        let snapshot = try JSONDecoder().decode(BatteryStationSnapshot.self, from: Data(contentsOf: url))
        XCTAssertNoThrow(try snapshot.validated())
        XCTAssertEqual(snapshot.stations.count, 56)
        XCTAssertTrue(snapshot.source.hasPrefix("OSM original Door Map"))
        XCTAssertTrue(snapshot.stations.allSatisfy { $0.id.hasPrefix("osm:") })
        let invalid = BatteryStationSnapshot(stations: [.init(id: "x", lat: 24, lng: 999, name: "invalid", address: nil, unavailable: nil)],
                                            fetchedAt: 1, source: "fixture", attribution: nil, stale: nil)
        XCTAssertThrowsError(try invalid.validated())
    }
}
