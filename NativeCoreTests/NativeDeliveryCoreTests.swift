import XCTest
@testable import DoorMap581

final class NativeDeliveryCoreTests: XCTestCase {
    private let a = DoorCoordinate(lat: 24.1350, lng: 120.6880)
    private let b = DoorCoordinate(lat: 24.1360, lng: 120.6890)
    private let c = DoorCoordinate(lat: 24.1370, lng: 120.6900)
    private let d = DoorCoordinate(lat: 24.1380, lng: 120.6910)

    func testAvoidAreaWrapMidnightEndpointExemptionAndBoundedSelection() {
        let nearStart = DoorAvoidArea(id: "start", lat: a.lat, lng: a.lng, radius: 80, start: "23:00", end: "02:00")
        let middle = DoorAvoidArea(id: "middle", lat: 24.1365, lng: 120.6895, radius: 60, start: "23:00", end: "02:00")
        XCTAssertTrue(DoorDeliveryCore.active(middle, minute: 30))
        XCTAssertFalse(DoorDeliveryCore.active(middle, minute: 12 * 60))
        let chosen = DoorDeliveryCore.choose([nearStart, middle], origin: a, destination: d, minute: 30)
        XCTAssertEqual(chosen.endpointExempt.map(\.id), ["start"])
        XCTAssertEqual(chosen.areas.map(\.id), ["middle"])
        XCTAssertEqual(DoorDeliveryCore.ring(middle).count, 17)
    }

    func testRouteEditorIsPlanBeforeCommitAndRejectsStaleResult() throws {
        let base = DoorPlannedRoute(coordinates: [a,b,c,d], distance: 500, duration: 120)
        var editor = DoorRouteEditor()
        _ = try editor.begin(.init(via: [], record: base))
        let version = try editor.change(.add(c))
        let stale = version &- 1
        XCTAssertFalse(try editor.accept(version: stale, route: base))
        let replanned = DoorPlannedRoute(coordinates: [a,b,c,d], distance: 520, duration: 125)
        XCTAssertTrue(try editor.accept(version: version, route: replanned))
        XCTAssertTrue(editor.ready)
        let finished = try editor.finish()
        XCTAssertEqual(finished.snapshot.via, [c])
        XCTAssertTrue(finished.changed)
    }

    func testExplicitRouteMemoryOnlyAndReasonableCandidateGate() throws {
        let before = DoorPlannedRoute(coordinates: [a,b,c,d], distance: 500, duration: 120)
        let detour = DoorCoordinate(lat: 24.1378, lng: 120.6891)
        let after = DoorPlannedRoute(coordinates: [a,b,detour,c,d], distance: 590, duration: 135)
        let memories = DoorPlannedMemory.differences(before: before, after: after, source: .edit, nowMS: 1000)
        let sanitized = try DoorPlannedMemory.sanitize(memories, nowMS: 2000)
        XCTAssertEqual(sanitized.count, memories.count)
        XCTAssertTrue(DoorPlannedMemory.reasonable(baseline: before, candidate: after))
        let absurd = DoorPlannedRoute(coordinates: [a,b,c,d], distance: 1000, duration: 500)
        XCTAssertFalse(DoorPlannedMemory.reasonable(baseline: before, candidate: absurd))
    }

    func testViaOrderingConstraintAndLoopInspectionStayFailClosed() {
        let route = [a,b,c,d]
        XCTAssertTrue(DoorDeliveryCore.constraints(route, via: [b,c]).ok)
        XCTAssertFalse(DoorDeliveryCore.constraints(route, via: [c,b]).ok)
        let bad = DoorAvoidArea(id: "x", lat: b.lat, lng: b.lng, radius: 100)
        XCTAssertFalse(DoorDeliveryCore.constraints(route, areas: [bad]).ok)
        XCTAssertFalse(DoorDeliveryCore.inspect(route).suspicious)
    }
}
