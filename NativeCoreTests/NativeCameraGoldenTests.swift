import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import DoorMapCore
#else
@testable import DoorMap581
#endif

/// Same fixed inputs executed by the immutable accepted JS oracle, then by
/// Swift. This does not certify MapKit projection or physical sensor timing.
final class NativeCameraGoldenTests: XCTestCase {
    struct Golden: Decodable {
        let schema: Int, sourceHashes: [String:String]
        let fitCases: [Fit], projectionCases: [Projection], leadTraces: [Lead]
        let viewportCases: [Viewport], arrivalCases: [Arrival], headingTraces: [Heading], bearingTraces: [Bearing], gestureTraces: [Gesture]
        struct Fit: Decodable {
            let name: String, path: [DoorCoordinate], origin: DoorCoordinate, destination: DoorCoordinate
            let viewport: DoorFitCamera.Viewport, options: DoorFitCamera.Options, expected: DoorFitCamera.Camera?
        }
        struct Projection: Decodable {
            let name: String, raw: DoorCoordinate, path: [DoorCoordinate], cursor: Int, meters: Double
            let expected: DoorCameraGeometry.Projection?, advanced: DoorCoordinate?
        }
        struct Lead: Decodable {
            let initial: Double, path: [DoorCoordinate], steps: [Step]
            struct Step: Decodable {
                let raw: DoorCoordinate, speed: Double, accuracy: Double, riding: Bool, cursor: Int
                let destination: DoorCoordinate?, maneuvers: [DoorRouteManeuver], expected: DoorCoordinate, leadMeters: Double
            }
        }
        struct Viewport: Decodable {
            let width: Double, height: Double, pip: Bool, hudHeight: Double, collapsedInsetHeight: Double, pipBottom: Double
            let expected: DoorCameraViewport.Navigation, arrival: Padding
            struct Padding: Decodable { let top: Double, bottom: Double, left: Double, right: Double }
        }
        struct Arrival: Decodable { let distance: Double, previous: Bool, active: Bool, locked: Bool, zoom: Double }
        struct Heading: Decodable {
            let initial: Double?, steps: [Step]
            struct Step: Decodable {
                let compass: DoorHeadingFilter.Compass?, course: Double?, nowMS: Double, monotonicMS: Double, expected: Double?
            }
        }
        struct Bearing: Decodable {
            let initial: Double?, steps: [Step]
            struct Step: Decodable { let target: Double, elapsed: Double, expected: Double }
        }
        struct Gesture: Decodable {
            let initial: DoorCameraInteraction.Selection, steps: [Step]
            struct Step: Decodable {
                let action: Action, nowMS: Double, foreground: Bool, selection: DoorCameraInteraction.Selection, expected: State
            }
            struct Action: Decodable {
                let op: String, id: Int?, x: Double?, y: Double?, remaining: Int?, cancelled: Bool?, foreground: Bool?, delta: Double?, manual: Bool?
            }
            struct State: Decodable {
                let holding: Bool, fitHolding: Bool, active: Bool, moved: Bool, pointerCount: Int, resumes: Int, stops: Int, resumeAtMS: Double?
            }
        }
    }
    private func golden() throws -> Golden {
        #if SWIFT_PACKAGE
        let url=Bundle.module.url(forResource:"camera-golden",withExtension:"json",subdirectory:"NativeCoreFixtures")
        #else
        let url=Bundle(for:Self.self).url(forResource:"camera-golden",withExtension:"json",subdirectory:"NativeCoreFixtures")
        #endif
        let bytes=try Data(contentsOf:XCTUnwrap(url))
        XCTAssertEqual(DoorDigest.sha256(bytes),"e20f6f71ba8ecd0a3d99c90d231d497deb32119cfdaf62c09d35451a48a87582")
        return try JSONDecoder().decode(Golden.self,from:bytes)
    }
    private func coordinate(_ a: DoorCoordinate, _ b: DoorCoordinate, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.lat,b.lat,accuracy:1e-8,name,file:file,line:line)
        XCTAssertEqual(a.lng,b.lng,accuracy:1e-8,name,file:file,line:line)
    }
    func testPinnedSourceIdentitiesAndCompleteNewFixtureCoverage() throws {
        let g=try golden()
        XCTAssertEqual(g.schema,1)
        XCTAssertEqual(g.sourceHashes["fit-camera.js"],DoorFitCamera.referenceSHA256)
        XCTAssertEqual(g.sourceHashes["door-map.js"],"23539b4a75598aee270478796528153b87274877ca635be9ac0cd68c1f762cf6")
        XCTAssertEqual(g.sourceHashes["camera-interaction.js"],"b3ca450ebb0f8da21f70427177395304e0458f52edc316978006ac5186d444af")
        XCTAssertEqual(g.fitCases.count,43); XCTAssertEqual(g.projectionCases.count,28)
        XCTAssertEqual(g.leadTraces.flatMap(\.steps).count,20); XCTAssertEqual(g.viewportCases.count,16)
        XCTAssertEqual(g.arrivalCases.count,48); XCTAssertEqual(g.headingTraces.flatMap(\.steps).count,24)
        XCTAssertEqual(g.bearingTraces.flatMap(\.steps).count,21); XCTAssertEqual(g.gestureTraces.flatMap(\.steps).count,44)
    }
    func testMercatorFITMatchesAcceptedFullRouteAnchorObstacleAndContinuityCases() throws {
        for c in try golden().fitCases {
            let actual=DoorFitCamera.solve(c.path,origin:c.origin,destination:c.destination,viewport:c.viewport,options:c.options)
            guard let expected=c.expected else { XCTAssertNil(actual,c.name); continue }
            let a=try XCTUnwrap(actual,c.name)
            coordinate(a.center,expected.center,c.name)
            XCTAssertEqual(a.zoom,expected.zoom,accuracy:2e-6,c.name)
            XCTAssertEqual(DoorCameraGeometry.delta(a.bearing,expected.bearing),0,accuracy:1e-7,c.name)
            XCTAssertEqual(a.pitch,0,c.name)
            XCTAssertEqual(a.start.x,expected.start.x,accuracy:0.05,c.name); XCTAssertEqual(a.start.y,expected.start.y,accuracy:0.05,c.name)
            XCTAssertEqual(a.end.x,expected.end.x,accuracy:0.05,c.name); XCTAssertEqual(a.end.y,expected.end.y,accuracy:0.05,c.name)
            XCTAssertEqual(a.riderAnchor,expected.riderAnchor,c.name); XCTAssertEqual(a.targetAbove,expected.targetAbove,c.name)
            XCTAssertEqual(a.stabilityHeld,expected.stabilityHeld,c.name)
            XCTAssertEqual(a.stats.inputPoints,expected.stats.inputPoints,c.name)
            XCTAssertEqual(a.stats.fullSearch,expected.stats.fullSearch,c.name)
            XCTAssertEqual(a.stats.collisionPoints,expected.stats.collisionPoints,c.name)
            XCTAssertTrue(DoorFitCamera.contains(a,coords:c.path,origin:c.origin,destination:c.destination,viewport:c.viewport),c.name)
        }
    }
    func testProjectionAndRouteAdvanceMatchAcceptedRawGeometry() throws {
        for c in try golden().projectionCases {
            let actual=DoorCameraGeometry.progressProjection(c.raw,path:c.path,cursor:c.cursor)
            guard let expected=c.expected else { XCTAssertNil(actual,c.name); continue }
            let a=try XCTUnwrap(actual,c.name)
            XCTAssertEqual(a.index,expected.index,c.name); XCTAssertEqual(a.t,expected.t,accuracy:1e-10,c.name)
            XCTAssertEqual(a.distance,expected.distance,accuracy:1e-6,c.name); coordinate(a.coordinate,expected.coordinate,c.name)
            if let expected=c.advanced { coordinate(try XCTUnwrap(DoorCameraGeometry.advance(a,path:c.path,meters:c.meters)),expected,c.name) }
        }
    }
    func testRawGPSPreservedDisplayLeadMatchesTurnDestinationAndPoorFixCaps() throws {
        for trace in try golden().leadTraces {
            var model=DoorDisplayLeadModel(initialLeadMeters:trace.initial)
            for (i,s) in trace.steps.enumerated() {
                let raw=s.raw
                let value=model.update(raw:raw,accuracy:s.accuracy,speed:s.speed,riding:s.riding,path:trace.path,cursor:s.cursor,destination:s.destination,maneuvers:s.maneuvers)
                coordinate(value,s.expected,"lead \(trace.initial) step\(i)")
                XCTAssertEqual(model.leadMeters,s.leadMeters,accuracy:1e-8)
                XCTAssertEqual(raw,s.raw); XCTAssertGreaterThanOrEqual(model.leadMeters,0); XCTAssertLessThanOrEqual(model.leadMeters,10)
            }
        }
    }
    func testPiPAndCollapsedInsetViewportMatchesActualAcceptedController() throws {
        for c in try golden().viewportCases {
            let a=try XCTUnwrap(DoorCameraViewport.navigation(width:c.width,height:c.height,pip:c.pip,hudHeight:c.hudHeight,collapsedInsetHeight:c.collapsedInsetHeight))
            XCTAssertEqual(a,c.expected)
            if c.pip { XCTAssertEqual(DoorCameraViewport.pipBottom(width:c.width,height:c.height),c.pipBottom,accuracy:1e-8) }
            let padding=DoorArrivalPolicy.padding(width:c.width,height:c.height,navigation:a,pip:c.pip)
            XCTAssertEqual(padding.top,c.arrival.top); XCTAssertEqual(padding.bottom,c.arrival.bottom)
            XCTAssertEqual(padding.left,c.arrival.left); XCTAssertEqual(padding.right,c.arrival.right)
        }
    }
    func testArrivalZoomAndLockHysteresisMatchEveryBoundary() throws {
        for c in try golden().arrivalCases {
            XCTAssertEqual(DoorArrivalPolicy.active(distance:c.distance,wasActive:c.previous),c.active)
            XCTAssertEqual(DoorArrivalPolicy.locked(distance:c.distance,wasLocked:c.previous),c.locked)
            XCTAssertEqual(DoorArrivalPolicy.stable3DZoom(distance:c.distance),c.zoom,accuracy:1e-10)
        }
    }
    func testHeadingUsesFreshCompassThenCourseAndShortestAngularPath() throws {
        for trace in try golden().headingTraces {
            var model=DoorHeadingFilter(initialHeading:trace.initial)
            for s in trace.steps {
                let actual=model.update(compass:s.compass,course:s.course,nowMS:s.nowMS,monotonicMS:s.monotonicMS)
                if let expected=s.expected { XCTAssertEqual(try XCTUnwrap(actual),expected,accuracy:1e-8) } else { XCTAssertNil(actual) }
            }
        }
    }
    func testStable3DBearingDeadzoneAndRateFollowActualAcceptedRule() throws {
        for trace in try golden().bearingTraces {
            var model=DoorNavigationBearing(initialBearing:trace.initial), now=0.0
            for s in trace.steps {
                now += s.elapsed*1000
                XCTAssertEqual(try XCTUnwrap(model.update(target:s.target,nowMS:now)),s.expected,accuracy:1e-8)
            }
        }
    }
    func testMultiTouchTapDelayedResumeBackgroundAndManualChoiceMatchOriginalController() throws {
        for trace in try golden().gestureTraces {
            var model=DoorCameraInteraction(), stops=0
            model.selectionChanged(trace.initial)
            for (i,s) in trace.steps.enumerated() {
                let a=s.action; var effect=DoorCameraInteraction.Effect()
                switch a.op {
                case "begin": effect=model.begin(id:try XCTUnwrap(a.id),at:.init(x:try XCTUnwrap(a.x),y:try XCTUnwrap(a.y)),selection:s.selection,foreground:s.foreground)
                case "move": model.move(to:.init(x:try XCTUnwrap(a.x),y:try XCTUnwrap(a.y)))
                case "transform": effect=model.transformBegan(isUserGesture:true,selection:s.selection,foreground:s.foreground)
                case "end": effect=model.end(id:try XCTUnwrap(a.id),cancelled:a.cancelled ?? false,remainingTouches:a.remaining ?? 0,nowMS:s.nowMS,selection:s.selection,foreground:s.foreground)
                case "advance": effect=model.advance(nowMS:s.nowMS,selection:s.selection,foreground:s.foreground)
                case "lifecycle": effect=model.lifecycle(foreground:s.foreground,selection:s.selection)
                case "wheel": effect=model.keyboardOrWheel(nowMS:s.nowMS,selection:s.selection,foreground:s.foreground)
                case "selection": model.selectionChanged(s.selection)
                default: XCTFail("Unknown oracle operation \(a.op)")
                }
                if effect.stopProgrammaticCamera { stops += 1 }
                let e=s.expected, label="gesture\(trace.initial.fitLocked) step\(i) \(a.op)"
                XCTAssertEqual(model.holding,e.holding,label); XCTAssertEqual(model.fitHolding,e.fitHolding,label)
                XCTAssertEqual(model.active,e.active,label); XCTAssertEqual(model.moved,e.moved,label)
                XCTAssertEqual(model.pointerCount,e.pointerCount,label); XCTAssertEqual(model.resumes,e.resumes,label)
                XCTAssertEqual(stops,e.stops,label); XCTAssertEqual(model.resumeAtMS,e.resumeAtMS,label)
            }
        }
    }
    func testUnknownHeadingAndCameraPreferenceDoNotInventGPSOrShareCoordinates() throws {
        var h=DoorHeadingFilter()
        XCTAssertNil(h.update(compass:nil,course:nil,nowMS:10)); XCTAssertNil(h.screenDirection(mapBearing:60))
        let bad=DoorHeadingFilter.Compass(value:25,timestampMS:10,accuracy:90,source:"bad")
        XCTAssertNil(h.update(compass:bad,course:nil,nowMS:20))
        let selection=DoorCameraInteraction.Selection(fitLocked:true,navigationRequested:true)
        let bytes=try JSONEncoder().encode(DoorCameraInteraction.Preference(selection:selection))
        XCTAssertEqual(DoorCameraInteraction.Preference.decode(bytes)?.owner,.fit)
        let text=String(decoding:bytes,as:UTF8.self)
        XCTAssertFalse(text.contains("lat")); XCTAssertFalse(text.contains("lng")); XCTAssertFalse(text.contains("coordinate"))
        for text in ["null","{}","{\"v\":1,\"owner\":\"unknown\"}"] { XCTAssertNil(DoorCameraInteraction.Preference.decode(Data(text.utf8))) }
    }
    func testInvalidViewportAndFullObstructionFailWithoutInventingCamera() {
        let origin=DoorCoordinate(lat:24.13,lng:120.68), destination=DoorCoordinate(lat:24.15,lng:120.69)
        XCTAssertNil(DoorFitCamera.solve([origin,destination],origin:origin,destination:destination,viewport:.init(width:0,height:844)))
        let blocked=DoorFitCamera.Viewport(width:390,height:844,obstacles:[.init(left:0,top:0,right:390,bottom:844)])
        XCTAssertNil(DoorFitCamera.solve([origin,destination],origin:origin,destination:destination,viewport:blocked))
        XCTAssertNil(DoorCameraViewport.navigation(width:.nan,height:844,pip:true,hudHeight:50,collapsedInsetHeight:56))
        XCTAssertEqual(DoorCameraViewport.pipBottom(width:390,height:0),0)
        XCTAssertFalse(DoorArrivalPolicy.active(distance:.nan,wasActive:true))
    }
    func testCompleteRouteCertificationRejectsAnExtraHiddenInteriorBend() throws {
        let origin=DoorCoordinate(lat:24.13,lng:120.68), destination=DoorCoordinate(lat:24.14,lng:120.68)
        let viewport=DoorFitCamera.Viewport(width:390,height:844)
        let camera=try XCTUnwrap(DoorFitCamera.solve([origin,destination],origin:origin,destination:destination,viewport:viewport))
        let far=DoorCoordinate(lat:24.135,lng:121)
        XCTAssertFalse(DoorFitCamera.contains(camera,coords:[origin,far,destination],origin:origin,destination:destination,viewport:viewport))
    }
}
