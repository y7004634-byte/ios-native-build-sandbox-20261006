import MapKit
import UIKit
import XCTest
@testable import DoorMap581

@MainActor final class NativeSearchPresentationTests: XCTestCase {
    private func values(_ count:Int) -> [DoorSearchCore.Result] {
        let records=(0..<count).map { i in
            DoorSearchRecord(displayName:"測試餐廳\(i)",lat:24.135,lng:120.688,feature:"restaurant",osmKey:"node/\(i)")
        }
        return DoorSearchCore.rank([records.map(DoorSearchCore.Prepared.init)],query:"restaurant",center:.init(lat:24.135,lng:120.688))
    }
    func testCoincidentNativeClusterContainsEveryOriginalRecordAndClears() throws {
        let map=MKMapView(frame:CGRect(x:0,y:0,width:402,height:874))
        map.setRegion(MKCoordinateRegion(center:.init(latitude:24.135,longitude:120.688),latitudinalMeters:1600,longitudinalMeters:1600),animated:false)
        let pool=values(1149), presenter=NativeSearchMapPresenter(map:map)
        presenter.setResults(pool)
        XCTAssertEqual(presenter.stats.poolCount,1149)
        XCTAssertEqual(presenter.stats.renderedMembers,1149)
        XCTAssertEqual(presenter.stats.renderedAnnotations,1)
        XCTAssertEqual(presenter.stats.offscreen,0)
        XCTAssertEqual(presenter.stats.unprojectable,0)
        let group=try XCTUnwrap(map.annotations.compactMap { $0 as? NativeSearchGroupAnnotation }.first)
        XCTAssertEqual(group.members,pool)
        XCTAssertEqual(Set(group.members.map(\.id)),Set(pool.map(\.id)))
        presenter.clear()
        XCTAssertTrue(map.annotations.isEmpty)
        XCTAssertEqual(presenter.stats.poolCount,0)
    }
    func testSingletonNativePinRetainsExactSourceCoordinateAndIdentity() throws {
        let map=MKMapView(frame:CGRect(x:0,y:0,width:402,height:874))
        map.setRegion(MKCoordinateRegion(center:.init(latitude:24.135,longitude:120.688),latitudinalMeters:1600,longitudinalMeters:1600),animated:false)
        let pool=values(1), presenter=NativeSearchMapPresenter(map:map)
        presenter.setResults(pool)
        let pin=try XCTUnwrap(map.annotations.compactMap { $0 as? NativeSearchAnnotation }.first)
        XCTAssertEqual(pin.result,pool[0])
        XCTAssertEqual(pin.coordinate.latitude,pool[0].record.lat)
        XCTAssertEqual(pin.coordinate.longitude,pool[0].record.lng)
        presenter.refresh()
        XCTAssertEqual(map.annotations.count,1)
        XCTAssertTrue(map.annotations.first === pin)
        presenter.clear()
    }
    func testCoincidentMemberTableRetainsRowsBeyondTheFirstPage() throws {
        let pool=values(96), controller=NativeSearchMembersViewController(members:pool)
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.tableView(controller.tableView,numberOfRowsInSection:0),96)
        for i in [0,29,30,60,95] {
            let cell=controller.tableView(controller.tableView,cellForRowAt:IndexPath(row:i,section:0))
            XCTAssertEqual(cell.textLabel?.text,pool[i].record.displayName)
            XCTAssertEqual(cell.accessibilityValue,pool[i].id)
        }
    }
}
