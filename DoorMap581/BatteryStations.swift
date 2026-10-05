import MapKit

struct BatteryStation: Codable {
    let id: String
    let lat: Double
    let lng: Double
    let name: String
    let address: String?
    let unavailable: Bool?
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    var valid: Bool { lat.isFinite && lng.isFinite && (20...27).contains(lat) && (117...123).contains(lng) && !id.isEmpty && !name.isEmpty }
}
struct BatteryStationSnapshot: Codable {
    let stations: [BatteryStation]
    let fetchedAt: Double
    let source: String
    let attribution: String?
    let stale: Bool?
    func validated() throws -> BatteryStationSnapshot {
        guard !stations.isEmpty, stations.count <= 15000, fetchedAt.isFinite,
              stations.allSatisfy(\.valid), Set(stations.map(\.id)).count == stations.count else { throw StationError.invalid }
        return self
    }
    enum StationError: Error { case invalid }
}
final class BatteryStationAnnotation: NSObject, MKAnnotation {
    let station: BatteryStation
    var coordinate: CLLocationCoordinate2D { station.coordinate }
    var title: String? { station.name }
    var subtitle: String? { station.address }
    init(_ station: BatteryStation) { self.station = station }
}

final class BatteryStationStore {
    private var task: URLSessionDataTask?
    private var generation = UUID()
    private let cacheKey = "581.appletest.station.positions.v1"
    private(set) var snapshot: BatteryStationSnapshot?
    var onChange: ((BatteryStationSnapshot?, String) -> Void)?
    func cancel() { generation = UUID(); task?.cancel(); task = nil }
    func load(force: Bool = false) {
        cancel()
        let token = generation
        if snapshot == nil {
            if let data = UserDefaults.standard.data(forKey: cacheKey),
               let value = try? JSONDecoder().decode(BatteryStationSnapshot.self, from: data),
               let valid = try? value.validated() { snapshot = valid }
            else if let url = Bundle.main.url(forResource: "battery-stations-fallback", withExtension: "json"),
                    let data = try? Data(contentsOf: url),
                    let value = try? JSONDecoder().decode(BatteryStationSnapshot.self, from: data),
                    let valid = try? value.validated() { snapshot = valid }
        }
        publish(message: "")
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOOR_UI_STATION_OFFLINE"] == "1" { return }
        #endif
        if !force, let snapshot, snapshot.source.hasPrefix("https://official-site-pro.gogoroapp.com/"),
           Date().timeIntervalSince1970 * 1000 - snapshot.fetchedAt < 6 * 3600000 { return }
        var request = URLRequest(url: AppConfig.liveBaseURL.appendingPathComponent("api/gogoro-stations"))
        request.timeoutInterval = 15
        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let value: BatteryStationSnapshot? = {
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                      let data, data.count < 8_000_000,
                      let value = try? JSONDecoder().decode(BatteryStationSnapshot.self, from: data) else { return nil }
                return try? value.validated()
            }()
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.task = nil
                if let value {
                    self.snapshot = value
                    if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: self.cacheKey) }
                    self.publish(message: "")
                } else { self.publish(message: "官方更新暫不可用；顯示已保存位置") }
            }
        }
        task?.resume()
    }
    private func publish(message: String) {
        guard let snapshot else { onChange?(nil, "站點暫不可用，可在更多設定重試"); return }
        let date = Date(timeIntervalSince1970: snapshot.fetchedAt / 1000)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
        let source = snapshot.source.hasPrefix("https://official-site-pro.gogoroapp.com/") ? "Gogoro 公開站點" : "OSM 已保存交換站・部分範圍"
        onChange?(snapshot, "\(source) · \(formatter.string(from: date)) · \(snapshot.stations.count) 站\(message.isEmpty ? "" : "\n" + message)\n不含即時電池量或營運保證")
    }
}
