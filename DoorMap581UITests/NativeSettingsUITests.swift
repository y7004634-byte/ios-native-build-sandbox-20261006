import XCTest

final class NativeSettingsUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--native-port-s3"]
        app.launchEnvironment["DOOR_NATIVE_S3_UI_TEST"] = "1"
        app.launchEnvironment["DOOR_NATIVE_CAMERA_FIXTURE"] = "1"
        app.launchEnvironment["DOOR_UI_STATION_OFFLINE"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["native-more"].waitForExistence(timeout: 25))
        wait("native state ready", seconds: 45) {
            (self.state()["routeCount"] as? Int ?? 0) >= 2
        }
    }
    override func tearDownWithError() throws {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
    }
    private func state() -> [String: Any] {
        let e = app.staticTexts["native-s2-state"]
        guard e.exists, let v = e.value as? String, let d = v.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j
    }
    private func wait(_ name: String, seconds: TimeInterval = 20, _ condition: @escaping () -> Bool) {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: seconds), .completed, name)
    }
    private func openSettings() {
        app.buttons["native-more"].tap()
        let settings = app.buttons["native-more-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.tables["map-settings"].waitForExistence(timeout: 8))
    }
    private func setSwitch(_ id: String, _ on: Bool) {
        let control = app.switches[id]
        XCTAssertTrue(control.waitForExistence(timeout: 5), id)
        let current = (control.value as? String) == "1"
        if current != on { control.tap() }
    }
    private func closeSettings() {
        let done = app.buttons["完成"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.buttons["native-more"].waitForExistence(timeout: 8))
    }
    func testMapSettingsApplyOfflineStationsAndRouteVisibilityThenRestore() {
        openSettings()
        setSwitch("setting-stations", true)
        setSwitch("setting-route-visible", false)
        let avatar = app.segmentedControls["avatar-mode"]; XCTAssertTrue(avatar.waitForExistence(timeout: 5)); avatar.buttons["悟空"].tap()
        closeSettings()
        wait("settings reflected in native state", seconds: 20) {
            self.state()["stationsEnabled"] as? Bool == true &&
            (self.state()["stationCount"] as? Int ?? 0) == 56 &&
            self.state()["routeVisible"] as? Bool == false &&
            self.state()["avatarMode"] as? String == "goku"
        }
        let rider = app.descendants(matching: .any)["native-live-rider"]
        XCTAssertTrue(rider.exists); XCTAssertTrue(rider.label.contains("悟空"))
        XCTAssertEqual(app.webViews.count, 0)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "s8-settings-stations-route-hidden"; shot.lifetime = .keepAlways; add(shot)

        openSettings()
        setSwitch("setting-stations", false)
        setSwitch("setting-route-visible", true)
        let avatarReset = app.segmentedControls["avatar-mode"]; XCTAssertTrue(avatarReset.waitForExistence(timeout: 5)); avatarReset.buttons["經典"].tap()
        closeSettings()
        wait("defaults restored") {
            self.state()["stationsEnabled"] as? Bool == false &&
            (self.state()["stationCount"] as? Int ?? -1) == 0 &&
            self.state()["routeVisible"] as? Bool == true &&
            self.state()["avatarMode"] as? String == "classic"
        }
    }

    func testPowerDiagnosticStartsAndStopsWithoutWebRuntime() {
        app.buttons["native-more"].tap()
        let power = app.buttons["native-more-power"]; XCTAssertTrue(power.waitForExistence(timeout: 5)); power.tap()
        let start = app.buttons["開始 5 分鐘"]; XCTAssertTrue(start.waitForExistence(timeout: 5)); start.tap()
        wait("power diagnostic running") { self.state()["powerDiagnosticRunning"] as? Bool == true }
        XCTAssertEqual(app.webViews.count, 0)
        app.buttons["native-more"].tap(); app.buttons["native-more-power"].tap()
        let stop = app.buttons["停止並保留報告"]; XCTAssertTrue(stop.waitForExistence(timeout: 5)); stop.tap()
        wait("power diagnostic stopped") { self.state()["powerDiagnosticRunning"] as? Bool == false }
    }

    func testMapCenterPickerTracksPanAndNavigatesExplicitCenter() {
        app.buttons["native-more"].tap()
        let picker = app.buttons["native-more-center-picker"]; XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.tap()
        XCTAssertTrue(app.staticTexts["native-center-coordinate"].waitForExistence(timeout: 5))
        wait("center picker enabled") { self.state()["centerPickerEnabled"] as? Bool == true }
        let before = state()["centerPickerCoordinate"] as? [Double] ?? []
        let map = app.otherElements["native-port-apple-map"]; XCTAssertTrue(map.waitForExistence(timeout: 5))
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.55))
            .press(forDuration: 0.1, thenDragTo: map.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.55)))
        wait("center picker follows map pan") {
            let after = self.state()["centerPickerCoordinate"] as? [Double] ?? []
            return after.count == 2 && after != before
        }
        app.buttons["native-center-navigate"].tap()
        wait("center becomes explicit destination") {
            self.state()["centerPickerEnabled"] as? Bool == false &&
            (self.state()["destination"] as? String) == "地圖中心"
        }
        XCTAssertEqual(app.webViews.count, 0)
    }
}
