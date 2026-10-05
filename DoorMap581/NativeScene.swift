import MapKit
import UIKit

struct NativeSceneFeature {
    let id: String
    let layer: String
    let source: String
    let kind: String
    let geometry: [String: Any]
    let paint: [String: Any]
    let layout: [String: Any]
    init?(_ row: [String: Any]) {
        guard let layer = row["layer"] as? String, let source = row["source"] as? String,
              let kind = row["type"] as? String, let geometry = row["geometry"] as? [String: Any] else { return nil }
        self.id = row["id"] as? String ?? ""; self.layer = layer; self.source = source; self.kind = kind; self.geometry = geometry
        paint = row["paint"] as? [String: Any] ?? [:]; layout = row["layout"] as? [String: Any] ?? [:]
    }
    func number(_ key: String, default fallback: Double) -> Double { (paint[key] as? NSNumber)?.doubleValue ?? fallback }
    var coordinate: CLLocationCoordinate2D? {
        guard geometry["type"] as? String == "Point", let xy = geometry["coordinates"] as? [Double], xy.count >= 2 else { return nil }
        let point = CLLocationCoordinate2D(latitude: xy[1], longitude: xy[0])
        return CLLocationCoordinate2DIsValid(point) ? point : nil
    }
    var paths: [[[Double]]] {
        switch geometry["type"] as? String {
        case "LineString": return (geometry["coordinates"] as? [[Double]]).map { [$0] } ?? []
        case "MultiLineString", "Polygon": return geometry["coordinates"] as? [[[Double]]] ?? []
        case "MultiPolygon": return (geometry["coordinates"] as? [[[[Double]]]])?.flatMap { $0 } ?? []
        default: return []
        }
    }
}

final class NativeSceneOverlay: NSObject, MKOverlay {
    var features: [NativeSceneFeature] = []
    var coordinate = CLLocationCoordinate2D(latitude: 24.1477, longitude: 120.6736)
    var boundingMapRect: MKMapRect { .world }
}

final class NativeSceneRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let scene = overlay as? NativeSceneOverlay, zoomScale > 0 else { return }
        for feature in scene.features where feature.kind != "symbol" && feature.kind != "circle" {
            let paths = feature.paths
            guard !paths.isEmpty else { continue }
            let path = CGMutablePath()
            var visible = false
            for coordinates in paths {
                let points = coordinates.filter { $0.count >= 2 }.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0])) }
                guard points.count >= 2 else { continue }
                let xs = points.map(\.x), ys = points.map(\.y)
                let bounds = MKMapRect(x: xs.min()!, y: ys.min()!, width: max(1, xs.max()! - xs.min()!), height: max(1, ys.max()! - ys.min()!))
                if bounds.intersects(mapRect) { visible = true }
                path.move(to: point(for: points[0]))
                for p in points.dropFirst() { path.addLine(to: point(for: p)) }
                if feature.kind != "line" { path.closeSubpath() }
            }
            guard visible else { continue }
            context.saveGState()
            context.addPath(path)
            if feature.kind == "line" {
                let color = UIColor.nativeColor(feature.paint["line-color"] as? String ?? "#79a9df")
                context.setStrokeColor(color.withAlphaComponent(feature.number("line-opacity", default: 1)).cgColor)
                context.setLineWidth(CGFloat(max(0.25, feature.number("line-width", default: 1))) / zoomScale)
                context.setLineCap(.round); context.setLineJoin(.round)
                if let dash = feature.paint["line-dasharray"] as? [Double] { context.setLineDash(phase: 0, lengths: dash.map { CGFloat($0 * feature.number("line-width", default: 1)) / zoomScale }) }
                context.strokePath()
            } else {
                let extrusion = feature.kind == "fill-extrusion", prefix = extrusion ? "fill-extrusion" : "fill"
                let color = UIColor.nativeColor(feature.paint[prefix + "-color"] as? String ?? "#7c93a3")
                // MapKit has no arbitrary data-driven 3D extrusion. Preserve the
                // original exact footprint/target, clearly as a ground overlay.
                let alpha = extrusion ? min(0.18, feature.number(prefix + "-opacity", default: 1) * 0.18) : feature.number(prefix + "-opacity", default: 1)
                context.setFillColor(color.withAlphaComponent(alpha).cgColor)
                context.drawPath(using: .eoFill)
                if extrusion || feature.paint["fill-outline-color"] != nil {
                    context.addPath(path)
                    context.setStrokeColor(UIColor.nativeColor(feature.paint["fill-outline-color"] as? String ?? feature.paint[prefix + "-color"] as? String ?? "#7c93a3").withAlphaComponent(extrusion ? 0.8 : alpha).cgColor)
                    context.setLineWidth(CGFloat(extrusion ? 1.2 : 0.7) / zoomScale)
                    context.strokePath()
                }
            }
            context.restoreGState()
        }
    }
}

final class NativeSceneAnnotation: NSObject, MKAnnotation {
    var feature: NativeSceneFeature
    let coordinate: CLLocationCoordinate2D
    var title: String? { feature.layout["text-field"] as? String }
    var subtitle: String? { feature.layout["text-subtitle"] as? String }
    var stableKey: String { "\(feature.source):\(feature.layer):\(feature.id):\(coordinate.latitude):\(coordinate.longitude)" }
    init?(feature: NativeSceneFeature) {
        guard let coordinate = feature.coordinate else { return nil }
        self.feature = feature; self.coordinate = coordinate
    }
}

