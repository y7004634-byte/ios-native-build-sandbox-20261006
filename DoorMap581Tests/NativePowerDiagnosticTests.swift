import XCTest
@testable import DoorMap581

final class NativePowerDiagnosticTests: XCTestCase {
    func testWorkloadCountsOnlyExplicitEventsAndForegroundTime() {
        var workload = NativePowerWorkload()
        workload.start(at: 1_000, durationMS: 300_000, foreground: true)
        workload.mark(.gps, 3); workload.mark(.heading, 4); workload.mark(.routeRequest)
        workload.setForeground(false, at: 61_000)
        workload.mark(.mapMove, 10)
        workload.setForeground(true, at: 121_000)
        workload.mark(.layerRefresh, 2)
        let snapshot = workload.snapshot(at: 181_000)
        XCTAssertTrue(snapshot.running)
        XCTAssertEqual(snapshot.durationMS, 180_000, accuracy: 0.001)
        XCTAssertEqual(snapshot.foregroundMS, 120_000, accuracy: 0.001)
        XCTAssertEqual(snapshot.count(.gps), 3)
        XCTAssertEqual(snapshot.count(.heading), 4)
        XCTAssertEqual(snapshot.count(.routeRequest), 1)
        XCTAssertEqual(snapshot.count(.mapMove), 10)
        XCTAssertEqual(snapshot.count(.layerRefresh), 2)
        XCTAssertFalse(snapshot.reportText.contains("24.135"))
        XCTAssertTrue(snapshot.reportText.contains("不含 GPS 座標"))
        XCTAssertTrue(snapshot.reportText.contains("瓦數"))
    }

    func testDurationIsBoundedAndStopFreezesReport() {
        var workload = NativePowerWorkload()
        workload.start(at: 0, durationMS: 1, foreground: true)
        XCTAssertFalse(workload.shouldFinish(at: 59_999))
        XCTAssertTrue(workload.shouldFinish(at: 60_000))
        workload.mark(.cameraApply, 2)
        let stopped = workload.stop(at: 60_000, reason: "complete")
        XCTAssertFalse(stopped.running)
        XCTAssertEqual(stopped.remainingMS, 0)
        XCTAssertEqual(stopped.count(.cameraApply), 2)
        workload.mark(.cameraApply, 10)
        XCTAssertEqual(workload.snapshot(at: 120_000).count(.cameraApply), 2)
    }
}
