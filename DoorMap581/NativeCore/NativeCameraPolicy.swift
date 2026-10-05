import Foundation

public enum DoorCameraViewport {
    public struct Navigation: Codable, Equatable, Sendable {
        public let top: Double, bottom: Double, left: Double, right: Double, anchorY: Double, offsetY: Double
    }
    /// Explicit user PiP preset, not detection of another application's window.
    public static func pipBottom(width: Double, height: Double) -> Double {
        let height=height.isFinite ? max(0,height) : 0, width=width.isFinite ? max(0,width) : 0
        guard height > 0 else { return 0 }
        let top=min(height*0.08,64), portrait=width > 0 && width <= height ? max(0,width-20)*9/16 : 0
        return min(height,top+max(min(height*0.26,205),portrait)+12)
    }
    public static func navigation(width: Double, height: Double, pip: Bool, hudHeight: Double, collapsedInsetHeight: Double) -> Navigation? {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let top=pip ? max(min(height*0.34,260),pipBottom(width:width,height:height)) : min(hudHeight+22,height*0.23)
        let bottom=min(max(0,collapsedInsetHeight)+32,height*0.29), right=min(86,width*0.24), left=12.0
        let anchorY=max(top+45,min(height*(pip ? 0.74 : 0.68),height-bottom-24))
        let padded=(height+top-bottom)/2
        return .init(top:top,bottom:bottom,left:left,right:right,anchorY:anchorY,offsetY:anchorY-padded)
    }
    public static func fit(width: Double, height: Double, pip: Bool, controlRects: [DoorScreenRect], edge: Double = 12) -> DoorFitCamera.Viewport {
        var obstacles=controlRects
        if pip { obstacles.insert(.init(left:0,top:0,right:width,bottom:pipBottom(width:width,height:height)),at:0) }
        return .init(width:width,height:height,edge:edge,obstacles:obstacles)
    }
}

public enum DoorArrivalPolicy {
    public static let enter=500.0, exit=600.0, lock=200.0, unlock=250.0, maximumAutomaticZoom=17.0
    public static func active(distance: Double, wasActive: Bool) -> Bool { distance.isFinite && distance <= (wasActive ? exit : enter) }
    public static func locked(distance: Double, wasLocked: Bool) -> Bool { distance.isFinite && distance <= (wasLocked ? unlock : lock) }
    public static func padding(width: Double, height: Double, navigation: DoorCameraViewport.Navigation, pip: Bool) -> DoorCameraViewport.Navigation {
        let c=DoorCameraGeometry.clamp
        let top=floor(c(navigation.top+(pip ? 38 : 18),0,height*0.48)+0.5)
        let bottom=floor(c(navigation.bottom+18,0,height*0.34)+0.5)
        let left=floor(c(navigation.left+8,8,width*0.24)+0.5)
        let right=floor(c(navigation.right+8,8,width*0.28)+0.5)
        return .init(top:top,bottom:bottom,left:left,right:right,anchorY:height/2,offsetY:0)
    }
    public static func stable3DZoom(distance: Double) -> Double {
        if !distance.isFinite || distance >= 800 { return 16.8 }
        if distance <= 200 { return 18.15 }
        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a+(b-a)*t }
        if distance < 350 { return lerp(18.15,17.75,(distance-200)/150) }
        if distance < 550 { return lerp(17.75,17.20,(distance-350)/200) }
        return lerp(17.20,16.8,(distance-550)/250)
    }
    public static func turn2DZoom(distance: Double) -> Double? {
        if distance <= 30 { return 18.85 }; if distance <= 80 { return 18.35 }
        if distance <= 150 { return 17.75 }; if distance <= 250 { return 17.15 }; return nil
    }
    public static func nearDestination2DZoom(distance: Double) -> Double? {
        if distance <= 150 { return 19.1 }; if distance <= 300 { return 18.5 }
        if distance <= 600 { return 17.7 }; if distance <= 1200 { return 16.9 }; return nil
    }
    public static func manualZoom(_ zoom: Double, offset: Double) -> Double {
        DoorCameraGeometry.clamp(zoom+DoorCameraGeometry.clamp(offset,-3,3),12,20.5)
    }
    public static func manual3DPitch(zoom: Double) -> Double {
        if zoom < 16.9 || zoom >= 19.45 { return 0 }
        if zoom < 17.25 { return 38+(zoom-16.9)/(17.25-16.9)*10 }
        if zoom < 18.9 { return 48+min(8,(zoom-17.25)*5) }
        return max(28,56-(zoom-18.9)/0.55*28)
    }
}

