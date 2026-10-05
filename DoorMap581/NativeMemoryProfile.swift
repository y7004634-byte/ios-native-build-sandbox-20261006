import CryptoKit
import Darwin
import Foundation
import MapKit
import WebKit

/// Simulator-only observation. No location history, production IPC or private SDK API.
enum NativeMemoryProfile {
    static let enabled: Bool = {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["DOOR_MEMORY_PROFILE"] == "1"
        #else
        return false
        #endif
    }()
    private static let controllers = NSHashTable<AnyObject>.weakObjects()
    private static let maps = NSHashTable<AnyObject>.weakObjects()
    private static let webViews = NSHashTable<AnyObject>.weakObjects()
    static func register(controller: AnyObject, map: MKMapView, webView: WKWebView) {
        guard enabled else { return }
        controllers.add(controller); maps.add(map); webViews.add(webView)
    }
    static func digest(_ object: Any) -> String {
        guard enabled, let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func process() -> [String: Any] {
        var basic = mach_task_basic_info(), basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let basicResult = withUnsafeMutablePointer(to: &basic) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount) }
        }
        var vm = task_vm_info(), vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount) }
        }
        var result: [String: Any] = ["pid": Int(getpid()), "basicStatus": Int(basicResult), "vmStatus": Int(vmResult)]
        if basicResult == KERN_SUCCESS { result["residentBytes"] = basic.resident_size; result["virtualBytes"] = basic.virtual_size }
        if vmResult == KERN_SUCCESS { result["physicalFootprintBytes"] = vm.phys_footprint; result["internalBytes"] = vm.internal; result["compressedBytes"] = vm.compressed }
        return result
    }
    static func write(_ fields: [String: Any]) {
        guard enabled else { return }
        var result = fields
        result["timestamp"] = Date().timeIntervalSince1970
        result["process"] = process()
        result["liveInstances"] = ["controllers": controllers.allObjects.count, "maps": maps.allObjects.count, "webViews": webViews.allObjects.count]
        result["scope"] = "Native task metrics; host observer measures isolated simulator WebKit services separately"
        guard let bytes = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys),
              let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? bytes.write(to: directory.appendingPathComponent("door581-memory-profile.json"), options: .atomic)
    }
}

/// Small counters can be read by the UI without waiting for a large server parse.
final class NativeServerMemoryCounters {
    private let lock = NSLock()
    private var values: [String: Double] = [:]
    func add(_ key: String, _ value: Double) {
        guard NativeMemoryProfile.enabled else { return }
        lock.lock(); values[key, default: 0] += value; lock.unlock()
    }
    func maximum(_ key: String, _ value: Double) {
        guard NativeMemoryProfile.enabled else { return }
        lock.lock(); values[key] = max(values[key, default: 0], value); lock.unlock()
    }
    func set(_ key: String, _ value: Double) {
        guard NativeMemoryProfile.enabled else { return }
        lock.lock(); values[key] = value; lock.unlock()
    }
    func snapshot() -> [String: Double] { lock.lock(); defer { lock.unlock() }; return values }
}
