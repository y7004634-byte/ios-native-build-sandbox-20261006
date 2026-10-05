import XCTest
@testable import DoorMap581

final class NativeGoogleHandoffTests: XCTestCase {
    func testCoordinateParserAcceptsTaiwanDecimalAndDMS() throws {
        XCTAssertEqual(NativeMapsInput.coordinate("24.1500, 120.6800"), DoorCoordinate(lat: 24.15, lng: 120.68))
        let dms = try XCTUnwrap(NativeMapsInput.coordinate("24° 9' 0\" N, 120° 40' 48\" E"))
        XCTAssertEqual(dms.lat, 24.15, accuracy: 0.000001)
        XCTAssertEqual(dms.lng, 120.68, accuracy: 0.000001)
        XCTAssertNil(NativeMapsInput.coordinate("35.0,139.0"))
    }

    func testAllowlistRejectsViewportOrUnrelatedHostsAsDestination() throws {
        XCTAssertNotNil(NativeMapsInput.extract("https://maps.app.goo.gl/abc123?g_st=ic"))
        XCTAssertNil(NativeMapsInput.extract("https://evil.example/maps/place/24.15,120.68"))
        let viewport = try XCTUnwrap(URL(string: "https://www.google.com/maps/@24.1500,120.6800,17z"))
        XCTAssertNil(NativeMapsInput.point(from: viewport), "generic @lat,lng is only a camera center")
    }

    func testDirectionsDestinationAndPlaceDataMatchAcceptedRules() throws {
        let directions = try XCTUnwrap(URL(string: "https://www.google.com/maps/dir/?api=1&origin=24.10,120.60&destination=24.1500,120.6800"))
        XCTAssertEqual(NativeMapsInput.point(from: directions), DoorCoordinate(lat: 24.15, lng: 120.68))

        let place = try XCTUnwrap(URL(string: "https://www.google.com/maps/place/X/data=!3d24.151!4d120.681"))
        XCTAssertEqual(NativeMapsInput.point(from: place), DoorCoordinate(lat: 24.151, lng: 120.681))

        let ambiguous = try XCTUnwrap(URL(string: "https://www.google.com/maps/place/X/data=!3d24.151!4d120.681!3d24.152!4d120.682"))
        XCTAssertNil(NativeMapsInput.point(from: ambiguous))
    }

    func testTargetTextKeepsPlaceNameButNotCoordinate() throws {
        let named = try XCTUnwrap(URL(string: "https://www.google.com/maps/search/?api=1&query=%E5%8F%B0%E4%B8%AD%E7%81%AB%E8%BB%8A%E7%AB%99"))
        XCTAssertEqual(NativeMapsInput.targetText(from: named), "台中火車站")
        let coordinate = try XCTUnwrap(URL(string: "https://www.google.com/maps/search/?api=1&query=24.15,120.68"))
        XCTAssertEqual(NativeMapsInput.targetText(from: coordinate), "")
    }

    func testResolverUsesLocalTrustedCoordinateWithoutNetwork() async throws {
        let value = try await NativeGoogleResolver().resolve("https://www.google.com/maps/dir/?api=1&destination=24.1500,120.6800")
        XCTAssertEqual(value.coordinate, DoorCoordinate(lat: 24.15, lng: 120.68))
        XCTAssertEqual(value.source, "google-local-url")
    }
}
