import CoreLocation
import MapKit
import UIKit

private actor NativeFitWorker {
    struct Answer: Sendable { let plan: DoorFitCamera.Camera; let fallback: Bool }
    func solve(path: [DoorCoordinate], origin: DoorCoordinate, destination: DoorCoordinate,
               viewport: DoorFitCamera.Viewport, maxZoom: Double, previous: Double?, full: Bool, continuous: Bool) -> Answer? {
        guard !Task.isCancelled else { return nil }
        func run(full: Bool, rider: Bool = true, bounds: DoorScreenRect? = nil) -> DoorFitCamera.Camera? {
            DoorFitCamera.solve(path, origin: origin, destination: destination, viewport: viewport,
                options: .init(maxZoom: maxZoom, previousBearing: previous, full: full, continuous: continuous,
                               riderAnchor: rider, targetAbove: true, anchorBounds: bounds))
        }
        if let p = run(full: full) { return .init(plan: p, fallback: false) }
        if !full, let p = run(full: true) { return .init(plan: p, fallback: false) }
        if let p = run(full: true, bounds: .init(left: 0.35, top: 0.58, right: 0.82, bottom: 0.88)) {
            return .init(plan: p, fallback: false)
        }
        if let p = run(full: true, rider: false) { return .init(plan: p, fallback: true) }
        return nil
    }
}

