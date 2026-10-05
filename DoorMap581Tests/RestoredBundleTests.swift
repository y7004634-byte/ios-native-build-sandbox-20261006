import MapKit
import XCTest
@testable import DoorMap581

final class RestoredBundleTests:XCTestCase {
    func testActualLoopbackStartupAndHTTPGzipRead() throws {
        let root=try XCTUnwrap(Bundle.main.url(forResource:"Behavior",withExtension:nil)),server=NativeBundleServer(bundleRoot:root,port:0)
        let started=expectation(description:"Loopback listener ready"),loaded=expectation(description:"Exact gzip resource read over HTTP")
        server.start{result in
            switch result {
            case .failure(let error):XCTFail(error.localizedDescription);started.fulfill();loaded.fulfill()
            case .success(let url):
                XCTAssertEqual(url.host,"127.0.0.1");started.fulfill()
                URLSession.shared.dataTask(with:url.appendingPathComponent("offline/taichung-official-202608-v1/manifest.json")){data,response,error in
                    XCTAssertNil(error);XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
                    let document=data.flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:Any]}
                    XCTAssertEqual(document?["addressCount"] as? Int,756225);loaded.fulfill()
                }.resume()
            }
        }
        wait(for:[started,loaded],timeout:8);server.stop()
    }
    func testGzipRejectsTruncationAndExpansionLimit() throws {
        let root=try XCTUnwrap(Bundle.main.url(forResource:"Behavior",withExtension:nil))
        let data=try Data(contentsOf:root.appendingPathComponent("native-data/osm-manifest.json.gz"))
        let decoded=try NativeGzip.decode(data),doc=try XCTUnwrap(JSONSerialization.jsonObject(with:decoded) as? [String:Any])
        XCTAssertEqual(doc["version"] as? String,"native-original-osm-fitlock6")
        XCTAssertThrowsError(try NativeGzip.decode(Data(data.prefix(data.count/2))))
        XCTAssertThrowsError(try NativeGzip.decode(data,maximumBytes:16))
    }
    func testLoopbackResourcesResolveOnlyInsideBundle() throws {
        let root=try XCTUnwrap(Bundle.main.url(forResource:"Behavior",withExtension:nil)),server=NativeBundleServer(bundleRoot:root)
        XCTAssertEqual(server.localFile(for:"/")?.lastPathComponent,"index.html")
        XCTAssertNil(server.localFile(for:"/../Info.plist"));XCTAssertNil(server.localFile(for:"/%2e%2e/Info.plist"));XCTAssertNil(server.localFile(for:"/a\\b"))
        let bytes=try XCTUnwrap(server.readResource("/offline/taichung-official-202608-v1/manifest.json")),doc=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        XCTAssertEqual(doc["addressCount"] as? Int,756225)
    }
    func testPublicPolygonHolesRetainOriginalCoordinates() throws {
        let rings=[[[120.6,24.1],[120.7,24.1],[120.7,24.2],[120.6,24.1]],[[120.61,24.11],[120.62,24.11],[120.62,24.12],[120.61,24.11]]]
        let feature=try XCTUnwrap(NativeSceneFeature(["layer":"community","source":"official-communities","type":"fill","geometry":["type":"Polygon","coordinates":rings]]))
        XCTAssertEqual(feature.paths,rings);XCTAssertNil(feature.coordinate)
    }
}
