import XCTest

final class NativePersonalUITests: XCTestCase {
    private func state(_ app: XCUIApplication) -> [String: Any] {
        let e = app.staticTexts["native-s2-state"]
        guard e.waitForExistence(timeout: 20), let value = e.value as? String,
              let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }
    private func wait(_ name: String, seconds: TimeInterval = 20, _ condition: @escaping () -> Bool) {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: seconds), .completed, name)
    }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--native-port-s3"]
        app.launchEnvironment["DOOR_NATIVE_S3_UI_TEST"] = "1"
        app.launchEnvironment["DOOR_NATIVE_CAMERA_FIXTURE"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["native-more"].waitForExistence(timeout: 25))
        return app
    }
    func testThemePersistsAndBackupEntryIsNative() {
        XCUIDevice.shared.orientation = .portrait
        var app = launch()
        let initial = state(app)["appearance"] as? String ?? "dark"

        app.buttons["native-more"].tap()
        let backup = app.buttons["native-more-backup"]
        XCTAssertTrue(backup.waitForExistence(timeout: 6))
        XCTAssertEqual(app.webViews.count, 0)
        app.buttons["native-more-theme"].tap()

        let expected: String = initial == "dark" ? "light" : initial == "light" ? "system" : "dark"
        wait("appearance changed") { (self.state(app)["appearance"] as? String) == expected }
        app.terminate()

        app = launch()
        wait("appearance persisted after relaunch") { (self.state(app)["appearance"] as? String) == expected }
        XCTAssertEqual(app.webViews.count, 0)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "s7-personal-persisted"; shot.lifetime = .keepAlways; add(shot)
        let bytes = try! JSONSerialization.data(withJSONObject: state(app), options: [.sortedKeys, .prettyPrinted])
        let json = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json"); json.name = "s7-personal-state"; json.lifetime = .keepAlways; add(json)
        app.terminate(); XCUIDevice.shared.orientation = .portrait
    }
}
