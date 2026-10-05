import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import DoorMapCore
#else
@testable import DoorMap581
#endif

final class NativeSearchCoreTests: XCTestCase {
    struct Golden: Decodable {
        let sourceHash:String,indexHash:String,rows:Int,cases:[Case],normalizations:[Normalization],edits:[Edit]
        struct Case:Decodable { let query:String,center:DoorCoordinate,ids:[String],priorities:[Int],kinds:[String],listIDs:[String],pinIDs:[String],radius:Double? }
        struct Normalization:Decodable { let text:String,normalized:String,tokens:[String] }
        struct Edit:Decodable { let a:String,b:String,expected:Bool }
    }
    private func golden() throws -> Golden {
        #if SWIFT_PACKAGE
        let url=Bundle.module.url(forResource:"search-golden",withExtension:"json",subdirectory:"NativeCoreFixtures")
        #else
        let url=Bundle(for:Self.self).url(forResource:"search-golden",withExtension:"json",subdirectory:"NativeCoreFixtures")
        #endif
        return try JSONDecoder().decode(Golden.self,from:Data(contentsOf:XCTUnwrap(url)))
    }
    private func index() throws -> DoorSearchIndex {
        #if SWIFT_PACKAGE
        let path=try XCTUnwrap(ProcessInfo.processInfo.environment["DOOR_SEARCH_INDEX"],"Run scripts/test-native-core after staging the existing index; do not skip the real-data test")
        let bytes=try Data(contentsOf:URL(fileURLWithPath:path))
        #else
        let url=try XCTUnwrap(Bundle.main.url(forResource:"search-index.json",withExtension:"gz",subdirectory:"Behavior/offline/taichung-prebuilt"))
        let bytes=try NativeGzip.decode(Data(contentsOf:url))
        #endif
        XCTAssertEqual(DoorDigest.sha256(bytes),"47e82698f8901f85193c2e726d4dd1d2c2f51d96878f2ec9fb0d1c5968591718")
        return try JSONDecoder().decode(DoorSearchIndex.self,from:bytes)
    }
    func testAcceptedRealIndexCandidateAndWindowParity() throws {
        let fixture=try golden(),data=try index()
        XCTAssertEqual(fixture.sourceHash,DoorSearchCore.referenceSHA256)
        XCTAssertEqual(data.version,"tcg-search-202609-v4-master-r2");XCTAssertEqual(data.rows.count,fixture.rows)
        let prepared=data.rows.map(DoorSearchCore.Prepared.init)
        var originalNames:[String:String]=[:]
        for row in data.rows where originalNames[DoorSearchCore.key(row)] == nil { originalNames[DoorSearchCore.key(row)]=row.displayName }
        for c in fixture.cases {
            let ranked=DoorSearchCore.rank([prepared],query:c.query,center:c.center)
            XCTAssertEqual(ranked.map(\.id),c.ids,"Candidate IDs/order: \(c.query)")
            XCTAssertEqual(ranked.map(\.matchPriority),c.priorities,"Priority: \(c.query)")
            XCTAssertEqual(ranked.map(\.matchKind),c.kinds,"Match kind: \(c.query)")
            let view=DoorSearchWindow.present(ranked,query:c.query,center:c.center)
            XCTAssertEqual(view.list.map(\.id),c.listIDs,"List: \(c.query)")
            XCTAssertEqual(view.pins.map(\.id),c.pinIDs,"Pins: \(c.query)")
            XCTAssertEqual(view.listRadiusM,c.radius,"Radius: \(c.query)")
            for row in ranked { XCTAssertEqual(row.record.displayName,originalNames[row.id]) }
        }
    }
    func testUnicodeNormalizationAndTokenParity() throws {
        for n in try golden().normalizations {
            XCTAssertEqual(DoorSearchCore.normalize(n.text),n.normalized,n.text)
            XCTAssertEqual(DoorSearchCore.tokens(n.text),n.tokens,n.text)
        }
    }
    func testGeneratedOneEditParity() throws {
        for c in try golden().edits { XCTAssertEqual(DoorSearchCore.oneEdit(c.a,c.b),c.expected,"\(c.a) / \(c.b)") }
    }
    func testNumericAliasDoesNotMatchCoordinatesOrHouseNumbers() {
        let p=[DoorSearchRecord(displayName:"普通餐館",lat:24.13711,lng:120.7,address:"測試路711號",osmKey:"node/1")].map(DoorSearchCore.Prepared.init)
        XCTAssertTrue(DoorSearchCore.rank([p],query:"711",center:nil).isEmpty)
    }
    func testRealSourceIdentityIsNotRewrittenAndDedupCanonicalizesOSMType() {
        let r=DoorSearchRecord(displayName:"全家便利商店",lat:24.1,lng:120.7,osmKey:"N/17",branch:"甲乙門市")
        var duplicate=r;duplicate.osmKey="node:17"
        let result=DoorSearchCore.rank([[.init(r)],[.init(duplicate)]],query:"FamilyMart",center:nil)
        XCTAssertEqual(result.count,1);XCTAssertEqual(result.first?.record,r);XCTAssertEqual(result.first?.id,"node:17")
    }
    func testOfficialCommunityOnlyConsumesProvenOSMAliases() {
        let raw=DoorSearchRecord(displayName:"同名社區",lat:24.1,lng:120.7,osmKey:"way/23")
        let other=DoorSearchRecord(displayName:"同名社區",lat:24.2,lng:120.8,osmKey:"way/24")
        let official=DoorSearchRecord(displayName:"官方社區全名",lat:24.1,lng:120.7,source:"official-community",communityId:"c1",osmAliases:["way/23"],identitySources:[raw,other])
        let result=DoorSearchCore.rank([[.init(raw),.init(other)],[.init(official)]],query:"同名社區",center:nil)
        XCTAssertEqual(Set(result.map(\.id)),Set(["official-community:c1","way:24"]))
        XCTAssertTrue(DoorSearchCore.locationText(official).contains("非入口"))
        var notProven=official;notProven.osmAliases=[]
        XCTAssertNil(DoorSearchCore.match(.init(notProven),DoorSearchCore.compile("同名社區")))
    }
    func testPaginationNeverTruncatesTheCandidateUniverseOrPins() {
        let c=DoorCoordinate(lat:24.1,lng:120.7)
        let p=(0..<101).map{DoorSearchCore.Prepared(.init(displayName:"甲咖啡\($0)",lat:c.lat+Double($0)*0.00001,lng:c.lng,feature:"cafe",osmKey:"node/\($0)"))}
        var session=DoorSearchSession();let t=session.begin(query:"咖啡",center:c)
        XCTAssertTrue(session.publish(p,provider:.local,for:t))
        XCTAssertEqual(session.presentation.candidates.count,101);XCTAssertEqual(session.presentation.pins.count,101)
        XCTAssertEqual(session.presentation.page().count,30)
        session.loadMore();XCTAssertEqual(session.renderLimit,60)
        session.loadMore();session.loadMore();XCTAssertEqual(session.presentation.page(through:session.renderLimit).count,101)
    }
    func testStaleResponsesCannotOverrideClearOrAreaSearch() {
        var session=DoorSearchSession()
        let first=session.begin(query:"全家",center:.init(lat:24,lng:120))
        let row=DoorSearchCore.Prepared(.init(displayName:"全家",lat:24,lng:120,osmKey:"node/1"))
        let next=session.begin(query:"全家",center:.init(lat:25,lng:121),submitted:true)
        XCTAssertFalse(session.publish([row],provider:.apple,for:first))
        XCTAssertTrue(session.publish([row],provider:.local,for:next))
        XCTAssertEqual(session.display,.mapResults)
        session.clear();XCTAssertFalse(session.publish([row],provider:.remote,for:next));XCTAssertTrue(session.presentation.candidates.isEmpty)
    }
    func testExpandedListStillHasThreeKmPins() {
        let c=DoorCoordinate(lat:24,lng:120)
        let rows=[100.0,2999,3001,7999,8001].enumerated().map{DoorSearchCore.Prepared(.init(displayName:"甲分店",lat:c.lat+$0.element/111320,lng:c.lng,osmKey:"node/\($0.offset)"))}
        let ranked=DoorSearchCore.rank([rows],query:"甲分店",center:c)
        let p=DoorSearchWindow.present(ranked,query:"甲分店",center:c)
        XCTAssertEqual(p.candidates.count,5);XCTAssertEqual(p.list.count,4);XCTAssertEqual(p.pins.count,2)
        XCTAssertEqual(p.listRadiusM,8000)
    }
    func testSourceIndexRejectsWrongCountAndInvalidCoordinates() {
        let bad="{\"version\":\"v4\",\"rowCount\":1,\"rows\":[]}".data(using:.utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(DoorSearchIndex.self,from:bad))
        let bad2="{\"version\":\"v4\",\"rowCount\":1,\"rows\":[[\"x\",\"x\",\"\",91,120,\"\",\"\",\"\",\"node/1\"]]}".data(using:.utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(DoorSearchIndex.self,from:bad2))
    }
    func testManualCorrectionNeverChangesRawGPSAndRejectsStaleDestination() {
        var state=DoorNavigationState();let gps=DoorCoordinate(lat:24,lng:120),target=DoorCoordinate(lat:24.1,lng:120.1)
        state.acceptRawPosition(gps);state.setCameraOwner(.fitTime);state.selectDestination(.init(coordinate:target,title:"目的地",source:"offline-index"))
        let revision=state.destinationRevision;state.beginCorrection();state.moveCorrection(.init(lat:24.2,lng:120.2));state.cancelCorrection()
        XCTAssertEqual(state.destination?.coordinate,target);XCTAssertEqual(state.rawPosition,gps);XCTAssertEqual(state.cameraOwner,.fitTime)
        state.beginCorrection();state.moveCorrection(.init(lat:24.3,lng:120.3));XCTAssertTrue(state.applyCorrection(expectedRevision:revision));XCTAssertEqual(state.rawPosition,gps)
        state.beginCorrection();XCTAssertFalse(state.applyCorrection(expectedRevision:revision))
    }
    func testExplicitSearchIsAvailableDuringNavigationWithoutLosingCameraOwnership() {
        var state=DoorNavigationState();state.setMode(.navigating);state.setCameraOwner(.fitDistance)
        XCTAssertFalse(state.searchVisible);state.requestSearch();XCTAssertTrue(state.searchVisible)
        XCTAssertEqual(state.mode,.navigating);XCTAssertEqual(state.cameraOwner,.fitDistance)
        state.dismissSearch();XCTAssertFalse(state.searchVisible);state.setMode(.browse);XCTAssertTrue(state.searchVisible)
    }
}
