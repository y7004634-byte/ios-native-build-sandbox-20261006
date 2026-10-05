import CryptoKit
import XCTest
import WebKit
@testable import DoorMap581

final class NativeResourceTests: XCTestCase {
    func testSelectedOSMQueriesEqualFormerWholeDocumentResultsAndCacheIsBounded() throws {
        let root = try XCTUnwrap(Bundle.main.url(forResource:"Behavior",withExtension:nil))
        let fixtures = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"Fixtures",withExtension:nil))
        let packed = try Data(contentsOf: fixtures.appendingPathComponent("osm-query-baseline.json.gz"))
        let golden = try XCTUnwrap(JSONSerialization.jsonObject(with:NativeGzip.decode(packed)) as? [String:Any])
        XCTAssertEqual(golden["source"] as? String,"45fe6278e9ab9d5266099698d7e107d4aa518d18")
        let cases = try XCTUnwrap(golden["cases"] as? [[String:Any]])
        XCTAssertEqual(cases.count,9)
        let server = NativeBundleServer(bundleRoot:root)
        for item in cases {
            try autoreleasepool {
                let query = try XCTUnwrap(item["query"] as? String)
                let bytes = try XCTUnwrap(server.osmResponse(Data(query.utf8)),query)
                let actual = try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? NSDictionary)
                let expected = try XCTUnwrap(item["expected"] as? NSDictionary)
                XCTAssertEqual(actual,expected,query)
                XCTAssertLessThanOrEqual(server.retainedOsmRawBytes,NativeBundleServer.osmRawCacheBudget)
            }
        }
        XCTAssertGreaterThan(server.retainedOsmRawBytes,0)
        let cleared = expectation(description:"Queued background cache release")
        server.discardDisposableCaches { XCTAssertEqual(server.retainedOsmRawBytes,0); cleared.fulfill() }
        wait(for:[cleared],timeout:3)
        let query = try XCTUnwrap(cases[1]["query"] as? String)
        let restored = try XCTUnwrap(server.osmResponse(Data(query.utf8)))
        XCTAssertEqual(try JSONSerialization.jsonObject(with:restored) as? NSDictionary,cases[1]["expected"] as? NSDictionary)
    }

    func testWrongTileByteRangeHashIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("581-range-integrity-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("native-data"),withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let bytes = Data("{\"key\":\"12/3420/1764\",\"part\":0,\"elements\":[]}".utf8)
        try bytes.write(to:root.appendingPathComponent("tile.json"))
        let digest = SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
        var record:[String:Any] = ["path":"/tile.json","part":0,"byteOffset":0,"byteLength":bytes.count,"fileBytes":bytes.count,"fileSHA256":digest,"tileSHA256":digest]
        let indexPath=root.appendingPathComponent("native-data/osm-file-index.json")
        try JSONSerialization.data(withJSONObject:["12/3420/1764":[record]]).write(to:indexPath)
        let query=Data("way(around:250,24.147663,120.672973);".utf8)
        XCTAssertNotNil(NativeBundleServer(bundleRoot:root).osmResponse(query))
        record["tileSHA256"]=String(repeating:"0",count:64)
        try JSONSerialization.data(withJSONObject:["12/3420/1764":[record]]).write(to:indexPath)
        let server = NativeBundleServer(bundleRoot:root)
        XCTAssertNil(server.osmResponse(query))
    }

    func testOwnedScreenCanBeReleasedWithoutStrongScriptHandlerCycle() {
        weak var released: RestoredAppleMapViewController?
        autoreleasepool {
            var controller: RestoredAppleMapViewController? = RestoredAppleMapViewController(initialDeepLink:nil)
            released=controller
            _ = controller?.view
            controller?.prepareForSceneDisconnect()
            controller=nil
        }
        XCTAssertNil(released)
    }
}
