import CoreLocation
import XCTest
@testable import DoorMap581

final class NativeAppleMapTests: XCTestCase {
    func testRouteUsesExistingWorkerAndLongitudeLatitudeOrder() throws {
        let request = try NativeRoute.request(from: .init(latitude: 24.1, longitude: 120.6),
                                              to: .init(latitude: 24.2, longitude: 120.7))
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "rider-door-map-canary.pages.dev")
        XCTAssertEqual(url.path, "/api/route")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first(where: { $0.name == "from" })?.value, "120.6,24.1")
        XCTAssertEqual(items.first(where: { $0.name == "variant" })?.value, "main")
        XCTAssertNil(items.first(where: { $0.name == "key" }))
    }

    func testRouteRejectsWrongProfileAndInvalidGeometry() throws {
        let original = #"{"geometry":{"type":"LineString","coordinates":[[120.6,24.1],[120.7,24.2]]},"distance":100,"duration":20,"engine":"valhalla","profile":"motor_scooter","maneuvers":[]}"#
        let decoder = JSONDecoder()
        let valid = try decoder.decode(NativeRoute.self, from: Data(original.utf8))
        XCTAssertNoThrow(try valid.validate())
        for text in [original.replacingOccurrences(of: "motor_scooter", with: "car"),
                     original.replacingOccurrences(of: "120.6,24.1", with: "120.6,240.1"),
                     original.replacingOccurrences(of: "LineString", with: "Polygon")] {
            let value = try decoder.decode(NativeRoute.self, from: Data(text.utf8))
            XCTAssertThrowsError(try value.validate())
        }
    }

    func testNativeCursorDoesNotResurrectTravelledSegments() {
        let path = (0...10).map { CLLocationCoordinate2D(latitude: 24.0, longitude: 120 + Double($0) * 0.0001) }
        var cursor = NativeRouteProgress(path: path)
        XCTAssertNotNil(cursor.update(path[5], accuracy: 5))
        let travelled = cursor.travelled
        _ = cursor.update(path[3], accuracy: 5)
        XCTAssertGreaterThanOrEqual(cursor.travelled, travelled)
        XCTAssertGreaterThanOrEqual(cursor.remaining[0].longitude, path[5].longitude)
    }

    func testPoorAccuracyDoesNotAdvanceCursor() {
        let path = [CLLocationCoordinate2D(latitude: 24, longitude: 120),
                    CLLocationCoordinate2D(latitude: 24, longitude: 120.001)]
        var cursor = NativeRouteProgress(path: path)
        XCTAssertNil(cursor.update(path[1], accuracy: 200))
        XCTAssertEqual(cursor.travelled, 0)
    }

    func testCoordinateInputRejectsNonfiniteAndOutOfRange() {
        XCTAssertNotNil(NativeAppleMapViewController.parseCoordinate("24.1477, 120.6736"))
        for value in ["nan,120", "24,inf", "91,120", "24,181", "商家名稱", "24,120,1"] {
            XCTAssertNil(NativeAppleMapViewController.parseCoordinate(value))
        }
    }

    func testBundledMiniMapPreservesItsRelativeResourceDirectory() throws {
        let bundle = Bundle(for: NativeAppleMapViewController.self)
        let html = try XCTUnwrap(bundle.url(forResource: "nlsc-map", withExtension: "html", subdirectory: "MiniMap"))
        for filename in ["nlsc-map.js", "nlsc-contract.js", "maplibre-gl.js", "maplibre-gl.css", "LICENSE.txt"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: html.deletingLastPathComponent().appendingPathComponent(filename).path))
        }
    }
}
