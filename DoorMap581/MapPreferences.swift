import MapKit

enum MapAppearance: String, Codable, CaseIterable { case dark, light, system }
enum MiniMapMode: String, Codable, CaseIterable { case hidden, collapsed, expanded }
enum RiderAvatarMode: String, Codable, CaseIterable, Hashable { case classic, goku, luffy }

struct MapPreferences: Codable, Equatable {
    var appearance: MapAppearance = .dark
    var muted = false
    var showsPOI = true
    var allPOI = true
    var poiCategories = NativePOICategory.options.map(\.id)
    var traffic = false
    var buildings = true
    var zoomGestures = true
    var rotateGestures = true
    var pitchGestures = true
    var followHeading = false
    var pitch = 45.0
    var heading = 0.0
    var distance = 650.0
    var miniMode: MiniMapMode = .collapsed
    var stations = false
    var routeVisible = true
    // Optional fields keep older appletest backups decodable.
    var avatarMode: RiderAvatarMode? = nil
    var routeMemoryEnabled: Bool? = nil
    var avatar: RiderAvatarMode { avatarMode ?? .classic }
    var memoryEnabled: Bool { routeMemoryEnabled ?? true }

    static let key = "581.appletest.map.preferences.v1"
    static func load(_ defaults: UserDefaults = .standard) -> MapPreferences {
        guard let data = defaults.data(forKey: key),
              var value = try? JSONDecoder().decode(MapPreferences.self, from: data) else { return .init() }
        value.sanitize()
        return value
    }
    mutating func sanitize() {
        pitch = pitch.isFinite ? min(70, max(0, pitch)) : 45
        heading = heading.isFinite ? (heading.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) : 0
        distance = distance.isFinite ? min(2_000_000, max(80, distance)) : 650
        let ids = Set(NativePOICategory.options.map(\.id))
        poiCategories = Array(Set(poiCategories).intersection(ids)).sorted()
    }
    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
    var filter: MKPointOfInterestFilter {
        if !showsPOI { return .excludingAll }
        if allPOI { return .includingAll }
        return MKPointOfInterestFilter(including: NativePOICategory.options.filter { poiCategories.contains($0.id) }.map(\.category))
    }
}

struct NativePOICategory {
    let id: String
    let title: String
    let category: MKPointOfInterestCategory
    static let options: [NativePOICategory] = [
        .init(id: "restaurant", title: "餐廳", category: .restaurant),
        .init(id: "cafe", title: "咖啡店", category: .cafe),
        .init(id: "bakery", title: "麵包店", category: .bakery),
        .init(id: "foodMarket", title: "超市／食品", category: .foodMarket),
        .init(id: "store", title: "商店", category: .store),
        .init(id: "gasStation", title: "加油站", category: .gasStation),
        .init(id: "evCharger", title: "充電站", category: .evCharger),
        .init(id: "parking", title: "停車場", category: .parking),
        .init(id: "publicTransport", title: "公共交通", category: .publicTransport),
        .init(id: "airport", title: "機場", category: .airport),
        .init(id: "hotel", title: "住宿", category: .hotel),
        .init(id: "hospital", title: "醫院", category: .hospital),
        .init(id: "pharmacy", title: "藥局", category: .pharmacy),
        .init(id: "bank", title: "銀行", category: .bank),
        .init(id: "atm", title: "提款機", category: .atm),
        .init(id: "postOffice", title: "郵局", category: .postOffice),
        .init(id: "school", title: "學校", category: .school),
        .init(id: "university", title: "大學", category: .university),
        .init(id: "library", title: "圖書館", category: .library),
        .init(id: "park", title: "公園", category: .park),
        .init(id: "fitnessCenter", title: "健身", category: .fitnessCenter),
        .init(id: "museum", title: "博物館", category: .museum),
        .init(id: "movieTheater", title: "電影院", category: .movieTheater),
        .init(id: "theater", title: "劇院", category: .theater),
        .init(id: "nightlife", title: "夜生活", category: .nightlife),
        .init(id: "police", title: "警察", category: .police),
        .init(id: "fireStation", title: "消防", category: .fireStation),
        .init(id: "restroom", title: "洗手間", category: .restroom),
        .init(id: "laundry", title: "洗衣", category: .laundry),
        .init(id: "carRental", title: "租車", category: .carRental),
        .init(id: "beach", title: "海灘", category: .beach),
        .init(id: "campground", title: "露營", category: .campground),
        .init(id: "amusementPark", title: "遊樂園", category: .amusementPark),
        .init(id: "aquarium", title: "水族館", category: .aquarium),
        .init(id: "zoo", title: "動物園", category: .zoo),
        .init(id: "stadium", title: "體育場", category: .stadium),
        .init(id: "marina", title: "碼頭", category: .marina),
        .init(id: "winery", title: "酒莊", category: .winery),
        .init(id: "brewery", title: "釀酒廠", category: .brewery),
        .init(id: "nationalPark", title: "國家公園", category: .nationalPark)
    ]
}

struct SavedDestination: Codable {
    var latitude: Double
    var longitude: Double
    var title: String
    var manuallyCorrected: Bool
    static let key = "581.appletest.manual.destination.v1"
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    func save() {
        // Only device-entered/manual coordinates persist. Apple search items do not.
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
    static func load() -> SavedDestination? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              CLLocationCoordinate2DIsValid(value.coordinate) else { return nil }
        return value
    }
}
