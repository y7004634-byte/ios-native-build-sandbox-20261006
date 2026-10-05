import Foundation

struct NativePowerSnapshot: Sendable, Equatable {
    let running: Bool
    let reason: String
    let durationMS: Double
    let foregroundMS: Double
    let remainingMS: Double
    let counts: [NativePowerWorkload.Key: Int64]

    func count(_ key: NativePowerWorkload.Key) -> Int64 { counts[key] ?? 0 }

    var reportText: String {
        let minutes = max(durationMS / 60_000, 0.001)
        func rate(_ key: NativePowerWorkload.Key) -> String {
            let value = Double(count(key)) / minutes
            return String(format: value < 10 ? "%.1f/分" : "%.0f/分", value)
        }
        var lines = [
            "581 5 分鐘運算／耗電診斷" + (running ? "（進行中）" : ""),
            String(format: "時間 %.1f 分 · 前景 %.1f 分", durationMS / 60_000, foregroundMS / 60_000),
            "GPS \(count(.gps))（\(rate(.gps))） · 方向感測 \(count(.heading))（\(rate(.heading))）",
            "地圖移動 \(count(.mapMove))（\(rate(.mapMove))） · 相機套用 \(count(.cameraApply)) · FIT 評估 \(count(.fitEvaluate))",
            "圖層更新 \(count(.layerRefresh)) · 路線請求 \(count(.routeRequest)) · 搜尋更新 \(count(.searchRefresh))",
            "已知網路請求 \(count(.networkRequest)) · 站點更新 \(count(.stationRefresh))"
        ]
        var hotspots: [String] = []
        if Double(count(.mapMove)) / minutes > 300 { hotspots.append("地圖更新偏高") }
        if Double(count(.layerRefresh)) / minutes > 180 { hotspots.append("圖層重建偏高") }
        if Double(count(.routeRequest)) / minutes > 3 { hotspots.append("路線重算偏高") }
        if Double(count(.networkRequest)) / minutes > 45 { hotspots.append("網路請求偏高") }
        lines.append(hotspots.isEmpty ? "高負載線索：目前計數沒有明顯失控項目" : "高負載線索：" + hotspots.joined(separator: "、"))
        lines.append("iPhone 無可靠溫度／瓦數權限；本報告只代表 Door Map 工作量，不含 GPS 座標也不會上傳。")
        return lines.joined(separator: "\n")
    }
}

struct NativePowerWorkload: Sendable {
    enum Key: String, CaseIterable, Sendable, Hashable {
        case gps, heading, mapMove, cameraApply, fitEvaluate, layerRefresh
        case routeRequest, searchRefresh, networkRequest, stationRefresh
    }
    private(set) var running = false
    private(set) var startMS = 0.0
    private(set) var durationMS = 300_000.0
    private(set) var foregroundMS = 0.0
    private(set) var lastVisibilityMS = 0.0
    private(set) var foreground = true
    private(set) var counts = Dictionary(uniqueKeysWithValues: Key.allCases.map { ($0, Int64(0)) })

    mutating func start(at nowMS: Double, durationMS: Double = 300_000, foreground: Bool = true) {
        self.running = true; startMS = nowMS
        self.durationMS = min(900_000, max(60_000, durationMS))
        foregroundMS = 0; lastVisibilityMS = nowMS; self.foreground = foreground
        counts = Dictionary(uniqueKeysWithValues: Key.allCases.map { ($0, Int64(0)) })
    }
    mutating func mark(_ key: Key, _ amount: Int64 = 1) {
        guard running, amount >= 0 else { return }
        counts[key, default: 0] &+= amount
    }
    mutating func setForeground(_ value: Bool, at nowMS: Double) {
        updateForeground(at: nowMS); foreground = value
    }
    mutating func snapshot(at nowMS: Double, reason: String = "") -> NativePowerSnapshot {
        updateForeground(at: nowMS)
        let elapsed = max(0, nowMS - startMS)
        return .init(running: running, reason: reason, durationMS: elapsed, foregroundMS: foregroundMS,
                     remainingMS: max(0, durationMS - elapsed), counts: counts)
    }
    mutating func shouldFinish(at nowMS: Double) -> Bool { running && max(0, nowMS - startMS) >= durationMS }
    mutating func stop(at nowMS: Double, reason: String) -> NativePowerSnapshot {
        let value = snapshot(at: nowMS, reason: reason); running = false
        return .init(running: false, reason: reason, durationMS: value.durationMS, foregroundMS: value.foregroundMS,
                     remainingMS: 0, counts: value.counts)
    }
    private mutating func updateForeground(at nowMS: Double) {
        if running && foreground { foregroundMS += max(0, nowMS - lastVisibilityMS) }
        lastVisibilityMS = nowMS
    }
}

@MainActor final class NativePowerDiagnostic {
    private var workload = NativePowerWorkload()
    private var timer: Timer?
    private(set) var lastReport: NativePowerSnapshot?
    var onChange: ((NativePowerSnapshot) -> Void)?
    var active: Bool { workload.running }

    private var nowMS: Double { ProcessInfo.processInfo.systemUptime * 1000 }

    func start(durationMS: Double = 300_000, foreground: Bool = true) {
        stop(reason: "restart")
        workload.start(at: nowMS, durationMS: durationMS, foreground: foreground)
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer.tolerance = 0.15; self.timer = timer
        onChange?(workload.snapshot(at: nowMS))
    }

    func mark(_ key: NativePowerWorkload.Key, _ amount: Int64 = 1) { workload.mark(key, amount) }

    func setForeground(_ value: Bool) {
        guard workload.running else { return }
        workload.setForeground(value, at: nowMS); onChange?(workload.snapshot(at: nowMS))
    }

    @discardableResult func stop(reason: String = "manual") -> NativePowerSnapshot? {
        timer?.invalidate(); timer = nil
        guard workload.running else { return lastReport }
        let report = workload.stop(at: nowMS, reason: reason); lastReport = report; onChange?(report); return report
    }

    func snapshot() -> NativePowerSnapshot? {
        workload.running ? workload.snapshot(at: nowMS) : lastReport
    }

    private func tick() {
        guard workload.running else { return }
        if workload.shouldFinish(at: nowMS) { _ = stop(reason: "complete") }
        else { onChange?(workload.snapshot(at: nowMS)) }
    }

    deinit { timer?.invalidate() }
}
