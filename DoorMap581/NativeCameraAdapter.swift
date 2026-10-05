import MapKit
import UIKit

/// The planner's Mercator zoom and composition are translated, never replaced
/// by setVisibleMapRect. Actual MapKit projection is sampled for DOM markers.
enum NativeCameraAdapter {
    static let earth = 40_075_016.68557849
    static func metersPerPoint(zoom: Double, latitude: Double) -> Double { earth * cos(latitude * .pi / 180) / (512 * pow(2, zoom)) }
    static func measuredMetersPerPoint(_ map: MKMapView) -> Double {
        let center = map.camera.centerCoordinate, heading = map.camera.heading * .pi / 180, meters = 100.0
        let p = CLLocationCoordinate2D(latitude: center.latitude - sin(heading) * meters / 111_320,
                                      longitude: center.longitude + cos(heading) * meters / (111_320 * max(0.1, cos(center.latitude * .pi / 180))))
        let a = map.convert(center, toPointTo: map), b = map.convert(p, toPointTo: map)
        let pixels = hypot(b.x - a.x, b.y - a.y)
        return pixels.isFinite && pixels > 0.01 ? meters / Double(pixels) : 1
    }
    static func measuredZoom(_ map: MKMapView) -> Double {
        log2(earth * cos(map.camera.centerCoordinate.latitude * .pi / 180) / (512 * measuredMetersPerPoint(map)))
    }
    @discardableResult
    static func apply(_ command: [String: Any], to map: MKMapView) -> [String: Double] {
        guard let center = command["center"] as? [String: Double], let lat = center["lat"], let lng = center["lng"],
              let zoom = command["zoom"] as? Double, let pitch = command["pitch"] as? Double,
              let heading = command["bearing"] as? Double, map.bounds.width > 0, map.bounds.height > 0,
              [lat,lng,zoom,pitch,heading].allSatisfy({ $0.isFinite }), CLLocationCoordinate2DIsValid(.init(latitude: lat, longitude: lng)) else { return ["invalidCommand": 1] }
        let target = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        let desired = metersPerPoint(zoom: zoom, latitude: lat)
        // Cold MapKit cameras can have a world-scale/zero distance. Seed from
        // the requested physical scale, then calibrate with real projection.
        var distance = min(40_000_000,max(50,desired * Double(map.bounds.height) * 1.5))
        let camera = MKMapCamera(lookingAtCenter: target, fromDistance: distance, pitch: CGFloat(min(65,max(0,pitch))), heading: heading)
        map.setCamera(camera, animated: false)
        for _ in 0..<3 {
            let measured = measuredMetersPerPoint(map)
            guard measured.isFinite, measured > 0, desired.isFinite, desired > 0 else { break }
            let ratio = min(8,max(0.125,desired / measured))
            if abs(ratio - 1) < 0.002 { break }
            distance = min(40_000_000, max(20, distance * ratio))
            camera.centerCoordinateDistance = distance; map.setCamera(camera, animated: false)
        }
        let padding = command["padding"] as? [String: Double] ?? [:], offset = command["offset"] as? [Double] ?? [0,0]
        let anchor = CGPoint(x: (Double(map.bounds.width) + (padding["left"] ?? 0) - (padding["right"] ?? 0)) / 2 + (offset.first ?? 0),
                             y: (Double(map.bounds.height) + (padding["top"] ?? 0) - (padding["bottom"] ?? 0)) / 2 + (offset.count > 1 ? offset[1] : 0))
        for _ in 0..<4 {
            let actual = map.convert(target, toPointTo: map), dx = actual.x - anchor.x, dy = actual.y - anchor.y
            if hypot(dx,dy) < 0.5 { break }
            let centerPixel = map.convert(camera.centerCoordinate, toPointTo: map)
            let correction = map.convert(CGPoint(x: centerPixel.x + dx, y: centerPixel.y + dy), toCoordinateFrom: map)
            guard CLLocationCoordinate2DIsValid(correction) else { break }
            camera.centerCoordinate = correction; map.setCamera(camera, animated: false)
        }
        let actual = map.convert(target, toPointTo: map)
        return ["requestedZoom":zoom,"actualZoom":measuredZoom(map),"requestedPitch":pitch,"actualPitch":Double(map.camera.pitch),
                "anchorErrorPoints":Double(hypot(actual.x-anchor.x,actual.y-anchor.y)),"scaleRatio":measuredMetersPerPoint(map)/desired]
    }
    static func mercator(_ point: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        ((point.longitude+180)/360,(1-asinh(tan(point.latitude * .pi/180)) / .pi)/2)
    }
    static func homography(_ map: MKMapView) -> [String: Any]? {
        let origin = mercator(map.camera.centerCoordinate), w = map.bounds.width, h = map.bounds.height
        guard w > 0, h > 0 else { return nil }
        let points = [CGPoint(x:w*0.25,y:h*0.35),CGPoint(x:w*0.75,y:h*0.35),CGPoint(x:w*0.75,y:h*0.75),CGPoint(x:w*0.25,y:h*0.75)]
        var matrix: [[Double]] = []
        for screen in points {
            let geo = map.convert(screen, toCoordinateFrom: map)
            guard CLLocationCoordinate2DIsValid(geo) else { return nil }
            let p = mercator(geo), x = p.x-origin.x, y = p.y-origin.y, sx = Double(screen.x), sy = Double(screen.y)
            matrix.append([x,y,1,0,0,0,-sx*x,-sx*y,sx]); matrix.append([0,0,0,x,y,1,-sy*x,-sy*y,sy])
        }
        for column in 0..<8 {
            let pivot = (column..<8).max(by: { abs(matrix[$0][column]) < abs(matrix[$1][column]) })!
            if abs(matrix[pivot][column]) < 1e-14 { return nil }
            matrix.swapAt(column,pivot)
            let denominator = matrix[column][column]
            for j in column..<9 { matrix[column][j] /= denominator }
            for row in 0..<8 where row != column {
                let factor = matrix[row][column]
                for j in column..<9 { matrix[row][j] -= factor*matrix[column][j] }
            }
        }
        let values = matrix.map { $0[8] }
        guard values.allSatisfy({ $0.isFinite }) else { return nil }
        return ["origin":["x":origin.x,"y":origin.y],"matrix":values]
    }
}

final class NativeContactObserver: UIGestureRecognizer {
    var contacts = Set<ObjectIdentifier>()
    var onContact: ((String, UITouch, Int) -> Void)?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { contacts.insert(ObjectIdentifier(touch)); onContact?("begin",touch,contacts.count) }
        state = state == .possible ? .began : .changed
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { onContact?("move",touch,contacts.count) }; state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { contacts.remove(ObjectIdentifier(touch)); onContact?("end",touch,contacts.count) }
        if contacts.isEmpty { state = .ended }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { contacts.remove(ObjectIdentifier(touch)); onContact?("cancel",touch,contacts.count) }
        state = .cancelled
    }
    override func reset() { contacts.removeAll(); super.reset() }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