final class NativeSceneAnnotationView: MKAnnotationView {
    func configure(_ item: NativeSceneAnnotation) {
        for subview in subviews { subview.removeFromSuperview() }
        layer.sublayers?.filter { $0.name == "581-symbol" }.forEach { $0.removeFromSuperlayer() }
        let f = item.feature
        let text = f.layout["text-field"] as? String ?? ""
        let icon = f.layout["icon-image"] as? String ?? ""
        isEnabled = true; canShowCallout = false; collisionMode = .rectangle
        displayPriority = (f.layout["text-allow-overlap"] as? Bool == true || f.layer.contains("destination")) ? .required : .defaultHigh
        clusteringIdentifier = f.layer == "extra-gogoro-points" ? "581-original-gogoro" : f.source == "planner-search-results" && f.kind == "circle" ? "581-original-search" : nil
        accessibilityIdentifier = "native-layer-" + f.layer
        accessibilityLabel = text.isEmpty ? f.layer : text
        if f.kind == "circle" {
            let radius = max(3, f.number("circle-radius", default: 6)), circle = CAShapeLayer()
            frame.size = CGSize(width: radius * 2 + 8, height: radius * 2 + 8)
            circle.name = "581-symbol"; circle.path = UIBezierPath(ovalIn: CGRect(x: 4, y: 4, width: radius * 2, height: radius * 2)).cgPath
            circle.fillColor = UIColor.nativeColor(f.paint["circle-color"] as? String ?? "#4dddba").withAlphaComponent(f.number("circle-opacity", default: 1)).cgColor
            circle.strokeColor = UIColor.nativeColor(f.paint["circle-stroke-color"] as? String ?? "#fff").cgColor
            circle.lineWidth = f.number("circle-stroke-width", default: 0); layer.addSublayer(circle)
            centerOffset = .zero
        } else if !icon.isEmpty {
            frame.size = CGSize(width: 32, height: 42); centerOffset = CGPoint(x: 0, y: -20)
            let pin = CAShapeLayer(); pin.name = "581-symbol"
            let path = UIBezierPath(); path.move(to: CGPoint(x: 16, y: 40))
            path.addCurve(to: CGPoint(x: 2, y: 16), controlPoint1: CGPoint(x: 10, y: 28), controlPoint2: CGPoint(x: 2, y: 24))
            path.addArc(withCenter: CGPoint(x: 16, y: 16), radius: 14, startAngle: .pi, endAngle: 0, clockwise: true)
            path.addCurve(to: CGPoint(x: 16, y: 40), controlPoint1: CGPoint(x: 30, y: 24), controlPoint2: CGPoint(x: 22, y: 28)); path.close()
            pin.path = path.cgPath; pin.fillColor = UIColor.systemRed.cgColor; pin.strokeColor = UIColor.white.cgColor; pin.lineWidth = 1.5
            layer.addSublayer(pin)
            let dot = UIView(frame: CGRect(x: 12, y: 12, width: 8, height: 8)); dot.backgroundColor = .white; dot.layer.cornerRadius = 4; addSubview(dot)
        } else {
            let label = UILabel()
            label.text = text; label.font = .systemFont(ofSize: CGFloat((f.layout["text-size"] as? NSNumber)?.doubleValue ?? 11), weight: f.layer.contains("hit") ? .semibold : .regular)
            label.textColor = UIColor.nativeColor(f.paint["text-color"] as? String ?? "#ffffff")
            label.layer.shadowColor = UIColor.nativeColor(f.paint["text-halo-color"] as? String ?? "#121b27").cgColor
            label.layer.shadowRadius = CGFloat(f.number("text-halo-width", default: 1)); label.layer.shadowOpacity = 1; label.layer.shadowOffset = .zero
            label.alpha = CGFloat(f.number("text-opacity", default: 1)); label.sizeToFit(); label.frame = label.frame.insetBy(dx: -2, dy: -1)
            frame.size = label.frame.size; label.frame.origin = .zero; addSubview(label)
            let offset = f.layout["text-offset"] as? [Double] ?? [0,0]
            let font = Double(label.font.pointSize)
            centerOffset = CGPoint(x: offset.count > 0 ? offset[0] * font : 0, y: offset.count > 1 ? offset[1] * font : 0)
        }
    }
}

extension UIColor {
    static func nativeColor(_ string: String) -> UIColor {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") {
            let hex = String(text.dropFirst()), raw = UInt64(hex, radix: 16) ?? 0
            if hex.count == 3 { return UIColor(red: Double((raw >> 8) & 15) / 15, green: Double((raw >> 4) & 15) / 15, blue: Double(raw & 15) / 15, alpha: 1) }
            if hex.count == 6 { return UIColor(red: Double((raw >> 16) & 255) / 255, green: Double((raw >> 8) & 255) / 255, blue: Double(raw & 255) / 255, alpha: 1) }
            if hex.count == 8 { return UIColor(red: Double((raw >> 24) & 255) / 255, green: Double((raw >> 16) & 255) / 255, blue: Double((raw >> 8) & 255) / 255, alpha: Double(raw & 255) / 255) }
        }
        if text.hasPrefix("rgb") {
            let parts = text.components(separatedBy: CharacterSet(charactersIn: "rgba(), ")).compactMap { Double($0) }
            if parts.count >= 3 { return UIColor(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: parts.count > 3 ? parts[3] : 1) }
        }
        if text == "transparent" { return .clear }; if text == "black" { return .black }
        return .white
    }
}
