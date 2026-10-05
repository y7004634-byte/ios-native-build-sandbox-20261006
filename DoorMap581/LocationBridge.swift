import CoreLocation
import Foundation
import WebKit

final class LocationBridge: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var pendingOneShot = false
    private var continuousLocationRequested = false
    private var appActive = true
    private var lastGoodLocation: CLLocation?
    private var lastGoodHeading: CLHeading?
    private var locationRunning = false
    private var headingRunning = false
    weak var webView: WKWebView?
    var onLocation: ((CLLocation) -> Void)?
    var onHeading: ((Double) -> Void)?
    var onAuthorization: ((CLAuthorizationStatus) -> Void)?
    var onError: ((String) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = 3
        // Camera ownership never owns or suspends the foreground sensor stream.
        manager.pausesLocationUpdatesAutomatically = false
        manager.headingFilter = kCLHeadingFilterNone
    }
    func requestOneShot() {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            pendingOneShot = true
            manager.requestWhenInUseAuthorization()
            return
        }
        guard authorized(status), appActive else { emitAuthorization(status); return }
        emitWarmLocationIfAvailable()
        manager.requestLocation()
        reconcile()
    }
    func setContinuousLocationEnabled(_ enabled: Bool) {
        continuousLocationRequested = enabled
        if enabled {
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
            emitWarmLocationIfAvailable()
        }
        reconcile()
    }
    func setAppActive(_ active: Bool) {
        appActive = active
        if active && continuousLocationRequested { emitWarmLocationIfAvailable() }
        reconcile()
    }
    func setHeadingOrientation(_ orientation: CLDeviceOrientation) { manager.headingOrientation = orientation }
    func replayFreshSamples() {
        if let fix=lastGoodLocation,SensorSamplePolicy.usableLocation(fix){emitLocation(fix,warm:false)}
        else{emitWarmLocationIfAvailable()}
        if let heading=lastGoodHeading,let value=SensorSamplePolicy.heading(trueHeading:heading.trueHeading,magnetic:heading.magneticHeading,accuracy:heading.headingAccuracy,timestamp:heading.timestamp){emit("door581:nativeHeading",["heading":value.value,"source":value.source,"accuracy":heading.headingAccuracy,"timestamp":heading.timestamp.timeIntervalSince1970*1000])}
    }
    private func authorized(_ status: CLAuthorizationStatus) -> Bool { status == .authorizedWhenInUse || status == .authorizedAlways }
    private func reconcile() {
        let active = appActive && authorized(manager.authorizationStatus)
        let locationWanted = active && continuousLocationRequested
        if locationWanted != locationRunning {
            locationRunning = locationWanted
            if locationWanted { manager.startUpdatingLocation() } else { manager.stopUpdatingLocation() }
        }
        let headingWanted = active && CLLocationManager.headingAvailable()
        if headingWanted != headingRunning {
            headingRunning = headingWanted
            if headingWanted { manager.startUpdatingHeading() } else { manager.stopUpdatingHeading() }
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        emitAuthorization(status)
        if pendingOneShot && authorized(status) && appActive {
            pendingOneShot = false
            emitWarmLocationIfAvailable()
            manager.requestLocation()
        }
        reconcile()
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard appActive, let fix = locations.filter({ SensorSamplePolicy.usableLocation($0) }).max(by: { $0.timestamp < $1.timestamp }) else { return }
        if let old = lastGoodLocation, fix.timestamp <= old.timestamp { return }
        lastGoodLocation = fix
        emitLocation(fix, warm: false)
        onLocation?(fix)
    }
    func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        guard appActive, let value = SensorSamplePolicy.heading(trueHeading: heading.trueHeading, magnetic: heading.magneticHeading, accuracy: heading.headingAccuracy, timestamp: heading.timestamp) else { return }
        lastGoodHeading=heading
        onHeading?(value.value)
        emit("door581:nativeHeading", ["heading": value.value, "source": value.source,
              "accuracy": heading.headingAccuracy, "timestamp": heading.timestamp.timeIntervalSince1970 * 1000])
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let ns = error as NSError
        let code = ns.domain == kCLErrorDomain && ns.code == CLError.denied.rawValue ? 1 : 2
        onError?(error.localizedDescription)
        emit("door581:nativeLocationError", ["code": code, "message": error.localizedDescription])
    }
    private func emitAuthorization(_ status: CLAuthorizationStatus) {
        onAuthorization?(status)
        emit("door581:nativeLocationAuthorization", ["status": status.rawValue])
    }
    private func emitWarmLocationIfAvailable() {
        guard appActive, authorized(manager.authorizationStatus),
              let fix = [manager.location, lastGoodLocation].compactMap({ $0 })
                .filter({ SensorSamplePolicy.usableLocation($0, warm: true) })
                .max(by: { $0.timestamp < $1.timestamp }) else { return }
        emitLocation(fix, warm: true)
    }
    private func emitLocation(_ fix: CLLocation, warm: Bool) {
        emit("door581:nativeLocation", ["latitude": fix.coordinate.latitude,
             "longitude": fix.coordinate.longitude, "accuracy": fix.horizontalAccuracy,
             "speed": fix.speed >= 0 ? fix.speed : NSNull(),
             "heading": SensorSamplePolicy.course(fix) as Any? ?? NSNull(),
             "timestamp": fix.timestamp.timeIntervalSince1970 * 1000, "warmStart": warm])
    }
    private func emit(_ event: String, _ detail: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(detail), let data = try? JSONSerialization.data(withJSONObject: detail),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak webView] in webView?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('\(event)',{detail:\(json)}));") }
    }
}
