import CoreLocation
import XCTest
@testable import DoorMap581

final class SensorSamplePolicyTests:XCTestCase {
    private let now=Date(timeIntervalSince1970:1_800_000_000)
    func testTrueHeadingPreferredAndMagneticFallback() {
        XCTAssertEqual(SensorSamplePolicy.heading(trueHeading:359,magnetic:12,accuracy:3,timestamp:now,now:now)?.value,359)
        XCTAssertEqual(SensorSamplePolicy.heading(trueHeading:-1,magnetic:1,accuracy:3,timestamp:now,now:now)?.source,"magnetic-heading")
    }
    func testInvalidAndStaleHeadingsNeverInventNorth() {
        for values in [(Double.nan,Double.nan,3.0),(360.0,-1.0,3.0),(0.0,0.0,-1.0),(0.0,0.0,61.0)] {
            XCTAssertNil(SensorSamplePolicy.heading(trueHeading:values.0,magnetic:values.1,accuracy:values.2,timestamp:now,now:now))
        }
        XCTAssertNil(SensorSamplePolicy.heading(trueHeading:1,magnetic:0,accuracy:3,timestamp:now.addingTimeInterval(-2.5),now:now))
    }
    func testWarmDisplayIsBoundedSeparatelyFromFreshLiveFix() {
        func fix(_ age:Double,_ accuracy:Double)->CLLocation{CLLocation(coordinate:.init(latitude:24.14,longitude:120.67),altitude:0,horizontalAccuracy:accuracy,verticalAccuracy:5,timestamp:now.addingTimeInterval(-age))}
        XCTAssertTrue(SensorSamplePolicy.usableLocation(fix(14,80),now:now,warm:true))
        XCTAssertFalse(SensorSamplePolicy.usableLocation(fix(16,5),now:now,warm:true))
        XCTAssertFalse(SensorSamplePolicy.usableLocation(fix(1,81),now:now,warm:true))
        XCTAssertFalse(SensorSamplePolicy.usableLocation(fix(1,-1),now:now))
        XCTAssertFalse(SensorSamplePolicy.usableLocation(fix(21,5),now:now))
    }
    func testCourseRequiresMovementAndAccuracy() {
        func fix(_ speed:Double,_ accuracy:Double,_ course:Double)->CLLocation{CLLocation(coordinate:.init(latitude:24.14,longitude:120.67),altitude:0,horizontalAccuracy:accuracy,verticalAccuracy:5,course:course,courseAccuracy:3,speed:speed,speedAccuracy:1,timestamp:now)}
        XCTAssertEqual(SensorSamplePolicy.course(fix(8,5,359)),359)
        for value in [fix(0,5,0),fix(1,5,180),fix(8,66,180),fix(8,-1,180),fix(8,5,-1)]{XCTAssertNil(SensorSamplePolicy.course(value))}
    }
}
