import Foundation

public struct DoorScreenPoint: Codable, Equatable, Sendable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x=x; self.y=y }
}
public struct DoorScreenRect: Codable, Equatable, Sendable {
    public var left: Double, top: Double, right: Double, bottom: Double
    public init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left=left; self.top=top; self.right=right; self.bottom=bottom
    }
    public var width: Double { right-left }
    public var height: Double { bottom-top }
    public var isFinite: Bool { [left,top,right,bottom].allSatisfy(\.isFinite) }
    public func overlaps(_ other: Self) -> Bool {
        left < other.right && right > other.left && top < other.bottom && bottom > other.top
    }
    public func contains(_ other: Self, tolerance: Double = 0) -> Bool {
        other.left >= left-tolerance && other.right <= right+tolerance && other.top >= top-tolerance && other.bottom <= bottom+tolerance
    }
    public func expanded(_ meters: Double) -> Self {
        .init(left:left-meters,top:top-meters,right:right+meters,bottom:bottom+meters)
    }
}

/// Exact accepted geodesic/projection rules. This type never modifies sensor fixes.
public enum DoorCameraGeometry {
    public static let radians = Double.pi/180
    public static func clamp(_ x: Double, _ a: Double, _ b: Double) -> Double { max(a,min(b,x)) }
    public static func heading(_ value: Double) -> Double { (value.truncatingRemainder(dividingBy:360)+360).truncatingRemainder(dividingBy:360) }
    public static func signed(_ value: Double) -> Double { heading(value+180)-180 }
    public static func delta(_ a: Double, _ b: Double) -> Double { signed(a-b) }
    public static func haversine(_ a: DoorCoordinate, _ b: DoorCoordinate) -> Double {
        let dLat=(b.lat-a.lat)*radians, dLng=(b.lng-a.lng)*radians
        let s=pow(sin(dLat/2),2)+cos(a.lat*radians)*cos(b.lat*radians)*pow(sin(dLng/2),2)
        return 2*6_371_000*asin(min(1,sqrt(s)))
    }
    public static func bearing(_ a: DoorCoordinate, _ b: DoorCoordinate) -> Double {
        let p1=a.lat*radians, p2=b.lat*radians, dl=(b.lng-a.lng)*radians
        return heading(atan2(sin(dl)*cos(p2),cos(p1)*sin(p2)-sin(p1)*cos(p2)*cos(dl))/radians)
    }
    public struct Projection: Codable, Equatable, Sendable {
        public let t: Double, distance: Double
        public let index: Int
        public let coordinate: DoorCoordinate
    }
    public static func project(_ point: DoorCoordinate, segment a: DoorCoordinate, end b: DoorCoordinate, index: Int = 0) -> Projection {
        let sx=111_320*max(0.15,cos(point.lat*radians)), sy=111_320.0
        let px=point.lng*sx, py=point.lat*sy, ax=a.lng*sx, ay=a.lat*sy, bx=b.lng*sx, by=b.lat*sy
        let vx=bx-ax, vy=by-ay, wx=px-ax, wy=py-ay, vv=vx*vx+vy*vy
        let t=vv > 0 ? clamp((wx*vx+wy*vy)/vv,0,1) : 0
        return .init(t:t,distance:hypot(px-(ax+t*vx),py-(ay+t*vy)),index:index,
                     coordinate:.init(lat:a.lat+t*(b.lat-a.lat),lng:a.lng+t*(b.lng-a.lng)))
    }
    public static func progressProjection(_ point: DoorCoordinate, path: [DoorCoordinate], cursor: Int) -> Projection? {
        guard point.isValid, path.count >= 2 else { return nil }
        let cursor=max(0,min(path.count-2,cursor)), first=max(0,cursor-3), last=min(path.count-2,cursor+120)
        var best: Projection?
        func scan(_ first: Int, _ last: Int) {
            guard first <= last else { return }
            for i in first...last {
                let value=project(point,segment:path[i],end:path[i+1],index:i)
                if best == nil || value.distance < best!.distance { best=value }
            }
        }
        scan(first,last)
        if let best, best.distance <= 65 { return best }
        if last < path.count-2 { scan(last+1,path.count-2) }
        return best
    }
    public static func advance(_ projection: Projection, path: [DoorCoordinate], meters: Double) -> DoorCoordinate? {
        guard path.count >= 2, meters.isFinite, meters > 0 else { return nil }
        var index=max(0,min(path.count-2,projection.index)), current=projection.coordinate, remaining=meters
        while remaining > 0 && index < path.count-1 {
            let end=path[index+1], length=haversine(current,end)
            if !length.isFinite || length < 0.05 { current=end; index += 1; continue }
            if remaining < length {
                let t=remaining/length
                return .init(lat:current.lat+(end.lat-current.lat)*t,lng:current.lng+(end.lng-current.lng)*t)
            }
            remaining -= length; current=end; index += 1
        }
        return current
    }
}

