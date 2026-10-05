import XCTest

final class NativeRouteUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--native-port-s3"]
        app.launchEnvironment["DOOR_NATIVE_S3_UI_TEST"] = "1"
        app.launchEnvironment["DOOR_NATIVE_CAMERA_FIXTURE"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["native-route"].waitForExistence(timeout: 25))
        wait("route choices fixture ready") { (self.state()["routeCandidateCount"] as? Int ?? 0) == 2 }
    }
    override func tearDownWithError() throws { app?.terminate(); XCUIDevice.shared.orientation = .portrait }
    private func state() -> [String: Any] {
        let e=app.staticTexts["native-s2-state"]
        guard e.exists,let value=e.value as? String,let data=value.data(using:.utf8),
              let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else{return [:]}
        return json
    }
    private func wait(_ name:String,seconds:TimeInterval=20,_ f:@escaping()->Bool){
        let e=XCTNSPredicateExpectation(predicate:NSPredicate{_,_ in f()},object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[e],timeout:seconds),.completed,name)
    }
    func testNativeRouteChoicesSwitchCommittedGeometryWithoutWebView() {
        XCTAssertEqual(state()["routeSelectedIndex"] as? Int,0)
        XCTAssertEqual(state()["routeCandidateCount"] as? Int,2)
        XCTAssertEqual(app.webViews.count,0)
        app.buttons["native-route"].tap()
        let alternate=app.buttons.matching(NSPredicate(format:"label CONTAINS %@", "備選 2")).firstMatch
        XCTAssertTrue(alternate.waitForExistence(timeout:8))
        alternate.tap()
        wait("alternative selected"){ (self.state()["routeSelectedIndex"] as? Int ?? -1)==1 }
        XCTAssertEqual(state()["routeCandidateCount"] as? Int,2)
        XCTAssertEqual(app.webViews.count,0)
        let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());shot.name="s5-native-route-alternative";shot.lifetime = .keepAlways;add(shot)
        let bytes=try! JSONSerialization.data(withJSONObject:state(),options:[.sortedKeys,.prettyPrinted])
        let stateFile=XCTAttachment(data:bytes,uniformTypeIdentifier:"public.json");stateFile.name="s5-native-route-state";stateFile.lifetime = .keepAlways;add(stateFile)
    }
}
