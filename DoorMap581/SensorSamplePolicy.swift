import CoreLocation
import Foundation

enum SensorSamplePolicy {
    static func usableLocation(_ fix: CLLocation, now: Date = Date(), warm: Bool = false) -> Bool {
        let age = now.timeIntervalSince(fix.timestamp)
        return CLLocationCoordinate2DIsValid(fix.coordinate)
            && fix.horizontalAccuracy.isFinite && fix.horizontalAccuracy >= 0
            && age >= -2 && age <= (warm ? 15 : 20)
            && (!warm || fix.horizontalAccuracy <= 80)
    }
    static func heading(trueHeading: Double, magnetic: Double, accuracy: Double, timestamp: Date, now: Date = Date()) -> (value: Double, source: String)? {
        let age = now.timeIntervalSince(timestamp)
        guard accuracy.isFinite, accuracy >= 0, accuracy <= 60, age >= -2, age < 2.5 else { return nil }
        if trueHeading.isFinite && trueHeading >= 0 && trueHeading < 360 { return (trueHeading, "true-heading") }
        if magnetic.isFinite && magnetic >= 0 && magnetic < 360 { return (magnetic, "magnetic-heading") }
        return nil
    }
    static func course(_ fix: CLLocation) -> Double? {
        guard fix.course.isFinite, fix.course >= 0, fix.course < 360,
              fix.speed.isFinite, fix.speed >= 1.2, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 65 else { return nil }
        if #available(iOS 13.4, *), !fix.courseAccuracy.isFinite || fix.courseAccuracy < 0 || fix.courseAccuracy > 60 { return nil }
        return fix.course
    }
}
