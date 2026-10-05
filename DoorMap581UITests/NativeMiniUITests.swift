import XCTest

/// Native NLSC mini-map acceptance with a local raster fixture. This verifies
/// UIKit/MapKit interaction and correction transaction only; live NLSC tiles
/// and physical-device readability remain separate evidence.
final class NativeMiniUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--native-port-s3"]
        app.launchEnvironment["DOOR_NATIVE_S3_UI_TEST"] = "1"
        app.launchEnvironment["DOOR_NATIVE_CAMERA_FIXTURE"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["native-mini-toggle"].waitForExistence(timeout: 25))
        wait("fixture target exists") { !(self.state()["destination"] as? String ?? "").isEmpty }
    }
    override func tearDownWithError() throws { app?.terminate(); XCUIDevice.shared.orientation = .portrait }
    private func state() -> [String: Any] {
        let e = app.staticTexts["native-s2-state"]
        guard e.exists, let value = e.value as? String, let bytes = value.data(using: .utf8),
              let data = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return [:] }
        return data
    }
    private func wait(_ name: String, seconds: TimeInterval = 25, _ condition: @escaping () -> Bool) {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: seconds), .completed, name)
    }
    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name + "-screen"; image.lifetime = .keepAlways; add(image)
        let bytes = try! JSONSerialization.data(withJSONObject: state(), options: [.sortedKeys, .prettyPrinted])
        let data = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json"); data.name = name + "-state"; data.lifetime = .keepAlways; add(data)
        XCTAssertEqual(app.webViews.count, 0)
    }
    func testCloseRangeCorrectionCancelApplyAndReopen() {
        let originalRevision = state()["destinationRevision"] as? Int ?? -1
        app.buttons["native-mini-toggle"].tap()
        wait("mini expanded close range") {
            self.state()["miniExpanded"] as? Bool == true && (self.state()["miniMapHeight"] as? Double ?? 0) > 180
        }
        let initial = state()
        XCTAssertEqual(initial["miniPitch"] as? Double ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual(initial["miniBearing"] as? Double ?? -1, 0, accuracy: 1)
        XCTAssertGreaterThan(initial["miniZoom"] as? Double ?? 0, 18.5)
        XCTAssertEqual(initial["miniPublicPinCount"] as? Int, 1)
        capture("s3-native-mini-close-range")

        app.buttons["native-mini-correct"].tap()
        let mini = app.otherElements["native-nlsc-map"]
        XCTAssertTrue(mini.waitForExistence(timeout: 8)); XCTAssertTrue(mini.isHittable)
        mini.swipeLeft()
        wait("manual draft created") { (self.state()["miniDraft"] as? [Double])?.count == 2 }
        XCTAssertTrue(app.buttons["native-mini-apply"].isEnabled)
        app.buttons["native-mini-cancel"].tap()
        wait("cancel keeps original destination") {
            self.state()["miniCorrecting"] as? Bool == false &&
            (self.state()["miniDraft"] as? [Double] ?? []).isEmpty &&
            (self.state()["destinationRevision"] as? Int ?? -1) == originalRevision
        }
        capture("s3-native-mini-cancel")

        app.buttons["native-mini-correct"].tap(); mini.swipeRight()
        wait("second draft created") { (self.state()["miniDraft"] as? [Double])?.count == 2 }
        app.buttons["native-mini-apply"].tap()
        wait("apply is the only commit") {
            self.state()["miniCommitSucceeded"] as? Bool == true &&
            (self.state()["destinationRevision"] as? Int ?? -1) == originalRevision + 1
        }
        capture("s3-native-mini-applied")

        let appliedZoom = state()["miniZoom"] as? Double ?? 0
        app.buttons["native-mini-toggle"].tap()
        wait("mini collapsed") { self.state()["miniExpanded"] as? Bool == false }
        app.buttons["native-mini-toggle"].tap()
        wait("mini reopen preserves close range") {
            self.state()["miniExpanded"] as? Bool == true && (self.state()["miniZoom"] as? Double ?? 0) > 18.5
        }
        XCTAssertEqual(state()["miniZoom"] as? Double ?? 0, appliedZoom, accuracy: 0.7)
        capture("s3-native-mini-reopen")
    }
}
