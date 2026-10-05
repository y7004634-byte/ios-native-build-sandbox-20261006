import XCTest

/// Sensors and routes are explicitly simulated. Public data uses the full real bundle.
final class NativeMapUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait
        app=XCUIApplication();app.launchArguments=["--reset-ui-test-preferences"]
        app.launchEnvironment["DOOR_UI_TEST"]="1";app.launch()
        XCTAssertTrue(button("GPS").waitForExistence(timeout:20),app.debugDescription)
        button("GPS").tap();waitState("sensor"){$0 as? String == "SIMULATED"}
    }
    private func button(_ label:String)->XCUIElement{app.descendants(matching:.any).matching(NSPredicate(format:"label == %@",label)).firstMatch}
    private func prefix(_ label:String)->XCUIElement{app.descendants(matching:.any).matching(NSPredicate(format:"label BEGINSWITH %@",label)).firstMatch}
    private func status()->[String:Any]{
        let element=app.descendants(matching:.any)["native-restoration-status"].firstMatch
        guard let value=element.value as? String,let data=value.data(using:.utf8),let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else{return [:]};return object
    }
    private func waitState(_ key:String,timeout:TimeInterval=20,_ check:@escaping(Any?)->Bool){
        let expectation=XCTNSPredicateExpectation(predicate:NSPredicate{_,_ in check(self.status()[key])},object:app)
        XCTAssertEqual(XCTWaiter.wait(for:[expectation],timeout:timeout),.completed,"\(key): \(status())")
    }
    private func shot(_ name:String){let a=XCTAttachment(screenshot:XCUIScreen.main.screenshot());a.name=name;a.lifetime = .keepAlways;add(a);if let bytes=try? JSONSerialization.data(withJSONObject:status(),options:[.prettyPrinted,.sortedKeys]){let d=XCTAttachment(data:bytes,uniformTypeIdentifier:"public.json");d.name=name+"-measured-state";d.lifetime = .keepAlways;add(d)}}
    private func more(){if button("Apple 地圖設定").exists{return};let b=button("更多功能");XCTAssertTrue(b.waitForExistence(timeout:5));b.tap();XCTAssertTrue(button("Apple 地圖設定").waitForExistence(timeout:5))}
    private func closeMore(){if button("Apple 地圖設定").exists{button("更多功能").tap()}}
    private func routeToggle()->XCUIElement{app.descendants(matching:.any).matching(NSPredicate(format:"label IN %@",["路線開關","關閉導航路線","開啟導航路線"])).firstMatch}
    private func moreViewport()->CGRect{let r=status()["moreViewport"] as? [String:Double] ?? [:];return CGRect(x:r["x"] ?? 0,y:r["y"] ?? 0,width:r["width"] ?? 0,height:r["height"] ?? 0)}
    private func revealRouteToggle(){
        waitState("moreViewport"){(($0 as? [String:Double])?["height"] ?? 0)>0}
        for _ in 0..<4{
            if routeToggle().exists && moreViewport().insetBy(dx:-1,dy:-1).contains(routeToggle().frame){break}
            app.coordinate(withNormalizedOffset:CGVector(dx:0.70,dy:0.72)).press(forDuration:0.10,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.70,dy:0.38)))
        }
        XCTAssertTrue(routeToggle().isHittable);XCTAssertTrue(moreViewport().insetBy(dx:-1,dy:-1).contains(routeToggle().frame),"Control \(routeToggle().frame) clipped by measured menu \(moreViewport())")
    }
    private func closeDialog(){let choices=app.buttons.matching(NSPredicate(format:"label == %@","關閉")).allElementsBoundByIndex;guard let close=choices.first(where:{$0.isHittable}) else{XCTFail("No visible dialog close button");return};close.tap()}
    private func openSettings(){more();button("Apple 地圖設定").tap();XCTAssertTrue(app.tables["map-settings"].waitForExistence(timeout:5))}
    private func reveal(_ e:XCUIElement){for _ in 0..<10{if e.isHittable{return};app.tables.firstMatch.swipeUp()};for _ in 0..<10{if e.isHittable{return};app.tables.firstMatch.swipeDown()};XCTAssertTrue(e.isHittable)}
    private func closeSettings(){app.navigationBars.buttons["完成"].tap();XCTAssertTrue(button("更多功能").waitForExistence(timeout:5));if button("Apple 地圖設定").isHittable{closeMore()}}
    func testGPSFailureHeadingLifecycleAndNativeMap() {
        XCTAssertTrue(app.descendants(matching:.any)["apple-main-map"].firstMatch.exists)
        button("359→1°").tap();waitState("heading"){v in guard let n=v as? Double else{return false};return min(abs(n),abs(360-n))<15}
        button("GPS失敗").tap();XCTAssertTrue(button("啟用 GPS").waitForExistence(timeout:5));shot("01-simulated-gps-failure")
        button("恢復").tap();button("背景返回").tap();waitState("hold"){$0 as? Bool == false}
        XCUIDevice.shared.press(.home);app.activate();waitState("hold"){$0 as? Bool == false}
        shot("02-recovered-native-map-direction")
    }
    func testFITContinuousManualGesturePiPAndRouteVisibility() {
        button("測試路線").tap();prefix("FIT 鎖定").tap();waitState("fit"){$0 as? Bool == true}
        let commands=status()["cameraRequests"] as? Int ?? 0
        button("前進").tap();waitState("fit"){$0 as? Bool == true};waitState("cameraRequests"){($0 as? Int ?? 0)>commands}
        let camera=status()["nativeCamera"] as? [String:Double];XCTAssertLessThan(abs((camera?["actualZoom"] ?? 0)-(camera?["requestedZoom"] ?? 99)),0.2);XCTAssertLessThan(camera?["anchorErrorPoints"] ?? .infinity,12);shot("03-continuous-fit-pip-reservation")
        let a=app.coordinate(withNormalizedOffset:CGVector(dx:0.65,dy:0.45)),b=app.coordinate(withNormalizedOffset:CGVector(dx:0.45,dy:0.56))
        a.press(forDuration:0.15,thenDragTo:b);waitState("hold"){$0 as? Bool == false};waitState("fit"){$0 as? Bool == true}
        more();prefix("PiP 視野").tap();waitState("pip"){$0 as? Bool == false};closeMore();shot("04-fit-pip-off-after-native-pan")
        more();revealRouteToggle();shot("17-more-route-switch-visible");routeToggle().tap();waitState("route"){$0 as? Bool == false};more();revealRouteToggle();routeToggle().tap();waitState("route"){$0 as? Bool == true};closeMore()
        shot("05-restored-route-controls")
    }
    func testRealCommunityDoorplatesOSMAndMiniPreservesZoom() {
        button("實際社區資料").tap()
        waitState("community",timeout:30){($0 as? Int ?? 0)>0}
        waitState("osmTiles",timeout:30){($0 as? Int ?? 0)>0}
        waitState("officialTiles",timeout:30){($0 as? Int ?? 0)>0}
        waitState("publicSymbols",timeout:30){($0 as? Int ?? 0)>0}
        XCTAssertLessThan(status()["appReadyMillis"] as? Double ?? .infinity,20000)
        app.coordinate(withNormalizedOffset:CGVector(dx:0.65,dy:0.40)).tap();waitState("lastMapClick"){v in guard let p=v as? [String:Any],let c=p["lngLat"] as? [String:Double] else{return false};return abs((c["lat"] ?? 0)-24.147663)<0.01&&abs((c["lng"] ?? 0)-120.672973)<0.01}
        XCTAssertEqual(status()["hashFailures"] as? Int,0);XCTAssertEqual((status()["styleErrors"] as? [String])?.count,0)
        XCTAssertLessThan((status()["nativeCamera"] as? [String:Double])?["anchorErrorPoints"] ?? .infinity,12)
        prefix("展開終點資訊").tap();waitState("zoom"){abs(($0 as? Double ?? 0)-19.5)<0.05};shot("06-actual-community-and-19-5-doorplate-mini")
        button("小窗移動").tap();waitState("zoom"){($0 as? Double ?? 0)==20};let center=status()["miniCenter"] as? [String:Double]
        prefix("收合終點資訊").tap();prefix("展開終點資訊").tap();waitState("zoom"){($0 as? Double ?? 0)==20}
        let restored=status()["miniCenter"] as? [String:Double];XCTAssertEqual(restored?["lat"],center?["lat"]);XCTAssertEqual(restored?["lng"],center?["lng"])
        shot("07-manual-mini-geography-preserved")
        prefix("收合終點資訊").tap();button("測試路線").tap();waitState("zoom"){abs(($0 as? Double ?? 0)-19.5)<0.05}
    }
    func testOriginalPanelsAndAppleSettingsPersistence() {
        button("測試路線").tap();more();button("編輯路線").tap();XCTAssertTrue(button("↶ 上一步").waitForExistence(timeout:5));shot("08-original-route-editor")
        app.coordinate(withNormalizedOffset:CGVector(dx:0.55,dy:0.45)).tap()
        XCTAssertTrue(app.staticTexts["1 個控制點"].firstMatch.waitForExistence(timeout:5));button("↶ 上一步").tap()
        XCTAssertTrue(app.staticTexts["0 個控制點"].firstMatch.waitForExistence(timeout:5))
        button("取消").tap()
        more();button("路線記憶／備份").tap();XCTAssertTrue(button("匯出備份").waitForExistence(timeout:5));shot("16-original-personal-route-backup");closeDialog()
        more();button("自訂道路避開區").tap();XCTAssertTrue(button("匯出備份").waitForExistence(timeout:5));shot("09-original-avoid-backup-manager");closeDialog()
        more();button("管理台中離線導航資料").tap();XCTAssertTrue(button("刪除下載快取").waitForExistence(timeout:5));shot("10-original-offline-contract");closeDialog()
        openSettings();app.segmentedControls["appearance"].buttons["淺色"].tap();app.segmentedControls["emphasis"].buttons["淡化"].tap();shot("11-native-apple-settings-light")
        let traffic=app.switches["setting-traffic"];reveal(traffic);traffic.tap();closeSettings()
        app.terminate();app.launchArguments=[];app.launch();XCTAssertTrue(button("更多功能").waitForExistence(timeout:20));openSettings()
        XCTAssertTrue(app.segmentedControls["appearance"].buttons["淺色"].isSelected);reveal(app.switches["setting-traffic"]);XCTAssertEqual(app.switches["setting-traffic"].value as? String,"1");shot("12-native-settings-restored")
    }
    func testSmallScreenLayoutAndLandscape() {
        button("實際社區資料").tap();waitState("community",timeout:30){($0 as? Int ?? 0)>0}
        let frame=app.windows.firstMatch.frame
        for label in ["更多功能","回到目前位置並恢復跟隨","鏡頭前行模式"]{let b=button(label);XCTAssertTrue(b.isHittable,label);XCTAssertTrue(frame.contains(b.frame),label)}
        shot("13-real-data-portrait")
        prefix("展開終點資訊").tap();shot("14-real-doorplate-mini-portrait");prefix("收合終點資訊").tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        let e=XCTNSPredicateExpectation(predicate:NSPredicate{_,_ in self.app.windows.firstMatch.frame.width>self.app.windows.firstMatch.frame.height},object:app)
        XCTAssertEqual(XCTWaiter.wait(for:[e],timeout:8),.completed)
        let rendered=expectation(description:"Orientation render completed");DispatchQueue.main.asyncAfter(deadline:.now()+2){rendered.fulfill()};wait(for:[rendered],timeout:4)
        shot("15-real-data-landscape")
        let screen=app.windows.firstMatch.frame,map=app.descendants(matching:.any)["apple-main-map"].firstMatch.frame
        XCTAssertEqual(map.width,screen.width,accuracy:1);XCTAssertEqual(map.height,screen.height,accuracy:1)
        XCTAssertTrue(button("更多功能").isHittable);XCUIDevice.shared.orientation = .portrait
    }
}