/// The sole native programmatic camera owner. Sensor intake never waits for FIT.
/// S3 exposes north/heading/FIT; full navigation routing is wired separately.
@MainActor final class NativeRidingCamera {
    enum Mode: String { case free, north, heading, navigation, fit }
    private weak var map: MKMapView?
    private let worker = NativeFitWorker()
    private var fitTask: Task<Void, Never>?
    private var fitTimer: Timer?
    private var resumeWork: DispatchWorkItem?
    private var staleHeadingWork: DispatchWorkItem?
    private var contact: NativeContactObserver?
    private var pointerIDs: [ObjectIdentifier: Int] = [:]
    private var nextPointer = 0
    private var pinchStartZoom: Double?
    private var pendingZoomStart: Double?
    private var unprotectedOrigin: DoorScreenPoint?
    private var gestureEvidence: [[String: Any]] = []
    private var generation: UInt64 = 0
    private var lastFollowMS = -Double.infinity
    private var lastFitMS = -Double.infinity
    private var lastFullMS = -Double.infinity
    private var lastPosition: DoorCoordinate?
    private var lastFullPosition: DoorCoordinate?
    private var lastLayout = ""
    private var lastRouteRevision: UInt64 = 0
    private var routeRevision: UInt64 = 0
    private var dirty = true
    private var active = true
    private var suspended = false
    private var compass: DoorHeadingFilter.Compass?
    private var heading = DoorHeadingFilter()
    private var navigationBearing = DoorNavigationBearing()
    private var arrival3DLocked = false
    private var lastNavigationMS = -Double.infinity
    private var lead = DoorDisplayLeadModel()
    private var cursor = DoorRouteCursor()
    private var route: [DoorCoordinate] = []
    private var destination: DoorCoordinate?
    private var maneuvers: [DoorRouteManeuver] = []
    private var routeLine: MKPolyline?
    private var routeVisible = true
    private var avatarMode: RiderAvatarMode = .classic
    private var rider: NativeRiderAnnotation?
    private var viewport = DoorFitCamera.Viewport(width: 0, height: 0)
    private var interaction = DoorCameraInteraction()
    private(set) var mode: Mode = .north
    private var preFitMode: Mode = .heading
    private(set) var raw: NativeSensorFix?
    private(set) var displayPosition: DoorCoordinate?
    private(set) var zoomOffset = 0.0
    private(set) var lastPlan: DoorFitCamera.Camera?
    private(set) var cameraApplications = 0
    private(set) var fitEvaluations = 0
    private(set) var fitBusy = false
    private(set) var anchorError = 0.0
    private(set) var pip = true
    private(set) var headingKnown = false
    var onChange: (() -> Void)?
    var onMessage: ((String) -> Void)?
    var controlRects: [DoorScreenRect] = []
    var hudHeight = 50.0
    var collapsedInsetHeight = 56.0
    var canFit: Bool { raw != nil && destination != nil && route.count >= 2 }
    var canNavigate: Bool { canFit }
    var nextManeuver: DoorRouteManeuver? {
        maneuvers.first { $0.type != "depart" && $0.type != "arrive" && $0.routeIndex >= max(0, cursor.index - 1) }
    }
    var nextManeuverMeters: Double? {
        guard let maneuver = nextManeuver else { return nil }
        let remaining = cursor.remaining
        if remaining.count >= 2, maneuver.routeIndex > cursor.index {
            let target = min(remaining.count - 1, maneuver.routeIndex - cursor.index)
            if target > 0 { return zip(remaining.prefix(target + 1), remaining.dropFirst().prefix(target)).reduce(0) { $0 + DoorCameraGeometry.haversine($1.0, $1.1) } }
        }
        guard let raw, let location = maneuver.location else { return nil }
        return DoorCameraGeometry.haversine(raw.coordinate, location)
    }
    var gestureHolding: Bool { interaction.holding }
    var pointerCount: Int { interaction.pointerCount }
    var displayHeading: Double? { heading.displayHeading }
    var remainingMeters: Double? {
        guard route.count >= 2 else { return nil }
        return zip(cursor.remaining, cursor.remaining.dropFirst()).reduce(0) { $0 + DoorCameraGeometry.haversine($1.0, $1.1) }
    }
    private var selection: DoorCameraInteraction.Selection {
        .init(fitLocked: mode == .fit, following: mode == .north || mode == .heading || mode == .navigation,
              cameraUserOverride: mode == .free, navigationActive: mode == .navigation, navigationRequested: false,
              headingMode: mode == .heading || mode == .navigation, editing: false)
    }
    init(map: MKMapView) {
        self.map = map
        let observer = NativeContactObserver(target: nil, action: nil)
        observer.cancelsTouchesInView = false; observer.delaysTouchesBegan = false
        observer.onContact = { [weak self] phase, touch, remaining in self?.contactEvent(phase, touch: touch, remaining: remaining) }
        contact = observer; map.addGestureRecognizer(observer)
        interaction.selectionChanged(selection)
    }
    func setMode(_ value: Mode) {
        if value == .fit && !canFit { onMessage?("先設定目的地並取得路線，再按 FIT"); return }
        if value == .navigation && !canNavigate { onMessage?("先取得機車路線，再開始導航"); return }
        pinchStartZoom = nil; pendingZoomStart = nil
        if value == .fit && mode != .fit { preFitMode = mode == .navigation ? .navigation : (mode == .heading ? .heading : .north) }
        mode = value; dirty = true; generation &+= 1; fitTask?.cancel(); fitTask = nil; fitBusy = false
        resumeWork?.cancel(); interaction.selectionChanged(selection)
        if value == .fit { lastFitMS = -.infinity; lastFullMS = -.infinity; lastPosition = nil; lastFullPosition = nil; lastPlan = nil }
        if value == .navigation { navigationBearing.reset(); arrival3DLocked = false; lastNavigationMS = -.infinity; if let raw { accept(raw) } }
        reconcileTimer(); refresh(force: true); onChange?()
    }
    func toggleFit() { mode == .fit ? setMode(preFitMode == .navigation && canNavigate ? .navigation : preFitMode) : setMode(.fit) }
    func setPiP(_ value: Bool) { pip = value; dirty = true; updateLayout(force: true) }
    func setRouteVisible(_ value: Bool) { routeVisible = value; if let routeLine { map?.removeOverlay(routeLine); if value { map?.addOverlay(routeLine) } }; onChange?() }
    func setAvatarMode(_ value: RiderAvatarMode) { avatarMode = value; updateRider(); onChange?() }
    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }; suspended = value; generation &+= 1
        if value { fitTask?.cancel(); fitTask = nil; fitBusy = false } else { dirty = true; refresh(force: true) }
    }
    /// Only committed, validated route geometry may enter; never fabricate a straight route.
    func setRoute(_ path: [DoorCoordinate], destination: DoorCoordinate, maneuvers: [DoorRouteManeuver] = []) {
        guard path.count >= 2, path.count <= 100_000, path.allSatisfy(\.isValid), destination.isValid else { return }
        route = path; self.destination = destination; self.maneuvers = maneuvers; routeRevision &+= 1
        cursor.reset(path: path); lead.reset(); lastPlan = nil; dirty = true; generation &+= 1
        fitTask?.cancel(); fitTask = nil; fitBusy = false
        if let line = routeLine { map?.removeOverlay(line) }
        let coordinates = path.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
        let line = MKPolyline(coordinates: coordinates, count: coordinates.count); routeLine = line; if routeVisible { map?.addOverlay(line) }
        if let raw { accept(raw) } else { refresh(force: true) }
    }
    func setDestination(_ value: DoorCoordinate?) {
        destination = value; route = []; maneuvers = []; cursor.reset(path: []); lead.reset(); routeRevision &+= 1
        generation &+= 1; fitTask?.cancel(); fitTask = nil; fitBusy = false
        if let line = routeLine { map?.removeOverlay(line) }; routeLine = nil
        if mode == .fit || mode == .navigation { setMode(.heading) }; dirty = true; onChange?()
    }
    func accept(_ value: NativeSensorFix) {
        guard active, value.coordinate.isValid else { return }
        if value.warm {
            if raw == nil { displayPosition = value.coordinate; updateRider() }
            return // A cached display fix must not become a route origin or a FIT input.
        }
        raw = value
        let navigating = mode == .fit || mode == .navigation
        cursor.update(raw: value.coordinate, path: route, destination: destination, navigating: navigating)
        displayPosition = lead.update(raw: value.coordinate, accuracy: value.accuracy, speed: value.speed,
            riding: navigating, path: route, cursor: cursor.index, destination: destination, maneuvers: maneuvers)
        updateDirection(); updateRider(); refresh(); onChange?()
    }
    func acceptHeading(_ value: DoorHeadingFilter.Compass) {
        guard active else { return }; compass = value; updateDirection(); updateRider()
        if mode == .heading { refresh() }
        staleHeadingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateDirection(); self?.updateRider(); self?.onChange?() }
        staleHeadingWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 2.55, execute: work)
        onChange?()
    }
    private func updateDirection() {
        let now = Date().timeIntervalSince1970 * 1000
        let fresh = compass.map { now - $0.timestampMS >= -2000 && now - $0.timestampMS < 2500 } ?? false
        let course = raw.flatMap { Date().timeIntervalSince($0.timestamp) <= 20 ? $0.course : nil }
        headingKnown = fresh || course != nil
        _ = heading.update(compass: compass, course: course, nowMS: now, monotonicMS: ProcessInfo.processInfo.systemUptime * 1000)
    }
    func updateLayout(force: Bool = false) {
        guard let map else { return }
        viewport = DoorCameraViewport.fit(width: Double(map.bounds.width), height: Double(map.bounds.height), pip: pip, controlRects: controlRects)
        refresh(force: force)
    }
    private func updateRider() {
        guard let map, let point = displayPosition else { return }
        let coordinate = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng)
        if let rider { rider.coordinate = coordinate } else { let item = NativeRiderAnnotation(coordinate: coordinate); rider = item; map.addAnnotation(item) }
        if let rider, let v = map.view(for: rider) as? NativeRiderView { v.update(heading: headingKnown ? heading.displayHeading : nil, mapBearing: map.camera.heading, warm: raw == nil, avatar: avatarMode) }
    }
    func annotationView(for annotation: MKAnnotation) -> MKAnnotationView? {
        guard annotation === rider, let map else { return nil }
        let view = map.dequeueReusableAnnotationView(withIdentifier: "native-rider") as? NativeRiderView ?? NativeRiderView(annotation: annotation, reuseIdentifier: "native-rider")
        view.annotation = annotation; view.update(heading: headingKnown ? heading.displayHeading : nil, mapBearing: map.camera.heading, warm: raw == nil, avatar: avatarMode); return view
    }
    func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        guard overlay === routeLine, let line = overlay as? MKPolyline else { return nil }
        let renderer = MKPolylineRenderer(polyline: line); renderer.strokeColor = .systemBlue; renderer.lineWidth = 5; return renderer
    }
    func regionChanged() { updateRider() }
    func refresh(force: Bool = false) {
        guard active, !suspended, !interaction.holding, pendingZoomStart == nil, let map, let raw, let point = displayPosition,
              map.bounds.width > 0, map.bounds.height > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime * 1000
        if mode == .fit { requestFit(now: now, force: force); return }
        if mode == .navigation { requestNavigation(now: now, force: force); return }
        guard mode == .north || mode == .heading, force || now - lastFollowMS >= 180 else { return }
        lastFollowMS = now
        let direct = destination.map { DoorCameraGeometry.haversine(point, $0) } ?? .infinity
        let zoom = DoorArrivalPolicy.manualZoom(DoorArrivalPolicy.nearDestination2DZoom(distance: direct) ?? 16.2, offset: zoomOffset)
        let bearing = mode == .north ? 0 : (headingKnown ? heading.displayHeading ?? map.camera.heading : map.camera.heading)
        let metrics = NativeCameraAdapter.apply(["center": ["lat": point.lat, "lng": point.lng], "zoom": zoom, "pitch": 0.0, "bearing": bearing], to: map)
        anchorError = metrics["anchorErrorPoints"] ?? 0; cameraApplications += 1
        _ = raw // Intake is deliberately separate from camera availability.
    }
    private func routeForwardBearing(fallback: Double) -> Double {
        let points = cursor.remaining
        guard points.count >= 2 else { return DoorCameraGeometry.heading(fallback) }
        let start = points[0], targetMeters = 36.0
        var walked = 0.0, target = points[1]
        for i in 1..<points.count {
            let a = points[i-1], b = points[i], segment = DoorCameraGeometry.haversine(a, b)
            guard segment.isFinite, segment > 0.01 else { continue }
            if walked + segment >= targetMeters {
                let q = max(0, min(1, (targetMeters - walked) / segment))
                target = .init(lat: a.lat + (b.lat-a.lat)*q, lng: a.lng + (b.lng-a.lng)*q)
                break
            }
            walked += segment; target = b
        }
        let value = DoorCameraGeometry.bearing(start, target)
        return value.isFinite ? value : DoorCameraGeometry.heading(fallback)
    }
    private func requestNavigation(now: Double, force: Bool) {
        guard let map, let point = displayPosition, let destination, route.count >= 2 else { return }
        guard force || now - lastNavigationMS >= 180 else { return }
        lastNavigationMS = now
        let direct = DoorCameraGeometry.haversine(point, destination)
        let routed = remainingMeters
        let remaining = routed.map { max($0, direct.isFinite ? direct : 0) } ?? direct
        let fallback = headingKnown ? (heading.displayHeading ?? map.camera.heading) : map.camera.heading
        let targetBearing = routeForwardBearing(fallback: fallback)
        let bearing = navigationBearing.update(target: targetBearing, nowMS: now, force: force) ?? targetBearing
        arrival3DLocked = DoorArrivalPolicy.locked(distance: remaining, wasLocked: arrival3DLocked)
        let baseZoom = arrival3DLocked ? 18.15 : DoorArrivalPolicy.stable3DZoom(distance: remaining)
        let zoom = DoorArrivalPolicy.manualZoom(baseZoom, offset: zoomOffset)
        let pitch = 58.0
        guard let composition = DoorCameraViewport.navigation(width: Double(map.bounds.width), height: Double(map.bounds.height),
                                                              pip: pip, hudHeight: hudHeight,
                                                              collapsedInsetHeight: collapsedInsetHeight) else { return }
        let metrics = NativeCameraAdapter.apply([
            "center": ["lat": point.lat, "lng": point.lng],
            "zoom": zoom, "pitch": pitch, "bearing": bearing,
            "padding": ["top": composition.top, "bottom": composition.bottom,
                        "left": composition.left, "right": composition.right],
            "offset": [0.0, composition.offsetY]
        ], to: map)
        anchorError = metrics["anchorErrorPoints"] ?? 0
        cameraApplications += 1
        updateRider()
    }
    private func requestFit(now: Double, force: Bool) {
        guard !fitBusy, let raw, let point = displayPosition, let destination, route.count >= 2 else { return }
        guard force || now - lastFitMS >= 1000 else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let layout = (try? encoder.encode(viewport)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let newRoute = routeRevision != lastRouteRevision, changed = layout != lastLayout
        let moved = lastPosition.map { DoorCameraGeometry.haversine($0, point) } ?? .infinity
        if !force && !newRoute && !changed && !dirty && moved < max(5, min(12, raw.accuracy * 0.8)) { return }
        if !force && raw.accuracy > 70 { return }
        let fullMoved = lastFullPosition.map { DoorCameraGeometry.haversine($0, point) } ?? .infinity
        let full = force || newRoute || changed || lastPlan == nil || (now - lastFullMS >= 15_000 && fullMoved >= 80)
        let previous = lastPlan?.bearing ?? map?.camera.heading, continuous = lastPlan != nil
        let path = cursor.remaining, viewport = self.viewport, maxZoom = (remainingMeters ?? .infinity) <= 150 ? 20.0 : 18.85
        let ticket = generation, revision = routeRevision
        lastFitMS = now; fitBusy = true; fitEvaluations += 1
        fitTask = Task { [weak self, worker] in
            let answer = await worker.solve(path: path, origin: point, destination: destination, viewport: viewport,
                                            maxZoom: maxZoom, previous: previous, full: full, continuous: continuous)
            guard let self, !Task.isCancelled, self.generation == ticket else { return }
            self.fitBusy = false; self.fitTask = nil
            guard self.active, !self.suspended, !self.interaction.holding, self.mode == .fit, let map = self.map else { return }
            let currentLayout = (try? encoder.encode(self.viewport)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            guard self.raw?.timestamp == raw.timestamp, self.displayPosition == point,
                  self.routeRevision == revision, currentLayout == layout else {
                self.dirty = true; self.refresh(force: currentLayout != layout); self.onChange?(); return
            }
            guard var plan = answer?.plan else { self.dirty = true; self.onMessage?("目前遮擋範圍無法安全 FIT；路線與定位保留"); self.onChange?(); return }
            plan.zoom = DoorArrivalPolicy.manualZoom(plan.zoom, offset: self.zoomOffset)
            self.lastPosition = point; self.lastLayout = layout; self.lastRouteRevision = revision; self.dirty = false
            if full { self.lastFullMS = now; self.lastFullPosition = point }
            let current = DoorFitCamera.Camera(center: .init(lat: map.camera.centerCoordinate.latitude, lng: map.camera.centerCoordinate.longitude),
                zoom: NativeCameraAdapter.measuredZoom(map), bearing: map.camera.heading, pitch: Double(map.camera.pitch),
                start: .init(x: 0, y: 0), end: .init(x: 0, y: 0), preference: 0, scale: 1)
            let fitsNow = current.pitch == 0 && DoorFitCamera.contains(current, coords: path, origin: point, destination: destination, viewport: viewport)
            let wanted = DoorFitCamera.project(point, camera: plan, width: viewport.width, height: viewport.height)
            let before = DoorFitCamera.project(point, camera: current, width: viewport.width, height: viewport.height)
            if !force && !newRoute && fitsNow && abs(plan.zoom - current.zoom) < 0.12 &&
                abs(DoorCameraGeometry.delta(plan.bearing, current.bearing)) < 4 && hypot(wanted.x - before.x, wanted.y - before.y) < 14 {
                self.onChange?(); return
            }
            self.lastPlan = plan
            let metrics = NativeCameraAdapter.apply(["center": ["lat": plan.center.lat, "lng": plan.center.lng],
                "zoom": plan.zoom, "pitch": 0.0, "bearing": plan.bearing, "padding": ["top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0]], to: map)
            self.anchorError = metrics["anchorErrorPoints"] ?? 0; self.cameraApplications += 1; self.updateRider(); self.onChange?()
        }
    }
    private func contactEvent(_ phase: String, touch: UITouch, remaining: Int) {
        guard let map else { return }; let key = ObjectIdentifier(touch), position = touch.location(in: map)
        if pointerIDs[key] == nil { nextPointer += 1; pointerIDs[key] = nextPointer }
        let id = pointerIDs[key]!, point = DoorScreenPoint(x: Double(position.x), y: Double(position.y))
        let now = ProcessInfo.processInfo.systemUptime * 1000
        switch phase {
        case "begin":
            if pointerIDs.count == 1 { finishManualZoomCapture() }
            resumeWork?.cancel(); generation &+= 1; fitTask?.cancel(); fitTask = nil; fitBusy = false
            if !selection.isProtected { unprotectedOrigin = point }
            _ = interaction.begin(id: id, at: point, selection: selection, foreground: active)
            if remaining >= 2 && mode != .free && pinchStartZoom == nil { pinchStartZoom = NativeCameraAdapter.measuredZoom(map) }
        case "move":
            interaction.move(to: point)
            if mode == .north, !selection.isProtected, let origin = unprotectedOrigin,
               hypot(point.x - origin.x, point.y - origin.y) >= 8 { unprotectedOrigin = nil; setMode(.free) }
        case "end", "cancel":
            if phase == "cancel" { pinchStartZoom = nil; pendingZoomStart = nil }
            else if remaining == 0, let start = pinchStartZoom {
                // UIKit touch delivery precedes MapKit's final zoom transaction.
                // Retain the baseline until the existing resume boundary; do not
                // discard a small early delta or restore FIT over a settling pinch.
                pendingZoomStart = start; pinchStartZoom = nil
            }
            let effect = interaction.end(id: id, cancelled: phase == "cancel", remainingTouches: remaining, nowMS: now, selection: selection, foreground: active)
            pointerIDs.removeValue(forKey: key)
            if remaining == 0 { unprotectedOrigin = nil }
            if effect.resume {
                if pendingZoomStart != nil {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.interaction.pointerCount == 0 else { return }
                        self.finishManualZoomCapture(); self.refresh(force: true); self.onChange?()
                    }
                } else { refresh(force: true) }
            }
            if let deadline = interaction.resumeAtMS {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    let effect = self.interaction.advance(nowMS: ProcessInfo.processInfo.systemUptime * 1000, selection: self.selection, foreground: self.active)
                    if effect.resume { self.finishManualZoomCapture(); self.refresh(force: true); self.onChange?() }
                }
                resumeWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - now) / 1000, execute: work)
            }
        default: break
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOOR_NATIVE_S3_UI_TEST"] == "1" {
            gestureEvidence.append(["phase": phase, "id": id, "remaining": remaining,
                "activePointers": interaction.pointerCount, "holding": interaction.holding,
                "zoom": NativeCameraAdapter.measuredZoom(map), "startZoom": pinchStartZoom ?? -999,
                "offset": zoomOffset, "mode": mode.rawValue, "resumeAt": interaction.resumeAtMS ?? -1,
                "atMS": now])
            if gestureEvidence.count > 40 { gestureEvidence.removeFirst(gestureEvidence.count - 40) }
        }
        #endif
        onChange?()
    }
    private func finishManualZoomCapture() {
        guard let start = pendingZoomStart, let map else { return }
        pendingZoomStart = nil
        let measured = NativeCameraAdapter.measuredZoom(map), delta = measured - start
        if delta.isFinite && abs(delta) >= 0.03 {
            zoomOffset = max(-3, min(3, zoomOffset + delta)); dirty = true
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOOR_NATIVE_S3_UI_TEST"] == "1" {
            gestureEvidence.append(["phase": "zoom-commit-after-native-settle", "startZoom": start,
                                    "zoom": measured, "delta": delta, "offset": zoomOffset])
        }
        #endif
    }
    private func reconcileTimer() {
        fitTimer?.invalidate(); fitTimer = nil
        if active && mode == .fit {
            fitTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            fitTimer?.tolerance = 0.15
        }
    }
    func setActive(_ value: Bool) {
        active = value; generation &+= 1; fitTask?.cancel(); fitTask = nil; fitBusy = false
        resumeWork?.cancel(); staleHeadingWork?.cancel(); pointerIDs.removeAll(); pinchStartZoom = nil; pendingZoomStart = nil; unprotectedOrigin = nil
        _ = interaction.lifecycle(foreground: value, selection: selection)
        reconcileTimer(); if value { dirty = true; updateDirection(); updateRider(); refresh(force: true) }
    }
    func diagnostics() -> [String: Any] {
        var result: [String: Any] = ["cameraMode": mode.rawValue, "fitBusy": fitBusy, "fitEvaluations": fitEvaluations,
            "cameraApplications": cameraApplications, "headingKnown": headingKnown, "gestureHolding": interaction.holding,
            "gesturePointers": interaction.pointerCount, "cameraZoomOffset": zoomOffset, "pipPreset": pip,
            "routeVisible": routeVisible, "avatarMode": avatarMode.rawValue, "navigation3D": mode == .navigation, "navigationArrivalLocked": arrival3DLocked,
            "nextManeuverMeters": nextManeuverMeters ?? -1,
            "source": raw == nil ? "NO_FRESH_SENSOR_POSITION" : "NATIVE_TYPED_SENSOR_INPUT",
            "sensorRawPosition": raw.map { [$0.coordinate.lat, $0.coordinate.lng] } ?? [],
            "displayPosition": displayPosition.map { [$0.lat, $0.lng] } ?? [], "routeCount": route.count,
            "fitPlanReady": lastPlan != nil, "anchorErrorPoints": anchorError]
        if let map, let destination, let point = displayPosition {
            let target = map.convert(.init(latitude: destination.lat, longitude: destination.lng), toPointTo: map)
            let rider = map.convert(.init(latitude: point.lat, longitude: point.lng), toPointTo: map)
            if [target.x, target.y, rider.x, rider.y].allSatisfy({ $0.isFinite }) {
                result["targetPixel"] = [Double(target.x), Double(target.y)]
                result["riderPixel"] = [Double(rider.x), Double(rider.y)]
            }
            result["pipBottom"] = pip ? DoorCameraViewport.pipBottom(width: Double(map.bounds.width), height: Double(map.bounds.height)) : 0
        }
        result["gestureEvidence"] = gestureEvidence
        result["measuredZoom"] = map.map { NativeCameraAdapter.measuredZoom($0) } ?? -1
        result["mapPitch"] = map.map { Double($0.camera.pitch) } ?? -1
        result["mapBearing"] = map.map { $0.camera.heading } ?? -1
        return result
    }
    func teardown() {
        setActive(false); mode = .free; contact?.onContact = nil
        if let contact { map?.removeGestureRecognizer(contact) }; contact = nil
        if let rider { map?.removeAnnotation(rider) }; rider = nil
        if let routeLine { map?.removeOverlay(routeLine) }; routeLine = nil
        onChange = nil; onMessage = nil; map = nil
    }
}

