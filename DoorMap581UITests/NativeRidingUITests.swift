import XCTest

/// Real MapKit/UIKit interactions, with explicitly simulated sensor and route
/// inputs. These tests are NOT phone GPS/compass or live route acceptance.
final class NativeRidingUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(); app.launchArguments = ["--native-port-s3"]
        app.launchEnvironment["DOOR_NATIVE_S3_UI_TEST"] = "1"
        app.launchEnvironment["DOOR_NATIVE_CAMERA_FIXTURE"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["native-fit"].waitForExistence(timeout: 25))
        wait("explicit native route/fix fixture is ready", seconds: 45) {
            (self.state()["sensorFixes"] as? Int ?? 0) > 0 && (self.state()["routeCount"] as? Int ?? 0) >= 2
        }
    }
    override func tearDownWithError() throws { app?.terminate(); XCUIDevice.shared.orientation = .portrait }
    private func state() -> [String: Any] {
        let element = app.staticTexts["native-s2-state"]
        guard element.exists, let text = element.value as? String, let bytes = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return [:] }
        return value
    }
    private func wait(_ name: String, seconds: TimeInterval = 20, _ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        let outcome = XCTWaiter.wait(for: [expectation], timeout: seconds)
        if outcome != .completed { capture("s3-timeout-" + name) }
        XCTAssertEqual(outcome, .completed, name)
    }
    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name + "-screen"; image.lifetime = .keepAlways; add(image)
        var snapshot = state(); snapshot["evidenceScope"] = "SIMULATED_SENSOR_ROUTE_REAL_UI_NOT_PHONE_ACCEPTANCE"
        let data = try! JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys, .prettyPrinted])
        let record = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); record.name = name + "-state"; record.lifetime = .keepAlways; add(record)
        XCTAssertEqual(app.webViews.count, 0); XCTAssertEqual(snapshot["wkViews"] as? Int, 0)
    }
    func testHeadingOwnershipSurvivesRealTapPanAndForegroundReturn() {
        app.buttons["native-heading"].tap()
        wait("heading owner active") { self.state()["cameraMode"] as? String == "heading" }
        let map = app.otherElements["native-port-apple-map"]; XCTAssertTrue(map.waitForExistence(timeout: 8))
        let center = map.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.55))
        center.tap()
        wait("tap never unlocks follow") { self.state()["cameraMode"] as? String == "heading" && self.state()["gestureHolding"] as? Bool == false }
        capture("s3-heading-after-tap")
        let before = state()["cameraApplications"] as? Int ?? 0
        center.press(forDuration: 0.1, thenDragTo: map.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.55)))
        wait("actual pan releases and camera resumes") {
            self.state()["cameraMode"] as? String == "heading" && self.state()["gestureHolding"] as? Bool == false &&
                (self.state()["cameraApplications"] as? Int ?? 0) > before
        }
        capture("s3-heading-after-pan-resume")
        XCUIDevice.shared.press(.home); app.activate()
        wait("foreground restores selected owner") { self.state()["cameraMode"] as? String == "heading" && self.state()["gestureHolding"] as? Bool == false }
        XCTAssertEqual(state()["gesturePointers"] as? Int, 0)
        XCTAssertEqual(state()["sensorRawPosition"] as? [Double], [24.135, 120.688])
        capture("s3-heading-foreground")
    }
    func testNormal3DNavigationHUDUsesRouteFirstCamera() {
        wait("normal navigation starts from committed scooter route", seconds: 25) {
            self.state()["cameraMode"] as? String == "navigation" &&
            abs((self.state()["mapPitch"] as? Double ?? 0) - 58) < 1 &&
            (self.state()["navigation3D"] as? Bool) == true
        }
        let hud = app.otherElements["native-navigation-hud"]
        XCTAssertTrue(hud.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["native-maneuver-name"].label.contains("測試路"))
        XCTAssertTrue(app.staticTexts["native-route-summary"].label.contains("3D 導航"))
        let bearing = state()["mapBearing"] as? Double ?? -999
        XCTAssertGreaterThan(bearing, 15); XCTAssertLessThan(bearing, 35, "route-first bearing must follow the first route segment, not fixture GPS/compass 45°")
        XCTAssertEqual(app.webViews.count, 0)
        capture("s8-normal-3d-navigation-hud")
    }
    func testFITPiPActualGeometryAndRealPinchRetainNativeOwner() {
        XCTAssertTrue(app.buttons["native-fit"].isEnabled); app.buttons["native-fit"].tap()
        wait("native FIT computed and applied", seconds: 35) {
            self.state()["cameraMode"] as? String == "fit" && self.state()["fitPlanReady"] as? Bool == true && self.state()["fitBusy"] as? Bool == false
        }
        let fitted = state(), target = fitted["targetPixel"] as? [Double] ?? [], rider = fitted["riderPixel"] as? [Double] ?? []
        XCTAssertEqual(target.count, 2); XCTAssertEqual(rider.count, 2)
        XCTAssertGreaterThanOrEqual(target[1] - 46, (fitted["pipBottom"] as? Double ?? .infinity) - 3)
        XCTAssertGreaterThan(rider[1], target[1] + 18)
        XCTAssertLessThan(fitted["anchorErrorPoints"] as? Double ?? .infinity, 2)
        capture("s3-fit-pip-actual-projection")
        let map = app.otherElements["native-port-apple-map"]
        // Measured MapKit delta for XCTest scale1.15 was only0.0228555,
        // below the unchanged accepted0.03 manual-zoom intent threshold.
        // Use a deliberate larger real gesture; never reduce the threshold,
        // synthesize an offset, or remove the original owner/offset assertions.
        map.pinch(withScale: 1.8, velocity: 0.5)
        capture("s3-immediate-after-real-pinch")
        wait("real pinch stores offset and preserves FIT", seconds: 25) {
            self.state()["cameraMode"] as? String == "fit" && self.state()["gestureHolding"] as? Bool == false &&
                abs(self.state()["cameraZoomOffset"] as? Double ?? 0) > 0.02 && self.state()["fitBusy"] as? Bool == false
        }
        let commits = (state()["gestureEvidence"] as? [[String: Any]] ?? []).filter { $0["phase"] as? String == "zoom-commit-after-native-settle" }
        XCTAssertGreaterThan(abs(commits.last?["delta"] as? Double ?? 0), 0.03, "real measured native scale must exceed original intent threshold")
        capture("s3-fit-real-pinch-offset")
        app.buttons["native-more"].tap(); app.buttons["native-more-pip"].tap()
        wait("PiP explicit preset changes without unlocking FIT") { self.state()["pipPreset"] as? Bool == false && self.state()["cameraMode"] as? String == "fit" && self.state()["fitBusy"] as? Bool == false }
        capture("s3-fit-pip-off")
        app.buttons["native-fit"].tap()
        wait("FIT toggle returns to the active navigation owner") { self.state()["cameraMode"] as? String == "navigation" }
    }
}
