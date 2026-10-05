import XCTest
@testable import DoorMap581

final class DeepLinkRouterTests: XCTestCase {
    private func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }

    func testCoordinateCustomScheme() {
        let incoming = URL(string: "door581://open?lat=24.1371&lng=120.668491")!
        let resolved = DeepLinkRouter.webURL(for: DeepLinkRouter.payload(from: incoming))
        XCTAssertEqual(query(resolved, "dest"), "24.1371,120.668491")
    }

    func testGoogleShareCustomScheme() {
        let raw = "https://maps.app.goo.gl/abc123?g_st=ic&x=1"
        var components = URLComponents()
        components.scheme = "door581"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "gmap", value: raw)]
        let incoming = components.url!
        let resolved = DeepLinkRouter.webURL(for: DeepLinkRouter.payload(from: incoming))
        XCTAssertEqual(query(resolved, "gmap"), raw)
    }

    func testDirectGoogleShareURL() {
        let incoming = URL(string: "https://maps.app.goo.gl/xyz987")!
        let resolved = DeepLinkRouter.webURL(for: DeepLinkRouter.payload(from: incoming))
        XCTAssertEqual(query(resolved, "gmap"), incoming.absoluteString)
    }

    func testUberWazeCoordinateURL() {
        let incoming = URL(string: "waze://?ll=24.1371,120.668491&navigate=yes")!
        let resolved = DeepLinkRouter.webURL(for: DeepLinkRouter.payload(from: incoming))
        XCTAssertEqual(query(resolved, "dest"), "24.1371,120.668491")
    }

    func testUberWazeRejectsInvalidCoordinate() {
        let incoming = URL(string: "waze://?ll=35.0,139.0&navigate=yes")!
        let resolved = DeepLinkRouter.webURL(for: DeepLinkRouter.payload(from: incoming))
        XCTAssertNil(query(resolved, "dest"))
    }

    func testUnknownExternalURLFallsBackHome() {
        let incoming = URL(string: "https://example.com/")!
        let resolved = DeepLinkRouter.webURL(for: DeepLinkRouter.payload(from: incoming))
        XCTAssertEqual(resolved.host, AppConfig.liveBaseURL.host)
        XCTAssertNil(query(resolved, "gmap"))
        XCTAssertNil(query(resolved, "dest"))
    }

    func testDuplicateQueryKeysDoNotCrash() {
        let incoming = URL(string: "door581://open?dest=24.1,120.6&dest=24.2,120.7")!
        let resolved = DeepLinkRouter.webURL(for: DeepLinkRouter.payload(from: incoming))
        XCTAssertEqual(query(resolved, "dest"), "24.1,120.6")
    }
}
