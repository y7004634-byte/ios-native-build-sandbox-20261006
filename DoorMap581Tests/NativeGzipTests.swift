import XCTest
@testable import DoorMap581

final class NativeGzipTests: XCTestCase {
    func testDeterministicEncoderReproducesAcceptedBuild8Bytes() throws {
        let seed = try NativeSeedBundle(bundle: .main)
        let path = "offline/taichung_sources.json"
        let accepted = try seed.encoded(path + ".gz")
        let decoded = try seed.decode(accepted, path: path)
        let rebuilt = try NativeGzip.encodeDeterministic(decoded)
        XCTAssertEqual(rebuilt, accepted)
        XCTAssertEqual(DoorDigest.sha256(rebuilt), "baf11a5f121ad56adebe94e9e96ba14d73823b36cf773c980df1a7de75e85f1d")
        XCTAssertEqual(try NativeGzip.decode(rebuilt), decoded)
    }
}
