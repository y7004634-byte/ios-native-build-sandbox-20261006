import Foundation

/// Typed translation of the pinned fitlock6 Mercator solver. JS is only the
/// development-time oracle: no WebKit, JS runtime, sensor, timer, or network.
public enum DoorFitCamera {
    public static let referenceSHA256="6abd9b6f54b00a8c5ac6006742cdafb63a58fce996635a90afc1f8a728577d79"
    public struct Viewport: Codable, Sendable {
        public var width: Double, height: Double, edge: Double
        public var obstacles: [DoorScreenRect]
        public init(width: Double, height: Double, edge: Double = 12, obstacles: [DoorScreenRect] = []) {
            self.width=width; self.height=height; self.edge=edge; self.obstacles=obstacles
        }
    }
    public struct Options: Codable, Sendable {
        public var maxZoom: Double = 20
        public var previousBearing: Double?
        public var full=true, continuous=false, riderAnchor=false, targetAbove=false
        public var anchorBounds: DoorScreenRect?
        public init(maxZoom: Double = 20, previousBearing: Double? = nil, full: Bool = true,
                    continuous: Bool = false, riderAnchor: Bool = false, targetAbove: Bool = false, anchorBounds: DoorScreenRect? = nil) {
            self.maxZoom=maxZoom; self.previousBearing=previousBearing; self.full=full; self.continuous=continuous
            self.riderAnchor=riderAnchor; self.targetAbove=targetAbove; self.anchorBounds=anchorBounds
        }
    }
    public struct Stats: Codable, Equatable, Sendable {
        public var angleEvaluations=0, collisionChecks=0, inputPoints=0, collisionPoints=0
        public var fullSearch=true
    }
    public struct Camera: Codable, Equatable, Sendable {
        public var center: DoorCoordinate
        public var zoom: Double, bearing: Double
        public var pitch: Double = 0
        public var start: DoorScreenPoint, end: DoorScreenPoint
        public var preference: Double, scale: Double
        public var riderAnchor=false, targetAbove=false, stabilityHeld=false
        public var stats=Stats()
    }
    private struct NormalViewport { let width: Double, height: Double, safe: DoorScreenRect, obstacles: [DoorScreenRect] }
    private struct Prepared { let ref: DoorScreenPoint, points: [DoorScreenPoint], start: DoorScreenPoint, end: DoorScreenPoint, hull: [DoorScreenPoint], pointCount: Int }
    private struct Placement { let x: Double, y: Double, scale: Double, preference: Double, start: DoorScreenPoint, end: DoorScreenPoint }
    private struct Candidate { var camera: Camera; let ordinal: Int }
    private static let rad=Double.pi/180
    private static func clamp(_ x: Double, _ a: Double, _ b: Double) -> Double { max(a,min(b,x)) }
    private static func valid(_ p: DoorCoordinate) -> Bool { p.lat.isFinite && p.lng.isFinite && abs(p.lat) <= 90 }
    public static func mercator(_ p: DoorCoordinate) -> DoorScreenPoint {
        let latitude=clamp(p.lat,-85.05112878,85.05112878)*rad
        return .init(x:(p.lng+180)/360,y:(1-log(tan(Double.pi/4+latitude/2))/Double.pi)/2)
    }
    public static func coordinate(_ p: DoorScreenPoint) -> DoorCoordinate {
        .init(lat:atan(sinh(.pi*(1-2*p.y)))/rad,lng:p.x*360-180)
    }
    private static func rotate(_ p: DoorScreenPoint, _ c: Double, _ s: Double) -> DoorScreenPoint { .init(x:c*p.x+s*p.y,y:-s*p.x+c*p.y) }
    private static func extents(_ points: [DoorScreenPoint]) -> DoorScreenRect {
        var x0=Double.infinity,y0=Double.infinity,x1 = -Double.infinity,y1 = -Double.infinity
        for p in points { x0=min(x0,p.x); x1=max(x1,p.x); y0=min(y0,p.y); y1=max(y1,p.y) }
        return .init(left:x0,top:y0,right:x1,bottom:y1)
    }
    private static func hull(_ points: [DoorScreenPoint]) -> [DoorScreenPoint] {
        let sorted=points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ a: DoorScreenPoint, _ b: DoorScreenPoint, _ c: DoorScreenPoint) -> Double { (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x) }
        var low:[DoorScreenPoint]=[], high:[DoorScreenPoint]=[]
        for p in sorted { while low.count > 1 && cross(low[low.count-2],low[low.count-1],p) <= 0 { low.removeLast() }; low.append(p) }
        for p in sorted.reversed() { while high.count > 1 && cross(high[high.count-2],high[high.count-1],p) <= 0 { high.removeLast() }; high.append(p) }
        if !low.isEmpty { low.removeLast() }; if !high.isEmpty { high.removeLast() }
        let result=low+high
        return result.isEmpty ? Array(sorted.prefix(1)) : result
    }
    private static func simplify(_ points: [DoorScreenPoint], epsilon: Double) -> [DoorScreenPoint] {
        guard points.count >= 3 else { return points }
        var keep=Array(repeating:false,count:points.count); keep[0]=true; keep[points.count-1]=true
        var stack=[(0,points.count-1)]; let e2=epsilon*epsilon
        while let (a,b)=stack.popLast() {
            if b <= a+1 { continue }
            let x=points[a].x, y=points[a].y, vx=points[b].x-x, vy=points[b].y-y, vv=vx*vx+vy*vy
            var far=e2, selected = -1
            for i in (a+1)..<b {
                let t=vv != 0 ? clamp(((points[i].x-x)*vx+(points[i].y-y)*vy)/vv,0,1) : 0
                let d=pow(points[i].x-x-t*vx,2)+pow(points[i].y-y-t*vy,2)
                if d > far { far=d; selected=i }
            }
            if selected >= 0 { keep[selected]=true; stack.append((a,selected)); stack.append((selected,b)) }
        }
        return points.enumerated().filter { keep[$0.offset] }.map(\.element)
    }
    private static func segmentHits(_ a: DoorScreenPoint, _ b: DoorScreenPoint, _ r: DoorScreenRect) -> Bool {
        var lo=0.0, hi=1.0; let dx=b.x-a.x, dy=b.y-a.y
        for (p,q) in [(-dx,a.x-r.left),(dx,r.right-a.x),(-dy,a.y-r.top),(dy,r.bottom-a.y)] {
            if abs(p) < 1e-12 { if q < 0 { return false } }
            else { let t=q/p; if p < 0 { lo=max(lo,t) } else { hi=min(hi,t) }; if lo > hi { return false } }
        }
        return true
    }
    private static func markerBox(_ p: DoorScreenPoint, destination: Bool) -> DoorScreenRect {
        destination ? .init(left:p.x-23,top:p.y-46,right:p.x+23,bottom:p.y+7)
                    : .init(left:p.x-18,top:p.y-18,right:p.x+18,bottom:p.y+18)
    }
    private static func normalized(_ v: Viewport) -> NormalViewport? {
        guard v.width.isFinite, v.height.isFinite, v.width >= 80, v.height >= 120 else { return nil }
        let edge=max(8,v.edge.isFinite && v.edge != 0 ? v.edge : 12)
        let safe=DoorScreenRect(left:edge,top:edge,right:v.width-edge,bottom:v.height-edge)
        let obstacles=v.obstacles.filter(\.isFinite).map { r in
            DoorScreenRect(left:clamp(r.left,0,v.width),top:clamp(r.top,0,v.height),right:clamp(r.right,0,v.width),bottom:clamp(r.bottom,0,v.height))
        }.filter { $0.width > 0 && $0.height > 0 }
        return .init(width:v.width,height:v.height,safe:safe,obstacles:obstacles)
    }
    private static func prepare(_ coords: [DoorCoordinate], origin: DoorCoordinate, destination: DoorCoordinate) -> Prepared? {
        guard valid(origin), valid(destination) else { return nil }
        let line=coords.filter(valid), ref=mercator(origin)
        func local(_ p: DoorCoordinate) -> DoorScreenPoint {
            let m=mercator(p); var dx=m.x-ref.x; dx -= floor(dx+0.5) // JavaScript Math.round, including negative half ties.
            return .init(x:dx*512,y:(m.y-ref.y)*512)
        }
        let points=line.map(local), start=local(origin), end=local(destination)
        return .init(ref:ref,points:points,start:start,end:end,hull:hull(points+[start,end]),pointCount:line.count)
    }
    private static func stableSorted(_ values: [Candidate], key: (Camera) -> Double) -> [Candidate] {
        values.enumerated().sorted { a,b in
            let x=key(a.element.camera), y=key(b.element.camera)
            return x == y ? a.offset < b.offset : x < y
        }.map(\.element)
    }

    public static func solve(_ coords: [DoorCoordinate], origin: DoorCoordinate, destination: DoorCoordinate,
                             viewport: Viewport, options: Options = .init()) -> Camera? {
        guard let v=normalized(viewport), let data=prepare(coords,origin:origin,destination:destination) else { return nil }
        let maxZoom=clamp(options.maxZoom.isFinite ? options.maxZoom : 20,0,22), maxScale=pow(2,maxZoom)
        let span=extents(data.hull), dimension=max(span.width,span.height,1e-8), epsilon=dimension/4000
        let points=simplify(data.points,epsilon:epsilon), obstacles=v.obstacles
        let previous=options.previousBearing?.isFinite == true ? options.previousBearing : nil
        let full=options.full || previous == nil
        var stats=Stats(); stats.inputPoints=data.pointCount; stats.collisionPoints=points.count; stats.fullSearch=full
        func atAngle(_ angle: Double) -> Camera? {
            stats.angleEvaluations += 1
            let c=cos(angle*rad), s=sin(angle*rad), shape=data.hull.map { rotate($0,c,s) }, bounds=extents(shape)
            let line=points.map { rotate($0,c,s) }, start=rotate(data.start,c,s), end=rotate(data.end,c,s)
            let cap=min(maxScale,v.safe.width/max(1e-10,bounds.width),v.safe.height/max(1e-10,bounds.height))
            guard cap.isFinite, cap > 0 else { return nil }
            func place(_ scale: Double) -> Placement? {
                let aBox=markerBox(.init(x:scale*start.x,y:scale*start.y),destination:false)
                let bBox=markerBox(.init(x:scale*end.x,y:scale*end.y),destination:true)
                var x0=max(v.safe.left-scale*bounds.left,v.safe.left-aBox.left,v.safe.left-bBox.left)
                var x1=min(v.safe.right-scale*bounds.right,v.safe.right-aBox.right,v.safe.right-bBox.right)
                var y0=max(v.safe.top-scale*bounds.top,v.safe.top-aBox.top,v.safe.top-bBox.top)
                var y1=min(v.safe.bottom-scale*bounds.bottom,v.safe.bottom-aBox.bottom,v.safe.bottom-bBox.bottom)
                if options.riderAnchor {
                    let anchor=options.anchorBounds ?? .init(left:0.62,top:0.66,right:0.80,bottom:0.88)
                    x0=max(x0,v.width*anchor.left-scale*start.x); x1=min(x1,v.width*anchor.right-scale*start.x)
                    y0=max(y0,v.height*anchor.top-scale*start.y); y1=min(y1,v.height*anchor.bottom-scale*start.y)
                }
                guard x0 <= x1, y0 <= y1 else { return nil }
                let xs=[clamp(v.width*0.70-scale*start.x,x0,x1),(x0+x1)/2,x0,x1]
                let ys=[clamp(v.height*0.79-scale*start.y,y0,y1),(y0+y1)/2,y0,y1]
                let inflated=obstacles.map { $0.expanded(6+epsilon*scale) }, scaled=line.map { DoorScreenPoint(x:$0.x*scale,y:$0.y*scale) }
                var choice: Placement?
                for y in ys { for x in xs {
                    let a=DoorScreenPoint(x:scale*start.x+x,y:scale*start.y+y), b=DoorScreenPoint(x:scale*end.x+x,y:scale*end.y+y)
                    let mb1=markerBox(a,destination:false), mb2=markerBox(b,destination:true)
                    if obstacles.contains(where: { mb1.overlaps($0) || mb2.overlaps($0) }) { continue }
                    let rbox=DoorScreenRect(left:bounds.left*scale+x,top:bounds.top*scale+y,right:bounds.right*scale+x,bottom:bounds.bottom*scale+y)
                    var blocked=false
                    for rect in inflated {
                        if !rbox.overlaps(rect) { continue }
                        let relative=DoorScreenRect(left:rect.left-x,top:rect.top-y,right:rect.right-x,bottom:rect.bottom-y)
                        if scaled.count >= 2 { for i in 1..<scaled.count {
                            stats.collisionChecks += 1
                            if segmentHits(scaled[i-1],scaled[i],relative) { blocked=true; break }
                        } }
                        if blocked { break }
                    }
                    if blocked { continue }
                    let pref=options.riderAnchor ? -hypot(a.x/v.width-0.70,a.y/v.height-0.79)+(a.y-b.y)/v.height*0.12
                        : (a.y-b.y)/v.height*0.4-abs((rbox.left+rbox.right)/2-v.width/2)/v.width*0.06
                    if choice == nil || pref > choice!.preference { choice = .init(x:x,y:y,scale:scale,preference:pref,start:a,end:b) }
                } }
                return choice
            }
            var hi=cap, lo=0.0, fit=place(cap)
            if fit == nil {
                for _ in 0..<20 {
                    let next=hi*0.83
                    if let probe=place(next) { lo=next; fit=probe; break }
                    hi=next
                }
                guard fit != nil else { return nil }
                for _ in 0..<6 {
                    let mid=(lo+hi)/2
                    if let probe=place(mid) { lo=mid; fit=probe } else { hi=mid }
                }
            }
            guard let fit else { return nil }
            let sx=(v.width/2-fit.x)/fit.scale, sy=(v.height/2-fit.y)/fit.scale
            let center=coordinate(.init(x:data.ref.x+(c*sx-s*sy)/512,y:data.ref.y+(s*sx+c*sy)/512))
            return .init(center:center,zoom:log2(fit.scale),bearing:DoorCameraGeometry.signed(angle),start:fit.start,end:fit.end,preference:fit.preference,scale:fit.scale)
        }
        var candidates:[Candidate]=[]
        func evaluate(_ angle: Double) { if let result=atAngle(angle) { candidates.append(.init(camera:result,ordinal:candidates.count)) } }
        if full {
            for angle in stride(from:-180.0,to:180.0,by:6.0) { evaluate(angle) }
            if let previous { evaluate(previous) }
        } else if let previous { for d in stride(from:-12.0,through:12.0,by:3.0) { evaluate(previous+d) } }
        guard !candidates.isEmpty else { return nil }
        let targetGap=max(18,min(42,v.height*0.04))
        func targetAbove(_ p: Camera) -> Bool { p.start.y > p.end.y+targetGap }
        func score(_ p: Camera) -> Double {
            p.zoom+p.preference*0.05-(options.riderAnchor && previous != nil && options.continuous ? abs(DoorCameraGeometry.delta(p.bearing,previous!))*0.0025 : 0)
        }
        candidates=stableSorted(candidates,key: { -score($0) })
        let initialUpright=options.targetAbove ? candidates.filter { targetAbove($0.camera) } : []
        if options.targetAbove && !full && initialUpright.isEmpty { return nil }
        let seeds=Array((initialUpright.isEmpty ? candidates : initialUpright).prefix(full ? 3 : 1))
        for seed in seeds { for d in stride(from:-3.0,through:3.0,by:0.5) { evaluate(seed.camera.bearing+d) } }
        candidates=stableSorted(candidates,key: { -score($0) })
        let upright=options.targetAbove ? candidates.filter { targetAbove($0.camera) } : []
        let eligible=upright.isEmpty ? candidates : upright
        var best=eligible[0]
        if !options.targetAbove && full && !options.continuous,
           let soft=candidates.first(where: { $0.camera.start.y > $0.camera.end.y+20 && $0.camera.zoom >= best.camera.zoom-0.12 }) { best=soft }
        if let previous, options.continuous {
            let near=eligible.filter { $0.camera.zoom >= best.camera.zoom-(options.riderAnchor ? 0.25 : 0.055) }
            if let stable=stableSorted(near,key: { abs(DoorCameraGeometry.delta($0.bearing,previous)) }).first { best=stable }
        }
        if options.riderAnchor, options.continuous, let previous, abs(DoorCameraGeometry.delta(best.camera.bearing,previous)) > 35 {
            let near=eligible.filter { abs(DoorCameraGeometry.delta($0.camera.bearing,previous)) <= 12 && $0.camera.zoom >= best.camera.zoom-0.35 }
            if let steady=stableSorted(near,key: { abs(DoorCameraGeometry.delta($0.bearing,previous)) }).first { best=steady; best.camera.stabilityHeld=true }
        }
        best.camera.riderAnchor=options.riderAnchor
        best.camera.targetAbove=options.targetAbove && upright.contains { $0.ordinal == best.ordinal }
        best.camera.stats=stats
        guard contains(best.camera,coords:coords,origin:origin,destination:destination,viewport:viewport) else { return nil }
        return best.camera
    }
    public static func project(_ point: DoorCoordinate, camera: Camera, width: Double, height: Double) -> DoorScreenPoint {
        let p=mercator(point), c=mercator(camera.center), scale=512*pow(2,camera.zoom)
        var dx=p.x-c.x; dx -= floor(dx+0.5)
        let q=rotate(.init(x:dx*scale,y:(p.y-c.y)*scale),cos(camera.bearing*rad),sin(camera.bearing*rad))
        return .init(x:q.x+width/2,y:q.y+height/2)
    }
    public static func contains(_ camera: Camera, coords: [DoorCoordinate], origin: DoorCoordinate, destination: DoorCoordinate, viewport: Viewport) -> Bool {
        guard let v=normalized(viewport), valid(camera.center), camera.zoom.isFinite, camera.bearing.isFinite,
              valid(origin), valid(destination) else { return false }
        let line=coords.filter(valid).map { project($0,camera:camera,width:v.width,height:v.height) }
        for p in line where !v.safe.contains(.init(left:p.x,top:p.y,right:p.x,bottom:p.y),tolerance:0.1) { return false }
        for (p,isDestination) in [(origin,false),(destination,true)] {
            let box=markerBox(project(p,camera:camera,width:v.width,height:v.height),destination:isDestination)
            if !v.safe.contains(box,tolerance:0.1) || v.obstacles.contains(where: { box.overlaps($0) }) { return false }
        }
        for rect in v.obstacles {
            let expanded=rect.expanded(4)
            if line.count >= 2 { for i in 1..<line.count { if segmentHits(line[i-1],line[i],expanded) { return false } } }
        }
        return true
    }
}
