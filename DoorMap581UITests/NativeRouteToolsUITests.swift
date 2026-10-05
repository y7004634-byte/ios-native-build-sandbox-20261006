import XCTest

final class NativeRouteToolsUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--native-port-s3"]
        app.launchEnvironment["DOOR_NATIVE_S3_UI_TEST"] = "1"
        app.launchEnvironment["DOOR_NATIVE_CAMERA_FIXTURE"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["native-more"].waitForExistence(timeout: 25))
        wait("route fixture ready") { (self.state()["routeCandidateCount"] as? Int ?? 0) == 2 }
    }
    override func tearDownWithError() throws { app?.terminate(); XCUIDevice.shared.orientation = .portrait }
    private func state() -> [String: Any] {
        let e=app.staticTexts["native-s2-state"]
        guard e.exists,let v=e.value as? String,let b=v.data(using:.utf8),
              let j=try? JSONSerialization.jsonObject(with:b) as? [String:Any] else{return [:]}
        return j
    }
    private func wait(_ name:String,seconds:TimeInterval=20,_ f:@escaping()->Bool){
        let e=XCTNSPredicateExpectation(predicate:NSPredicate{_,_ in f()},object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[e],timeout:seconds),.completed,name)
    }
    private func openTools() {
        app.buttons["native-more"].tap()
        let tools=app.buttons["native-more-route-tools"]; XCTAssertTrue(tools.waitForExistence(timeout:5)); tools.tap()
    }
    private func action(_ text:String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format:"label CONTAINS %@",text)).firstMatch
    }
    func testViaUndoCancelCommitAndAvoidArea() {
        XCTAssertEqual(state()["viaCount"] as? Int,0)
        openTools(); let begin=action("開始編輯路線"); XCTAssertTrue(begin.waitForExistence(timeout:5)); begin.tap()
        wait("editor begins"){ self.state()["routeEditorActive"] as? Bool == true }

        openTools(); let addVia=action("目前地圖中心加入途經"); XCTAssertTrue(addVia.waitForExistence(timeout:5)); addVia.tap()
        wait("preview after add"){ (self.state()["routeEditorViaCount"] as? Int ?? 0)==1 && self.state()["routeEditorReady"] as? Bool == true && self.state()["routePreviewVisible"] as? Bool == true }
        XCTAssertTrue(app.otherElements["native-via-0"].exists || app.maps.descendants(matching:.any)["native-via-0"].exists)

        openTools(); let undo=action("撤銷上一步"); XCTAssertTrue(undo.waitForExistence(timeout:5)); undo.tap()
        wait("undo removes draft via"){ (self.state()["routeEditorViaCount"] as? Int ?? -1)==0 }
        openTools(); let add2=action("目前地圖中心加入途經"); XCTAssertTrue(add2.waitForExistence(timeout:5)); add2.tap()
        wait("second draft"){ (self.state()["routeEditorViaCount"] as? Int ?? 0)==1 }
        openTools(); let cancel=action("取消編輯"); XCTAssertTrue(cancel.waitForExistence(timeout:5)); cancel.tap()
        wait("cancel preserves committed route"){ self.state()["routeEditorActive"] as? Bool == false && (self.state()["viaCount"] as? Int ?? -1)==0 && self.state()["routePreviewVisible"] as? Bool == false }

        openTools(); let begin2=action("開始編輯路線"); XCTAssertTrue(begin2.waitForExistence(timeout:5)); begin2.tap()
        openTools(); let add3=action("目前地圖中心加入途經"); XCTAssertTrue(add3.waitForExistence(timeout:5)); add3.tap()
        wait("ready to commit"){ self.state()["routeEditorReady"] as? Bool == true && (self.state()["routeEditorViaCount"] as? Int ?? 0)==1 }
        openTools(); let done=action("完成編輯"); XCTAssertTrue(done.waitForExistence(timeout:5)); done.tap()
        wait("explicit done commits via"){ self.state()["routeEditorActive"] as? Bool == false && (self.state()["viaCount"] as? Int ?? 0)==1 && self.state()["routePreviewVisible"] as? Bool == false }

        openTools(); let avoid=action("新增避讓區 80m"); XCTAssertTrue(avoid.waitForExistence(timeout:5)); avoid.tap()
        wait("avoid overlay"){ (self.state()["avoidAreaCount"] as? Int ?? 0)==1 && (self.state()["avoidOverlayCount"] as? Int ?? 0)==1 }
        XCTAssertEqual(app.webViews.count,0)

        let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());shot.name="s6-route-tools";shot.lifetime = .keepAlways;add(shot)
        let bytes=try! JSONSerialization.data(withJSONObject:state(),options:[.sortedKeys,.prettyPrinted])
        let st=XCTAttachment(data:bytes,uniformTypeIdentifier:"public.json");st.name="s6-route-tools-state";st.lifetime = .keepAlways;add(st)
    }
}
