import Foundation
import XCTest
@testable import DoorMap581

final class NativeSeedTests: XCTestCase {
    private func isolatedRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("581-native-seed-test-" + UUID().uuidString)
    }
    func testPinnedCatalogContainsEveryPreviouslyAcceptedResourceWithoutAnotherProvider() throws {
        let seed = try NativeSeedBundle(bundle: .main)
        XCTAssertEqual(seed.manifest.files.count, 3122)
        XCTAssertEqual(try seed.manifest.identity, NativeSeedIdentity.manifestSHA256)
        XCTAssertTrue(seed.manifest.requiredComponents.contains("taichung-prebuilt"))
        XCTAssertTrue(seed.manifest.requiredComponents.contains("taichung-destination-v2"))
        XCTAssertTrue(seed.manifest.requiredComponents.contains("taichung-official-202608-v1"))
        XCTAssertTrue(seed.manifest.requiredComponents.contains("taichung-community-1150630-v2"))
        XCTAssertEqual(seed.manifest.files.reduce(Int64(0), { $0 + $1.bytes }), NativeSeedIdentity.storedBytes)
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.door581.appletest")
    }
    func testNativeDirectReadHasActualPOIsWithoutHTTPWebKitOrInstallationReceipt() async throws {
        let root = isolatedRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let resources = try NativePublicResources(seed: NativeSeedBundle(bundle: .main), offlineRoot: root)
        let receipt = try await resources.receipt(); XCTAssertNil(receipt)
        let index = try await resources.searchIndex()
        XCTAssertEqual(index.rowCount, 38950)
        let prepared = index.rows.map(DoorSearchCore.Prepared.init)
        let matches = DoorSearchCore.rank([prepared], query: "全家", center: .init(lat: 24.135, lng: 120.688))
        XCTAssertFalse(matches.isEmpty)
        XCTAssertFalse(matches.contains { $0.record.displayName == "" })
        let retained = await resources.cacheBytes; XCTAssertLessThanOrEqual(retained, NativePublicResources.decodedCacheBudget)
        await resources.releaseDisposableCaches()
        let after = await resources.cacheBytes; XCTAssertEqual(after, 0)
    }
    func testActualBundledComponentsInstallAtomicallyAndReopenUsingNativeFiles() async throws {
        let root = isolatedRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let seed = try NativeSeedBundle(bundle: .main)
        let resources = try NativePublicResources(seed: seed, offlineRoot: root)
        let receipt = try await resources.installBundledSeed()
        XCTAssertEqual(receipt.origin, "bundled-seed")
        XCTAssertEqual(receipt.fileCount, 3122)
        XCTAssertEqual(receipt.storedBytes, NativeSeedIdentity.storedBytes)
        let reopened = try NativePublicResources(seed: seed, offlineRoot: root)
        let verified = try await reopened.verifyInstalled()
        XCTAssertEqual(verified, receipt)
        let index = try await reopened.searchIndex()
        XCTAssertEqual(index.rowCount, 38950)
        XCTAssertEqual(index.version, "tcg-search-202609-v4-master-r2")
        let second = try await reopened.installBundledSeed()
        XCTAssertEqual(second, receipt)
    }

    func testInstalledCopyCanBeDeletedAndBundledSearchStillWorks() async throws {
        let root = isolatedRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let seed = try NativeSeedBundle(bundle: .main)
        let resources = try NativePublicResources(seed: seed, offlineRoot: root)
        let receipt = try await resources.installBundledSeed()
        XCTAssertNotNil(try await resources.receipt())
        let removed = try await resources.removeInstalledCopy()
        XCTAssertEqual(removed, receipt)
        XCTAssertNil(try await resources.receipt())
        let index = try await resources.searchIndex()
        XCTAssertEqual(index.rowCount, 38950)
    }

    func testNetworkPayloadMustReproduceAcceptedDecodedAndGzipHashes() throws {
        let seed = try NativeSeedBundle(bundle: .main)
        let path = "offline/taichung_sources.json"
        let accepted = try seed.encoded(path + ".gz")
        let decoded = try seed.decode(accepted, path: path)
        XCTAssertEqual(try seed.encodeValidatedDecoded(decoded, path: path), accepted)
        var corrupted = decoded
        corrupted[corrupted.startIndex] ^= 0x01
        XCTAssertThrowsError(try seed.encodeValidatedDecoded(corrupted, path: path))
    }
}
