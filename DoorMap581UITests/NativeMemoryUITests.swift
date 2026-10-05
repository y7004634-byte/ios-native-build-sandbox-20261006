import XCTest

/// Identical public-data scenario, no screenshots during sampling and no phone claims.
final class NativeMemoryUITests: XCTestCase {
    private var app: XCUIApplication!
    private var phase = 0
    private func button(_ label: String) -> XCUIElement { app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch }
    private func prefix(_ label: String) -> XCUIElement { app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch }
    private func status() -> [String: Any] {
        let element = app.descendants(matching: .any)["native-restoration-status"].firstMatch
        guard let text = element.value as? String, let bytes = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return [:] }
        return value
    }
    private func waitState(_ key: String, timeout: TimeInterval = 30, _ check: @escaping (Any?) -> Bool) {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in check(self.status()[key]) }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: timeout), .completed, "\(key): \(status())")
    }
    private func settle(_ seconds: TimeInterval) {
        let e = expectation(description: "Fixed memory sampling dwell")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: seconds + 3)
    }
    private func measureOSMQuery() {
        let before=(status()["memoryAPI"] as? [String:Any])?["request"] as? Int ?? 0
        button("量測 OSM 查詢").tap()
        waitState("memoryAPI",timeout:45){value in guard let record=value as? [String:Any] else{return false};return (record["request"] as? Int ?? 0)>before && record["status"] as? Int == 200}
        XCTAssertGreaterThan((status()["memoryAPI"] as? [String:Any])?["elements"] as? Int ?? 0,0)
    }
    private func mark(_ name: String, dwell: TimeInterval = 6) {
        phase += 1; button("標記量測階段").tap()
        waitState("memoryPhase") { ($0 as? Int) == self.phase }
        settle(dwell)
        let state = status(), record: [String: Any] = ["name": name, "phase": phase, "timestamp": Date().timeIntervalSince1970, "state": state]
        let attachment = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = String(format: "%02d", phase) + "-" + name; attachment.lifetime = .keepAlways; add(attachment)
        let profile = state["memoryProfile"] as? [String: Any]
        XCTAssertNotNil(profile, "Native sampling missing")
        XCTAssertEqual(state["hashFailures"] as? Int, 0)
        XCTAssertEqual((state["styleErrors"] as? [String])?.count, 0)
        print("DOOR_MEMORY_STAGE \(name) phase=\(phase)")
    }
    func testRepeatedNavigationDestinationAndBackgroundMemory() {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(); app.launchArguments = ["--reset-ui-test-preferences"]
        app.launchEnvironment["DOOR_UI_TEST"] = "1"; app.launchEnvironment["DOOR_MEMORY_PROFILE"] = "1"
        app.launch()
        XCTAssertTrue(button("標記量測階段").waitForExistence(timeout: 30))
        mark("ready-without-simulated-fix")
        button("GPS").tap(); waitState("sensor") { $0 as? String == "SIMULATED" }
        mark("gps-default-area")
        button("實際社區資料").tap(); waitState("community") { ($0 as? Int ?? 0) > 0 }
        waitState("osmTiles") { ($0 as? Int ?? 0) > 0 }; waitState("officialTiles") { ($0 as? Int ?? 0) > 0 }
        mark("actual-community-and-doorplates")
        measureOSMQuery()
        mark("same-250m-osm-service-query")
        prefix("展開終點資訊").tap(); waitState("zoom") { abs(($0 as? Double ?? 0) - 19.5) < 0.05 }
        mark("nlsc-mini-expanded")
        prefix("收合終點資訊").tap()
        for cycle in 1...6 {
            button("測試路線").tap(); waitState("route") { $0 as? Bool == true }
            if status()["fit"] as? Bool != true { prefix("FIT 鎖定").tap() }
            button("前進").tap(); waitState("fit") { $0 as? Bool == true }
            mark("navigation-and-fit-cycle-\(cycle)", dwell: 3)
            button("實際社區資料").tap(); waitState("community") { ($0 as? Int ?? 0) > 0 }
            mark("community-destination-cycle-\(cycle)", dwell: 3)
            if cycle == 3 || cycle == 6 {
                XCUIDevice.shared.press(.home); settle(5)
                app.activate(); XCTAssertTrue(button("標記量測階段").waitForExistence(timeout: 10)); waitState("hold") { $0 as? Bool == false }
                mark("actual-background-return-cycle-\(cycle)")
            }
        }
        measureOSMQuery()
        mark("final-identical-community-and-query", dwell: 10)
        let profile = status()["memoryProfile"] as? [String: Any]
        XCTAssertNotNil(profile?["sceneGeometrySHA256"])
        let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); picture.name = "final-memory-scene-after-sampling"; picture.lifetime = .keepAlways; add(picture)
    }
}
