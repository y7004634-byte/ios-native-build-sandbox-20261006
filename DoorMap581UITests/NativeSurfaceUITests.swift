import XCTest

/// Real UIKit interactions with real bundled public data. Location is a labeled
/// fixed map center; Apple live lookup, actual riding and full parity are NOT tested.
final class NativeSurfaceUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--native-port-s2"]
        app.launchEnvironment["DOOR_NATIVE_S2_UI_TEST"] = "1"
        app.launch()
        XCTAssertTrue(app.textFields["native-planner-query"].waitForExistence(timeout: 20))
        wait("real native seed and community loaded", seconds: 60) {
            (self.state()["localCount"] as? Int) == 38950 && (self.state()["communityCount"] as? Int) == 7285
        }
    }
    override func tearDownWithError() throws { app?.terminate(); XCUIDevice.shared.orientation = .portrait }
    private func state() -> [String: Any] {
        let e = app.staticTexts["native-s2-state"]
        guard e.exists, let value = e.value as? String, let bytes = value.data(using: .utf8),
              let data = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return [:] }
        return data
    }
    private func wait(_ name: String, seconds: TimeInterval = 35, condition: @escaping () -> Bool) {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: seconds), .completed, name)
    }
    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name + "-screen"; image.lifetime = .keepAlways; add(image)
        var observed = state()
        if app.staticTexts["native-offline-summary"].exists {
            observed = ["screen": "native-offline", "summary": app.staticTexts["native-offline-summary"].label,
                        "detail": app.staticTexts["native-offline-detail"].label, "wkViews": app.webViews.count]
        }
        let bytes = (try? JSONSerialization.data(withJSONObject: observed, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        let data = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json"); data.name = name + "-measured-state"; data.lifetime = .keepAlways; add(data)
        XCTAssertEqual(observed["wkViews"] as? Int, 0)
        XCTAssertEqual(app.webViews.count, 0)
    }
    private func typeQuery(_ text: String) {
        let q = app.textFields["native-planner-query"]; q.tap(); q.typeText(text)
        wait("query publishes without web layer") { self.state()["query"] as? String == text && self.state()["busy"] as? Bool == false && (self.state()["listCount"] as? Int ?? 0) > 0 }
    }
    private func offline() {
        app.buttons["native-more"].tap(); app.buttons["native-more-offline"].tap()
        XCTAssertTrue(app.staticTexts["native-offline-summary"].waitForExistence(timeout: 8))
    }
    func testTopSearchMoreShortcutPinsAndSelectionUseOneNativeFlow() {
        let ready = state()
        XCTAssertEqual((ready["searchTop"] as? Double ?? 0) - (ready["safeTop"] as? Double ?? 0), 10, accuracy: 1.5)
        typeQuery("FamilyMart"); capture("s2-native-candidates")
        XCTAssertLessThanOrEqual(state()["maxPinMeters"] as? Double ?? .infinity, 3000)
        XCTAssertGreaterThan(state()["pinCount"] as? Int ?? 0, 0)
        app.buttons["native-planner-go"].tap()
        wait("explicit Search shows map pool") { self.state()["mapResultsMode"] as? Bool == true && self.state()["busy"] as? Bool == false }
        capture("s2-native-map-pins")
        app.buttons["native-more"].tap(); app.buttons["native-more-search"].tap()
        XCTAssertEqual(app.textFields["native-planner-query"].value as? String, "FamilyMart")
        XCTAssertTrue(app.tables["native-search-results"].cells.firstMatch.waitForExistence(timeout: 8))
        app.tables["native-search-results"].cells.firstMatch.tap()
        wait("real selected target is held by native state") { !(self.state()["destination"] as? String ?? "").isEmpty }
        XCTAssertEqual(state()["destinationRevision"] as? Int, 1)
        capture("s2-native-selection")
    }
    func testPagingAreaResearchAndClearDoNotLosePoolOrResurrectOldPins() {
        typeQuery("restaurant")
        capture("s2-repair-dense-restaurant-pool")
        let dense = state()
        XCTAssertGreaterThan(dense["pinCount"] as? Int ?? 0, 1000)
        XCTAssertEqual(dense["accountedPinCount"] as? Int, dense["pinCount"] as? Int)
        XCTAssertEqual(dense["unprojectablePinCount"] as? Int, 0)
        XCTAssertLessThanOrEqual(dense["renderedAnnotationCount"] as? Int ?? Int.max, 180)
        XCTAssertLessThan(dense["renderedAnnotationCount"] as? Int ?? Int.max, dense["pinCount"] as? Int ?? 0)
        XCTAssertGreaterThan(state()["listCount"] as? Int ?? 0, 30)
        XCTAssertEqual(state()["pageCount"] as? Int, 30)
        let more = app.buttons["native-search-load-more"], table = app.tables["native-search-results"]
        for _ in 0..<10 { if more.isHittable { break }; table.swipeUp() }
        XCTAssertTrue(more.isHittable); more.tap()
        wait("second page without truncating the pool") { (self.state()["pageCount"] as? Int ?? 0) > 30 }
        app.buttons["native-planner-go"].tap()
        wait("map mode before real pan") { self.state()["mapResultsMode"] as? Bool == true && self.state()["busy"] as? Bool == false }
        // Exact failure hierarchy identifies this MKMapView as Other, not Map.
        // Keep the same identity and perform a real gesture; never inject area state.
        let map = app.otherElements["native-port-apple-map"]
        XCTAssertTrue(map.waitForExistence(timeout: 8)); XCTAssertTrue(map.isHittable)
        capture("s2-repair-map-before-real-pan")
        map.swipeLeft()
        XCTAssertTrue(app.buttons["native-search-area"].waitForExistence(timeout: 8))
        app.buttons["native-search-area"].tap()
        wait("area search completes") { self.state()["busy"] as? Bool == false && self.state()["areaAvailable"] as? Bool == false }
        XCTAssertEqual(state()["accountedPinCount"] as? Int, state()["pinCount"] as? Int)
        capture("s2-repair-dense-area-researched")
        app.buttons["native-planner-clear"].tap()
        wait("Clear owns the empty pool") { self.state()["query"] as? String == "" && self.state()["pinCount"] as? Int == 0 && self.state()["listCount"] as? Int == 0 }
        capture("s2-native-clear-after-area")
    }
    func testActualOfflineButtonInstallsAllComponentsAndRelaunchVerifiesFiles() {
        offline(); app.buttons["native-offline-install"].tap()
        wait("real complete installation receipt", seconds: 180) {
            self.app.staticTexts["native-offline-summary"].label.contains("已安裝 · 3122") && self.app.buttons["native-offline-install"].isEnabled
        }
        capture("s2-native-offline-installed")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["native-more"].waitForExistence(timeout: 20)); offline()
        wait("persisted receipt survived process restart", seconds: 25) { self.app.staticTexts["native-offline-summary"].label.contains("已安裝 · 3122") }
        app.buttons["native-offline-verify"].tap()
        wait("actual installed files verify after relaunch", seconds: 120) { self.app.staticTexts["native-offline-summary"].label.contains("檢查通過 · 3122") }
        capture("s2-native-offline-reopened-verified")
    }
    func testNativeLayoutRemainsReachableInPortraitAndLandscape() {
        capture("s2-native-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        wait("landscape layout") { (self.state()["width"] as? Double ?? 0) > (self.state()["height"] as? Double ?? .infinity) }
        let field = app.textFields["native-planner-query"]
        XCTAssertTrue(field.isHittable)
        XCTAssertTrue(app.buttons["native-more"].isHittable)
        capture("s2-native-landscape")
    }
}
