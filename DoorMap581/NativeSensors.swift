import CoreLocation
import Foundation

struct NativeSensorFix: Sendable {
    let coordinate: DoorCoordinate
    let accuracy: Double
    let speed: Double
    let course: Double?
    let timestamp: Date
    let warm: Bool
}

/// Foreground CoreLocation ownership is independent of every map gesture.
/// Uses existing when-in-use permission only; no background/Always capability.
@MainActor final class NativeSensors: NSObject, CLLocationManagerDelegate {
    private let manager: CLLocationManager?
    private var requested = false
    private var active = true
    private var lastLocation: CLLocation?
    private var locationRunning = false
    private var headingRunning = false
    private(set) var acceptedFixes = 0
    private(set) var acceptedHeadings = 0
    private(set) var status = "GPS 尚未取得"
    let simulated: Bool
    var onFix: ((NativeSensorFix) -> Void)?
    var onHeading: ((DoorHeadingFilter.Compass) -> Void)?
    var onStatus: ((String) -> Void)?

    init(simulated: Bool) {
        self.simulated = simulated
        manager = simulated ? nil : CLLocationManager()
        super.init()
        manager?.delegate = self
        manager?.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager?.activityType = .automotiveNavigation
        manager?.distanceFilter = 3
        manager?.headingFilter = kCLHeadingFilterNone
        manager?.pausesLocationUpdatesAutomatically = false
    }
    var isRunning: Bool { locationRunning }
    func start() {
        requested = true
        guard let manager else { changeStatus("模擬感測輸入（非手機驗收）"); return }
        let authorization = manager.authorizationStatus
        if authorization == .notDetermined { changeStatus("等待位置授權"); manager.requestWhenInUseAuthorization(); return }
        guard authorized(authorization), active else { reconcile(); return }
        emitWarmLocation()
        manager.requestLocation()
        reconcile()
    }
    func setActive(_ value: Bool) {
        let changed = value != active; active = value
        reconcile()
        if changed && value && requested { start() }
    }
    func setOrientation(_ value: CLDeviceOrientation) { manager?.headingOrientation = value }
    func stop() { requested = false; reconcile() }
    private func authorized(_ value: CLAuthorizationStatus) -> Bool {
        value == .authorizedWhenInUse || value == .authorizedAlways
    }
    private func changeStatus(_ value: String) { status = value; onStatus?(value) }
    private func reconcile() {
        guard let manager else { return }
        let permitted = authorized(manager.authorizationStatus)
        let wanted = active && requested && permitted
        if wanted != locationRunning {
            locationRunning = wanted
            if wanted { manager.startUpdatingLocation() } else { manager.stopUpdatingLocation() }
        }
        let headingWanted = wanted && CLLocationManager.headingAvailable()
        if headingWanted != headingRunning {
            headingRunning = headingWanted
            if headingWanted { manager.startUpdatingHeading() } else { manager.stopUpdatingHeading() }
        }
        if requested && !permitted {
            changeStatus(manager.authorizationStatus == .notDetermined ? "等待位置授權" : "位置未授權，請到 iOS 設定允許")
        }
    }
    private func emitWarmLocation() {
        guard active, let manager, authorized(manager.authorizationStatus),
              let fix = [manager.location, lastLocation].compactMap({ $0 })
                .filter({ SensorSamplePolicy.usableLocation($0, warm: true) })
                .max(by: { $0.timestamp < $1.timestamp }) else { return }
        emit(fix, warm: true)
    }
    private func emit(_ fix: CLLocation, warm: Bool) {
        let value = NativeSensorFix(coordinate: .init(lat: fix.coordinate.latitude, lng: fix.coordinate.longitude),
                                   accuracy: fix.horizontalAccuracy,
                                   speed: fix.speed.isFinite ? max(0, fix.speed) : 0,
                                   course: SensorSamplePolicy.course(fix), timestamp: fix.timestamp, warm: warm)
        onFix?(value)
    }
    /// Same acceptance path for genuine delegate samples and explicit DEBUG fixtures.
    func acceptLocations(_ locations: [CLLocation], now: Date = Date()) {
        guard active, let fix = locations.filter({ SensorSamplePolicy.usableLocation($0, now: now) })
            .max(by: { $0.timestamp < $1.timestamp }) else { return }
        guard lastLocation == nil || fix.timestamp > lastLocation!.timestamp else { return }
        lastLocation = fix; acceptedFixes += 1
        changeStatus("GPS \(Int(fix.horizontalAccuracy.rounded())) m")
        emit(fix, warm: false)
    }
    func acceptHeading(trueHeading: Double, magnetic: Double, accuracy: Double, timestamp: Date, now: Date = Date()) {
        guard active, let heading = SensorSamplePolicy.heading(trueHeading: trueHeading, magnetic: magnetic,
                                                               accuracy: accuracy, timestamp: timestamp, now: now) else { return }
        acceptedHeadings += 1
        onHeading?(.init(value: heading.value, timestampMS: timestamp.timeIntervalSince1970 * 1000,
                         accuracy: accuracy, source: heading.source))
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        reconcile()
        if requested && active && authorized(manager.authorizationStatus) { emitWarmLocation(); manager.requestLocation() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) { acceptLocations(locations) }
    func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        acceptHeading(trueHeading: heading.trueHeading, magnetic: heading.magneticHeading,
                      accuracy: heading.headingAccuracy, timestamp: heading.timestamp)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as NSError).code
        changeStatus(code == CLError.denied.rawValue ? "位置未授權，請到 iOS 設定允許" : "GPS 暫不可用，點定位重試")
    }
    func teardown() {
        stop(); manager?.delegate = nil; onFix = nil; onHeading = nil; onStatus = nil
    }
}
