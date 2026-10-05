import MapKit
import XCTest
@testable import DoorMap581

@MainActor final class NativeCameraAdapterTests:XCTestCase {
    func testActualMapKitZoomCompositionAndProjection() throws {
        let window=UIWindow(frame:CGRect(x:0,y:0,width:390,height:844)),controller=UIViewController(),map=MKMapView(frame:window.bounds)
        window.rootViewController=controller;controller.view.addSubview(map);window.makeKeyAndVisible();map.layoutIfNeeded()
        map.layoutMargins=UIEdgeInsets(top:0,left:0,bottom:95,right:0)
        map.preferredConfiguration=MKStandardMapConfiguration(elevationStyle:.flat)
        for (zoom,pitch) in [(15.0,0.0),(16.8,58.0),(18.15,58.0),(18.85,0.0)] {
            let metrics=NativeCameraAdapter.apply(["center":["lat":24.1477,"lng":120.6736],"zoom":zoom,"pitch":pitch,"bearing":91.0,"padding":["top":250.0,"bottom":80.0,"left":12.0,"right":75.0]],to:map)
            XCTAssertEqual(try XCTUnwrap(metrics["actualZoom"]),zoom,accuracy:0.18)
            XCTAssertEqual(try XCTUnwrap(metrics["scaleRatio"]),1,accuracy:0.13)
            XCTAssertLessThan(try XCTUnwrap(metrics["anchorErrorPoints"]),12)
            let homography=try XCTUnwrap(NativeCameraAdapter.homography(map));XCTAssertEqual((homography["matrix"] as? [Double])?.count,8)
        }
        window.isHidden=true
    }
}
