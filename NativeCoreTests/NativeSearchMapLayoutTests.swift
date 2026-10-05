import Foundation
import XCTest
#if canImport(DoorMap581)
@testable import DoorMap581
#elseif canImport(DoorMapCore)
@testable import DoorMapCore
#else
@testable import DoorMapLayout
#endif

final class NativeSearchMapLayoutTests: XCTestCase {
    func testDensePoolIsGroupedWithoutLosingAnyIdentity() {
        let points=(0..<10_000).map { i in
            DoorSearchMapLayout.Point(id:"poi-\(i)",x:Double(i % 400),y:Double((i*37) % 870))
        }
        let p=DoorSearchMapLayout.plan(points,width:402,height:874)
        XCTAssertLessThanOrEqual(p.groups.count,8*16)
        XCTAssertEqual(p.accountedUniqueCount,points.count)
        XCTAssertEqual(Set(p.visibleIDs),Set(points.map(\.id)))
        XCTAssertTrue(p.offscreenIDs.isEmpty)
        XCTAssertTrue(p.unprojectableIDs.isEmpty)
        XCTAssertTrue(p.duplicateIDs.isEmpty)
    }
    func testViewportChangesMaterializeOffscreenPointsWithoutTruncatingPool() {
        let original=[DoorSearchMapLayout.Point(id:"near",x:20,y:30),
                      .init(id:"far",x:800,y:30),.init(id:"outside",x:1600,y:30)]
        let first=DoorSearchMapLayout.plan(original,width:402,height:874)
        XCTAssertEqual(first.visibleIDs,["near"])
        XCTAssertEqual(first.offscreenIDs,["far","outside"])
        let moved=original.map { DoorSearchMapLayout.Point(id:$0.id,x:$0.x-780,y:$0.y) }
        let second=DoorSearchMapLayout.plan(moved,width:402,height:874)
        XCTAssertEqual(second.visibleIDs,["far"])
        XCTAssertEqual(second.offscreenIDs,["near","outside"])
        XCTAssertEqual(first.accountedUniqueCount,original.count)
        XCTAssertEqual(second.accountedUniqueCount,original.count)
        XCTAssertEqual(original.map(\.id),["near","far","outside"])
    }
    func testCoincidentPointsRetainAllMembersForExplicitSelection() {
        let points=(0..<1149).map { DoorSearchMapLayout.Point(id:"restaurant-\($0)",x:160,y:350) }
        let p=DoorSearchMapLayout.plan(points,width:402,height:874)
        XCTAssertEqual(p.groups.count,1)
        XCTAssertEqual(p.groups.first?.memberIDs,points.map(\.id))
        XCTAssertEqual(p.groups.first?.x,160)
        XCTAssertEqual(p.groups.first?.y,350)
        XCTAssertEqual(p.accountedUniqueCount,1149)
    }
    func testBadProjectionNeverProducesAFakeZeroCoordinatePin() {
        let points=[DoorSearchMapLayout.Point(id:"bad-x",x:.nan,y:5),
                    .init(id:"bad-y",x:2,y:.infinity),.init(id:"good",x:200,y:300)]
        let p=DoorSearchMapLayout.plan(points,width:402,height:874)
        XCTAssertEqual(p.visibleIDs,["good"])
        XCTAssertEqual(p.unprojectableIDs,["bad-x","bad-y"])
        XCTAssertEqual(p.accountedUniqueCount,3)
        let invalid=DoorSearchMapLayout.plan(points,width:0,height:874)
        XCTAssertTrue(invalid.groups.isEmpty)
        XCTAssertEqual(Set(invalid.unprojectableIDs),Set(points.map(\.id)))
    }
    func testStableMembershipIdentityAndSingletonSourceIdentity() {
        let points=[DoorSearchMapLayout.Point(id:"node:17",x:10,y:20),
                    .init(id:"official-community:abc",x:15,y:20),.init(id:"way:99",x:300,y:700)]
        let p=DoorSearchMapLayout.plan(points,width:402,height:874)
        XCTAssertEqual(p,DoorSearchMapLayout.plan(points,width:402,height:874))
        XCTAssertEqual(p.groups[0].memberIDs,["node:17","official-community:abc"])
        XCTAssertEqual(p.groups[1].memberIDs,["way:99"])
        let moved=points.map { DoorSearchMapLayout.Point(id:$0.id,x:$0.x+2,y:$0.y+2) }
        XCTAssertEqual(p.groups.map(\.key),DoorSearchMapLayout.plan(moved,width:402,height:874).groups.map(\.key))
    }
    func testBoundaryAndDuplicateAccountingDoesNotInventOrSilentlyDropRecords() {
        let points=[DoorSearchMapLayout.Point(id:"edge",x:-56,y:0),
                    .init(id:"outside",x:-56.01,y:0),.init(id:"duplicate",x:4,y:5),
                    .init(id:"duplicate",x:8,y:9)]
        let p=DoorSearchMapLayout.plan(points,width:402,height:874)
        XCTAssertEqual(Set(p.visibleIDs),Set(["edge","duplicate"]))
        XCTAssertEqual(p.offscreenIDs,["outside"])
        XCTAssertEqual(p.duplicateIDs,["duplicate"])
        XCTAssertEqual(p.accountedUniqueCount,3)
    }
}
