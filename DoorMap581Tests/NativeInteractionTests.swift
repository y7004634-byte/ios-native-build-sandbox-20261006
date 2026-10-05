import MapKit
import XCTest
@testable import DoorMap581

@MainActor final class NativeInteractionTests: XCTestCase {
    private func controller() -> NativeAppleMapViewController {
        UserDefaults.standard.removeObject(forKey: MapPreferences.key)
        UserDefaults.standard.removeObject(forKey: SavedDestination.key)
        let controller = NativeAppleMapViewController(initialDeepLink: nil)
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0,y: 0,width: 390,height: 844)
        controller.view.layoutIfNeeded(); return controller
    }
    func testCorrectionMovesDestinationPinAndInvalidatesOldRouteWithoutMovingGPS() throws {
        let c = controller(), old = CLLocationCoordinate2D(latitude: 24.14,longitude: 120.67)
        let corrected = CLLocationCoordinate2D(latitude: 24.141,longitude: 120.671)
        c.testFix(CLLocation(latitude: 24.13,longitude: 120.66)); c.testChoose(old)
        let token = c.testRouteToken
        var preferences = c.testSettings; preferences.miniMode = .expanded; c.testPreferences(preferences)
        c.testCorrect(corrected)
        XCTAssertEqual(try XCTUnwrap(c.testPin).latitude,corrected.latitude)
        XCTAssertEqual(try XCTUnwrap(c.testPin).longitude,corrected.longitude)
        XCTAssertEqual(try XCTUnwrap(c.testGPS).latitude,24.13)
        XCTAssertEqual(c.testSettings.miniMode,.collapsed)
        let request = try NativeRoute.request(from: XCTUnwrap(c.testGPS),to: XCTUnwrap(c.testPin))
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url),resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "to" }?.value,"120.671,24.141")
        let stale = NativeRoute(geometry: .init(type: "LineString",coordinates: [[120.66,24.13],[120.67,24.14]]),
                                distance: 200,duration: 60,engine: "valhalla",profile: "motor_scooter",maneuvers: [])
        c.testReceiveRoute(stale,token: token); XCTAssertNil(c.testRoute)
        // Closing the editor rejects both delayed and subsequent correction attempts.
        c.testCorrect(old); XCTAssertEqual(try XCTUnwrap(c.testPin).latitude,corrected.latitude)
    }
    func testHandCameraIsSavedAndOverviewRetainsChosenAngle() throws {
        let c = controller(); c.testChoose(.init(latitude: 24.14,longitude: 120.67))
        let camera = MKMapCamera(lookingAtCenter: .init(latitude: 24.14,longitude: 120.67),fromDistance: 800,pitch: 30,heading: 91)
        c.testSaveCamera(camera)
        let chosen = c.testSettings
        XCTAssertEqual(MapPreferences.load().heading,chosen.heading,accuracy: 0.5)
        XCTAssertEqual(MapPreferences.load().pitch,chosen.pitch,accuracy: 0.5)
        c.testOverview()
        XCTAssertEqual(Double(c.testCamera.pitch),chosen.pitch,accuracy: 0.5)
        XCTAssertEqual(c.testCamera.heading,chosen.heading,accuracy: 0.5)
        c.testFix(CLLocation(latitude: 24.13,longitude: 120.66)); c.testFollow()
        XCTAssertEqual(c.testSettings.pitch,chosen.pitch,accuracy: 0.5)
        XCTAssertEqual(c.testSettings.heading,chosen.heading,accuracy: 0.5)
    }
}