final class NativeRiderAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(coordinate: CLLocationCoordinate2D) { self.coordinate = coordinate; super.init() }
}
final class NativeRiderView: MKAnnotationView {
    private let fan = CAShapeLayer(), dot = CAShapeLayer(), avatarHeading = CAShapeLayer()
    private let avatarImage = UIImageView()
    private var images: [RiderAvatarMode: (front: UIImage, back: UIImage)] = [:]
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame.size = CGSize(width: 100, height: 100); centerOffset = .zero; isEnabled = false; displayPriority = .required
        let shape = UIBezierPath(); shape.move(to: CGPoint(x: 50, y: 50))
        shape.addArc(withCenter: CGPoint(x: 50, y: 50), radius: 42, startAngle: -.pi / 2 - .pi / 7, endAngle: -.pi / 2 + .pi / 7, clockwise: true); shape.close()
        fan.path = shape.cgPath; fan.frame = bounds; fan.fillColor = UIColor.systemCyan.withAlphaComponent(0.35).cgColor
        dot.path = UIBezierPath(ovalIn: CGRect(x: 43, y: 43, width: 14, height: 14)).cgPath
        dot.fillColor = UIColor.systemBlue.cgColor; dot.strokeColor = UIColor.white.cgColor; dot.lineWidth = 2
        let arrow = UIBezierPath(); arrow.move(to: CGPoint(x: 50, y: 7)); arrow.addLine(to: CGPoint(x: 44, y: 20))
        arrow.addLine(to: CGPoint(x: 56, y: 20)); arrow.close()
        avatarHeading.path = arrow.cgPath; avatarHeading.fillColor = UIColor.white.withAlphaComponent(0.92).cgColor
        avatarHeading.shadowColor = UIColor.black.cgColor; avatarHeading.shadowOpacity = 0.8; avatarHeading.shadowRadius = 2
        avatarImage.frame = CGRect(x: 12, y: 15, width: 76, height: 76); avatarImage.contentMode = .scaleAspectFit
        avatarImage.isUserInteractionEnabled = false; avatarImage.isHidden = true
        layer.addSublayer(fan); layer.addSublayer(dot); layer.addSublayer(avatarHeading); addSubview(avatarImage)
        if let front = Self.asset("avatar_goku_nimbus"), let back = Self.asset("avatar_goku_nimbus_back") { images[.goku] = (front, back) }
        if let front = Self.asset("avatar_luffy"), let back = Self.asset("avatar_luffy_back") { images[.luffy] = (front, back) }
        accessibilityIdentifier = "native-live-rider"
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static func asset(_ name: String) -> UIImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Behavior/assets") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    func update(heading: Double?, mapBearing: Double, warm: Bool, avatar: RiderAvatarMode) {
        let relative = heading.map { DoorCameraGeometry.delta($0, mapBearing) } ?? 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let pair = images[avatar]
        let customAvailable: Bool
        if case .some = pair { customAvailable = true } else { customAvailable = false }
        let classic = avatar == .classic || !customAvailable
        fan.isHidden = classic ? heading == nil : true
        dot.isHidden = !classic
        avatarHeading.isHidden = classic || heading == nil
        avatarImage.isHidden = classic
        if let heading {
            let angle = CGFloat(DoorCameraGeometry.delta(heading, mapBearing) * .pi / 180)
            fan.setAffineTransform(CGAffineTransform(rotationAngle: angle))
            avatarHeading.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        }
        dot.opacity = warm ? 0.5 : 1
        avatarImage.alpha = warm ? 0.55 : 1
        CATransaction.commit()

        if !classic, let pair {
            let r = ((relative + 540).truncatingRemainder(dividingBy: 360)) - 180
            let ar = abs(r)
            let view: String, mirror: Bool, side: Double
            if ar <= 55 { view = "back"; mirror = r < 0; side = min(1, ar / 55) }
            else if ar >= 125 { view = "front"; mirror = r > 0; side = min(1, (180 - ar) / 55) }
            else { view = "side"; mirror = r < 0; side = 1 }
            avatarImage.image = view == "back" ? pair.back : pair.front
            let scale = view == "side" ? 0.68 : (1 - 0.12 * side)
            let lean = view == "side" ? (mirror ? -7.0 : 7.0) : (mirror ? -3 * side : 3 * side)
            avatarImage.transform = CGAffineTransform(scaleX: CGFloat(mirror ? -scale : scale), y: CGFloat(scale))
                .rotated(by: CGFloat(lean * .pi / 180))
            avatarImage.accessibilityValue = view
        } else {
            avatarImage.image = nil; avatarImage.transform = .identity
        }
        accessibilityLabel = warm ? "GPS 更新中" : avatar == .goku ? "悟空導航角色" : avatar == .luffy ? "魯夫導航角色" : "目前定位"
    }
}
