import CoreLocation
import MapKit
import XCTest
@testable import DoorMap581

final class NativeRidingTests: XCTestCase {
    @MainActor func testNativeSensorInputRejectsStaleDuplicateAndBackgroundWithoutStartingManager() {
        let sensor = NativeSensors(simulated: true), now = Date()
        var accepted: [NativeSensorFix] = []; sensor.onFix = { accepted.append($0) }
        func fix(_ time: Date, accuracy: Double = 5) -> CLLocation {
            CLLocation(coordinate: .init(latitude: 24.135, longitude: 120.688), altitude: 0,
                       horizontalAccuracy: accuracy, verticalAccuracy: 5, course: 45, courseAccuracy: 5,
                       speed: 6, speedAccuracy: 1, timestamp: time)
        }
        sensor.acceptLocations([fix(now.addingTimeInterval(-25))], now: now)
        sensor.acceptLocations([fix(now, accuracy: -1)], now: now)
        sensor.acceptLocations([fix(now.addingTimeInterval(4))], now: now)
        XCTAssertTrue(accepted.isEmpty)
        sensor.acceptLocations([fix(now)], now: now); sensor.acceptLocations([fix(now)], now: now)
        XCTAssertEqual(accepted.count, 1); XCTAssertEqual(accepted.first?.course, 45)
        XCTAssertFalse(accepted.first?.warm ?? true)
        sensor.setActive(false); sensor.acceptLocations([fix(now.addingTimeInterval(1))], now: now)
        XCTAssertEqual(accepted.count, 1)
        sensor.setActive(true); sensor.acceptLocations([fix(now.addingTimeInterval(1))], now: now)
        XCTAssertEqual(accepted.count, 2); XCTAssertFalse(sensor.isRunning)
        sensor.teardown()
    }
    @MainActor func testCompassUsesNativeTrueOrMagneticAndNeverInventsZeroHeading() {
        let sensor = NativeSensors(simulated: true), now = Date()
        var headings: [DoorHeadingFilter.Compass] = []; sensor.onHeading = { headings.append($0) }
        sensor.acceptHeading(trueHeading: -1, magnetic: -1, accuracy: 4, timestamp: now, now: now)
        sensor.acceptHeading(trueHeading: 90, magnetic: 88, accuracy: 100, timestamp: now, now: now)
        sensor.acceptHeading(trueHeading: 90, magnetic: 88, accuracy: 4, timestamp: now.addingTimeInterval(-3), now: now)
        XCTAssertTrue(headings.isEmpty)
        sensor.acceptHeading(trueHeading: 90, magnetic: 88, accuracy: 4, timestamp: now, now: now)
        sensor.acceptHeading(trueHeading: -1, magnetic: 88, accuracy: 4, timestamp: now, now: now)
        XCTAssertEqual(headings.map(\.value), [90, 88]); XCTAssertEqual(headings.map(\.source), ["true-heading", "magnetic-heading"])
        sensor.setActive(false); sensor.acceptHeading(trueHeading: 180, magnetic: 179, accuracy: 4, timestamp: now, now: now)
        XCTAssertEqual(headings.count, 2); sensor.teardown()
    }
    @MainActor func testWarmDisplayCannotEnableFITOrBecomeRawRouteOrigin() {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let camera = NativeRidingCamera(map: map)
        camera.accept(.init(coordinate: .init(lat: 24.135, lng: 120.688), accuracy: 10, speed: 0, course: nil, timestamp: Date(), warm: true))
        XCTAssertNil(camera.raw); XCTAssertNotNil(camera.displayPosition); XCTAssertFalse(camera.canFit)
        camera.setMode(.fit); XCTAssertEqual(camera.mode, .north)
        XCTAssertEqual(camera.cameraApplications, 0)
        let raw = NativeSensorFix(coordinate: .init(lat: 24.135, lng: 120.688), accuracy: 5, speed: 0, course: nil, timestamp: Date(), warm: false)
        camera.accept(raw); XCTAssertEqual(camera.raw?.coordinate, raw.coordinate)
        camera.setMode(.free); camera.setActive(false)
        XCTAssertEqual(camera.raw?.coordinate, raw.coordinate); XCTAssertFalse(camera.gestureHolding)
        camera.teardown()
    }
    func testManual3DPitchMatchesPinnedFitlock6AtAllUpperBandBoundaries() {
        let cases: [(Double, Double)] = [(16.8, 0), (16.9, 38), (17.25, 48), (18.9, 56),
            (19.0, 50.90909090909091), (19.2, 40.72727272727273), (19.44, 28.50909090909091), (19.45, 0)]
        for (zoom, expected) in cases { XCTAssertEqual(DoorArrivalPolicy.manual3DPitch(zoom: zoom), expected, accuracy: 1e-8, "z=\(zoom)") }
    }
    @MainActor func testNormalNavigationUsesPinnedStable3DAndArrivalLock() {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 402, height: 874)); map.layoutIfNeeded()
        let camera = NativeRidingCamera(map: map)
        let start = DoorCoordinate(lat: 24.135, lng: 120.688), destination = DoorCoordinate(lat: 24.135, lng: 120.698)
        let route = [start, .init(lat:24.135,lng:120.693), destination]
        camera.accept(.init(coordinate:start,accuracy:5,speed:7,course:180,timestamp:Date(),warm:false))
        camera.setRoute(route, destination: destination, maneuvers:[.init(type:"turn",modifier:"right",name:"測試路",routeIndex:1,location:route[1])])
        camera.setMode(.navigation)
        XCTAssertEqual(camera.mode,.navigation)
        XCTAssertEqual(map.camera.pitch,58,accuracy:0.75)
        XCTAssertEqual(NativeCameraAdapter.measuredZoom(map),16.8,accuracy:0.25)
        XCTAssertEqual(map.camera.heading,90,accuracy:5, "route bearing, not the 180° GPS course, owns the city")
        let near = DoorCoordinate(lat:24.135,lng:120.6975)
        camera.accept(.init(coordinate:near,accuracy:5,speed:4,course:180,timestamp:Date().addingTimeInterval(1),warm:false))
        XCTAssertEqual(map.camera.pitch,58,accuracy:0.75)
        XCTAssertEqual(NativeCameraAdapter.measuredZoom(map),18.15,accuracy:0.25)
        XCTAssertTrue(camera.diagnostics()["navigationArrivalLocked"] as? Bool == true)
        camera.toggleFit(); XCTAssertEqual(camera.mode,.fit)
        camera.toggleFit(); XCTAssertEqual(camera.mode,.navigation, "FIT overview must return to the active navigation owner")
        camera.teardown()
    }
}
