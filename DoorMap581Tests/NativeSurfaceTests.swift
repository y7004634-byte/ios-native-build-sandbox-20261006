import Foundation
import UIKit
import XCTest
@testable import DoorMap581

final class NativeSurfaceTests: XCTestCase {
    private func resources() throws -> (NativePublicResources, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("581-native-s2-tests-" + UUID().uuidString)
        return (try NativePublicResources(seed: NativeSeedBundle(bundle: .main), offlineRoot: root), root)
    }
    func testActualCommunityDecoderRetainsAllIdentitiesAndAliases() async throws {
        let (data, root) = try resources(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try await data.data("offline/taichung-community-1150630-v2/search-index.json")
        let index = try JSONDecoder().decode(DoorCommunityIndex.self, from: bytes)
        XCTAssertEqual(index.records.count, 7285)
        XCTAssertEqual(Set(index.records.compactMap(\.communityId)).count, 7285)
        XCTAssertEqual(Set(index.records.flatMap(\.osmAliases)).count, index.records.flatMap(\.osmAliases).count)
        XCTAssertTrue(index.scopes.values.contains("point"))
        XCTAssertTrue(index.scopes.values.contains("building"))
        XCTAssertTrue(index.scopes.values.contains("community"))
    }
    func testActualCommunitySourceNameStillMatchesWithoutDuplicateOSMIdentity() async throws {
        let (data, root) = try resources(); defer { try? FileManager.default.removeItem(at: root) }
        let index = try JSONDecoder().decode(DoorCommunityIndex.self, from: await data.data("offline/taichung-community-1150630-v2/search-index.json"))
        let community = try XCTUnwrap(index.records.first { !$0.identitySources.isEmpty })
        let source = try XCTUnwrap(community.identitySources.first)
        let result = DoorSearchCore.rank([[.init(community)], [.init(source)]], query: source.displayName, center: community.coordinate)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.record.communityId, community.communityId)
        XCTAssertEqual(result.first?.record.displayName, community.displayName)
    }
    private func row(id: String, scope: String = "point", alias: String? = nil) -> [String: Any] {
        var r: [String: Any] = ["communityId": id, "displayName": "測試社區", "lat": 24.13, "lng": 120.68,
            "address": "臺中市南區測試路1號", "source": "official-community", "scope": scope,
            "osmAliases": [], "identitySources": [], "identityEvidence": []]
        if let alias {
            r["osmAliases"] = [alias]
            r["identitySources"] = [["displayName": "測試建物", "lat": 24.13, "lng": 120.68, "osmKey": alias, "source": "offline-index"]]
            r["identityEvidence"] = [["osmId": alias, "rule": "test-explicit-identity"]]
        }
        return r
    }
    private func decode(_ rows: [[String: Any]]) throws -> DoorCommunityIndex {
        try JSONDecoder().decode(DoorCommunityIndex.self, from: JSONSerialization.data(withJSONObject: ["version": "tcg-community-1150630-v2", "rows": rows]))
    }
    func testDuplicateCommunityIdentityIsRejected() throws {
        XCTAssertThrowsError(try decode([row(id: "a"), row(id: "a")]))
    }
    func testOneOSMObjectCannotBelongToTwoCommunities() throws {
        XCTAssertThrowsError(try decode([row(id: "a", alias: "way/1"), row(id: "b", alias: "way/1")]))
    }
    func testUnknownScopeIsNotSilentlyConvertedIntoPolygonOrPoint() throws {
        XCTAssertThrowsError(try decode([row(id: "a", scope: "invented-boundary")]))
    }
    func testRepositoryUsesFullRealCorpusAndNativeRadiusRules() async throws {
        let (data, root) = try resources(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = NativeSearchRepository(resources: data)
        let count = try await repo.counts(); XCTAssertEqual(count.local, 38950); XCTAssertEqual(count.community, 7285)
        let output = try await repo.search(query: "FamilyMart", center: .init(lat: 24.135, lng: 120.688))
        XCTAssertFalse(output.list.isEmpty)
        XCTAssertTrue(output.pins.allSatisfy { ($0.distanceM ?? .infinity) <= 3000 })
        XCTAssertLessThanOrEqual(output.page().count, 30)
        XCTAssertEqual(Set(output.candidates.map(\.id)).count, output.candidates.count)
    }
    func testRepositoryPreservesExpansionWithoutFarPins() async throws {
        let (data, root) = try resources(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = NativeSearchRepository(resources: data)
        let output = try await repo.search(query: "永隆門市", center: .init(lat: 24.135, lng: 120.688))
        XCTAssertTrue(output.expanded)
        XCTAssertGreaterThan(output.list.count, output.pins.count)
        XCTAssertTrue(output.list.allSatisfy { ($0.distanceM ?? .infinity) <= 8000 })
        XCTAssertTrue(output.pins.allSatisfy { ($0.distanceM ?? .infinity) <= 3000 })
    }
    @MainActor func testClearOwnsLateNativeRepositoryCompletion() async throws {
        let (data, root) = try resources(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = NativeSearchRepository(resources: data)
        let c = NativeSearchCoordinator(repository: repo, appleEnabled: false)
        c.begin("FamilyMart", center: .init(lat: 24.135, lng: 120.688), submitted: true)
        await Task.yield(); c.clear()
        _ = try await repo.counts(); await Task.yield()
        XCTAssertEqual(c.query, ""); XCTAssertFalse(c.busy); XCTAssertTrue(c.presentation.list.isEmpty)
        XCTAssertTrue(c.presentation.pins.isEmpty)
    }
    @MainActor func testApplePlanNormalizesIdentityWithoutInventingCoordinates() {
        XCTAssertEqual(NativeAppleSearchProvider.plan("7-11").term, "7-Eleven")
        XCTAssertEqual(NativeAppleSearchProvider.plan("全家").brandKey, "familymart")
        let generic = NativeAppleSearchProvider.plan("沒有硬編碼的小店")
        XCTAssertEqual(generic.term, "沒有硬編碼的小店"); XCTAssertNil(generic.brandKey)
        XCTAssertTrue(generic.acceptedNameTokens.isEmpty)
    }
    @MainActor func testNativeSurfaceHasNoWebViewAndDoesNotCreateATransportServer() {
        let c = NativePortViewController(initialURL: nil, testMode: true)
        c.loadViewIfNeeded(); c.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852); c.view.layoutIfNeeded()
        func count(_ v: UIView) -> Int { (String(describing: type(of: v)).contains("WKWebView") ? 1 : 0) + v.subviews.reduce(0) { $0 + count($1) } }
        XCTAssertEqual(count(c.view), 0)
        XCTAssertEqual(c.view.accessibilityIdentifier, "native-port-root")
        c.prepareForSceneDisconnect()
    }
}