public struct DoorRouteManeuver: Codable, Equatable, Sendable {
    public let type: String, modifier: String, name: String
    public let routeIndex: Int
    public let location: DoorCoordinate?
    public init(type: String, modifier: String = "", name: String = "", routeIndex: Int = 0, location: DoorCoordinate? = nil) {
        self.type=type; self.modifier=modifier; self.name=name; self.routeIndex=routeIndex; self.location=location
    }
}

/// Display-only, route-bounded 0–10m lead from fitlock6. Raw GPS remains the
/// routing/deviation input; turns, destination and poor fixes cap prediction.
public struct DoorDisplayLeadModel: Sendable {
    public private(set) var leadMeters: Double = 0
    public init(initialLeadMeters: Double = 0) { leadMeters=initialLeadMeters.isFinite ? max(0,min(10,initialLeadMeters)) : 0 }
    public mutating func reset() { leadMeters=0 }
    public mutating func update(raw: DoorCoordinate, accuracy: Double, speed: Double,
                                riding: Bool, path: [DoorCoordinate], cursor: Int,
                                destination: DoorCoordinate?, maneuvers: [DoorRouteManeuver]) -> DoorCoordinate {
        guard riding, path.count >= 2 else { leadMeters=0; return raw }
        let accuracy=accuracy.isFinite ? max(0,accuracy) : 0
        let maxSnap=max(18,min(45,accuracy > 0 ? accuracy*1.5 : 18))
        guard let p=DoorCameraGeometry.progressProjection(raw,path:path,cursor:cursor), p.distance <= maxSnap else {
            leadMeters=0; return raw
        }
        let speed=speed.isFinite ? max(0,speed) : 0
        var wanted=speed >= 1.2 ? min(10,1.5+speed*0.65) : 0
        if accuracy > 30 { wanted *= 0.5 }
        if accuracy > 50 { wanted=0 }
        var lead=speed >= 1.2 ? leadMeters*0.30+wanted*0.70 : leadMeters*0.82
        if accuracy > 50 { lead=0 }
        if let turn=maneuvers.first(where: { $0.type != "depart" && $0.type != "arrive" && $0.routeIndex >= max(0,cursor)-2 }), let location=turn.location {
            let meters=DoorCameraGeometry.haversine(raw,location)
            if meters.isFinite && meters < 80 { lead=min(lead,max(0,meters-1.5)) }
        }
        if let destination {
            let meters=DoorCameraGeometry.haversine(raw,destination)
            if meters.isFinite { lead=min(lead,max(0,meters-1.5)) }
        }
        leadMeters=max(0,min(10,lead))
        guard leadMeters >= 0.35 else { return raw }
        return DoorCameraGeometry.advance(p,path:path,meters:leadMeters) ?? raw
    }
}

/// Monotonic segment cursor and actual remaining line, not a synthetic straight
/// route or the earlier build6 simplified cursor. Arrival uses the accepted 12m boundary.
public struct DoorRouteCursor: Sendable {
    public private(set) var index: Int = 0
    public private(set) var remaining: [DoorCoordinate] = []
    public private(set) var arrived = false
    public init() {}
    public mutating func reset(path: [DoorCoordinate]) { index=0; remaining=path; arrived=false }
    public mutating func update(raw: DoorCoordinate, path: [DoorCoordinate], destination: DoorCoordinate?, navigating: Bool, editing: Bool = false) {
        guard path.count >= 2 else { remaining=[]; return }
        if editing || !navigating { remaining=path; return }
        guard let p=DoorCameraGeometry.progressProjection(raw,path:path,cursor:index), p.distance <= 140 else { return }
        index=max(index,p.index)
        var start=p.coordinate
        if p.index < index {
            let a=path[min(index,path.count-1)], b=path[min(index+1,path.count-1)]
            let q=DoorCameraGeometry.project(raw,segment:a,end:b,index:index)
            if q.distance <= 140 { start=q.coordinate }
        }
        if let destination, DoorCameraGeometry.haversine(raw,destination) <= 12 {
            remaining=[]; arrived=true; return
        }
        remaining=[start]+Array(path.dropFirst(index+1)); arrived=false
    }
}
