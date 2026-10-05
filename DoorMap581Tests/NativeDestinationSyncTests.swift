import XCTest
@testable import DoorMap581

final class NativeDestinationSyncTests: XCTestCase {
    func testFreshTaiwanPayloadNewerThanReceiptIsAccepted() {
        let payload = NativeDestinationSyncPayload(lat: 24.1477, lng: 120.6736, updatedAt: 1_900_000)
        XCTAssertEqual(payload.accepted(nowMS: 2_000_000, lastAppliedAt: 1_800_000),
                       DoorCoordinate(lat: 24.1477, lng: 120.6736))
    }

    func testDuplicateOrOlderPayloadIsRejected() {
        let payload = NativeDestinationSyncPayload(lat: 24.1477, lng: 120.6736, updatedAt: 1_900_000)
        XCTAssertNil(payload.accepted(nowMS: 2_000_000, lastAppliedAt: 1_900_000))
        XCTAssertNil(payload.accepted(nowMS: 2_000_000, lastAppliedAt: 1_950_000))
    }

    func testStaleOrOutsideTaiwanPayloadIsRejected() {
        let stale = NativeDestinationSyncPayload(lat: 24.1477, lng: 120.6736, updatedAt: 1_000_000)
        XCTAssertNil(stale.accepted(nowMS: 2_000_000, lastAppliedAt: 0))
        let outside = NativeDestinationSyncPayload(lat: 35.0, lng: 139.0, updatedAt: 1_990_000)
        XCTAssertNil(outside.accepted(nowMS: 2_000_000, lastAppliedAt: 0))
    }
}
