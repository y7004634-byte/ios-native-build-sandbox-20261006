import XCTest
#if SWIFT_PACKAGE
@testable import DoorMapCore
#else
@testable import DoorMap581
#endif

final class NativeReroutePolicyTests: XCTestCase {
    private let eastRoute = [
        DoorCoordinate(lat: 24.0, lng: 120.0),
        DoorCoordinate(lat: 24.0, lng: 120.002)
    ]

    func testSoftDeviationRequiresTwoConsecutiveFixes() {
        var policy = DoorReroutePolicy()
        let off = DoorCoordinate(lat: 24.00036, lng: 120.001)
        XCTAssertNil(policy.evaluate(position: off, accuracy: 5, heading: nil, speed: 5, route: eastRoute, nowMS: 1000))
        let decision = policy.evaluate(position: off, accuracy: 5, heading: nil, speed: 5, route: eastRoute, nowMS: 2000)
        XCTAssertEqual(decision?.reason, .repeatedDeviation)
        XCTAssertTrue(decision?.force == true)
    }

    func testHardDeviationTriggersImmediatelyAndAccuracyRaisesThreshold() {
        var policy = DoorReroutePolicy()
        let off = DoorCoordinate(lat: 24.00063, lng: 120.001)
        XCTAssertEqual(policy.evaluate(position: off, accuracy: 5, heading: nil, speed: 5, route: eastRoute, nowMS: 1000)?.reason, .hardDeviation)

        var poor = DoorReroutePolicy()
        XCTAssertNil(poor.evaluate(position: off, accuracy: 50, heading: nil, speed: 5, route: eastRoute, nowMS: 1000),
                     "accuracy 50m raises hard threshold to100m and soft to67.5m")
    }

    func testHeadingMismatchRequiresTwoFixesAtLeast15mOffRoute() {
        var policy = DoorReroutePolicy()
        let off = DoorCoordinate(lat: 24.00018, lng: 120.001)
        XCTAssertNil(policy.evaluate(position: off, accuracy: 5, heading: 270, speed: 5, route: eastRoute, nowMS: 1000))
        XCTAssertEqual(policy.evaluate(position: off, accuracy: 5, heading: 270, speed: 5, route: eastRoute, nowMS: 2000)?.reason, .headingMismatch)
    }

    func testMissedRealTurnBypassesNormalCooldown() {
        let route = [
            DoorCoordinate(lat: 24.0, lng: 120.0),
            DoorCoordinate(lat: 24.0, lng: 120.0006),
            DoorCoordinate(lat: 24.0006, lng: 120.0006)
        ]
        let preview = DoorReroutePolicy.preview(position: route[0], accuracy: 5, speed: 5, route: route)
        XCTAssertTrue(preview.onRoute)
        XCTAssertLessThanOrEqual(preview.turnMeters, 65)
        XCTAssertNotNil(preview.turnCoordinate)
        XCTAssertNotNil(preview.turnBearingAfter)

        var policy = DoorReroutePolicy()
        policy.requested(at: 0, reason: .missingRoute)
        XCTAssertNil(policy.evaluate(position: route[0], accuracy: 5, heading: 90, speed: 5, route: route, nowMS: 1000))
        let straightPastTurn = DoorCoordinate(lat: 24.0, lng: 120.0010)
        let decision = policy.evaluate(position: straightPastTurn, accuracy: 5, heading: 90, speed: 5, route: route, nowMS: 2000)
        XCTAssertEqual(decision?.reason, .missedTurn)
        XCTAssertTrue(decision?.force == true)
    }

    func testMissingRouteUsesSevenSecondOrdinaryRequestInterval() {
        var policy = DoorReroutePolicy()
        let p = DoorCoordinate(lat: 24.135, lng: 120.688)
        XCTAssertEqual(policy.evaluate(position: p, accuracy: 5, heading: 0, speed: 0, route: [], nowMS: 100)?.reason, .missingRoute)
        policy.requested(at: 100, reason: .missingRoute)
        XCTAssertNil(policy.evaluate(position: p, accuracy: 5, heading: 0, speed: 0, route: [], nowMS: 7099))
        XCTAssertEqual(policy.evaluate(position: p, accuracy: 5, heading: 0, speed: 0, route: [], nowMS: 7100)?.reason, .missingRoute)
    }
}