public struct DoorHeadingFilter: Sendable {
    public struct Compass: Codable, Sendable {
        public let value: Double, timestampMS: Double, accuracy: Double
        public let source: String
        public init(value: Double, timestampMS: Double, accuracy: Double, source: String) { self.value=value; self.timestampMS=timestampMS; self.accuracy=accuracy; self.source=source }
    }
    public private(set) var displayHeading: Double?
    public private(set) var lastUpdateMS: Double = 0
    public private(set) var source: String?
    public init(initialHeading: Double? = nil, lastUpdateMS: Double = 0) {
        displayHeading=initialHeading?.isFinite == true ? DoorCameraGeometry.heading(initialHeading!) : nil
        self.lastUpdateMS=lastUpdateMS
    }
    @discardableResult public mutating func update(compass: Compass?, course: Double?, nowMS: Double, monotonicMS: Double? = nil) -> Double? {
        let clock=monotonicMS ?? nowMS
        guard nowMS.isFinite, clock.isFinite else { return displayHeading }
        let compassFresh=compass.map { c in
            c.value.isFinite && (0..<360).contains(c.value) && c.accuracy >= 0 && c.accuracy <= 60 && nowMS-c.timestampMS >= -2000 && nowMS-c.timestampMS < 2500
        } ?? false
        let heading=compassFresh ? compass?.value : (course?.isFinite == true && (0..<360).contains(course!) ? course : nil)
        guard let heading else { return displayHeading }
        source=compassFresh ? compass?.source : "gps-course"
        guard let old=displayHeading else { displayHeading=heading; lastUpdateMS=clock; return heading }
        let dt=DoorCameraGeometry.clamp(clock-lastUpdateMS,10,150), difference=DoorCameraGeometry.delta(heading,old)
        lastUpdateMS=clock
        guard abs(difference) >= 0.2 else { return old }
        let alpha=compassFresh ? 1-exp(-dt/65) : 0.38
        displayHeading=DoorCameraGeometry.heading(old+difference*alpha)
        return displayHeading
    }
    public func screenDirection(mapBearing: Double) -> Double? { displayHeading.map { DoorCameraGeometry.delta($0,mapBearing) } }
}

/// Deadzone/rate limits affect the programmatic camera, never the raw compass.
public struct DoorNavigationBearing: Sendable {
    public private(set) var value: Double?
    public private(set) var updatedAtMS: Double = 0
    public init(initialBearing: Double? = nil, updatedAtMS: Double = 0) {
        value=initialBearing?.isFinite == true ? DoorCameraGeometry.heading(initialBearing!) : nil
        self.updatedAtMS=updatedAtMS
    }
    public mutating func reset() { value=nil; updatedAtMS=0 }
    public mutating func update(target: Double, nowMS: Double, force: Bool = false) -> Double? {
        guard target.isFinite, nowMS.isFinite else { return value }
        guard let prior=value, !force else { value=DoorCameraGeometry.heading(target); updatedAtMS=nowMS; return value }
        let difference=DoorCameraGeometry.delta(target,prior)
        let rawElapsed=(nowMS-updatedAtMS)/1000
        let elapsed=DoorCameraGeometry.clamp(rawElapsed == 0 ? 0.18 : rawElapsed,0.05,1.5)
        updatedAtMS=nowMS
        if abs(difference) >= 3 {
            let step=max(2.5,58*elapsed)
            value=DoorCameraGeometry.heading(prior+DoorCameraGeometry.clamp(difference,-step,step))
        }
        return value
    }
}
