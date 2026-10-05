import Foundation

struct NativePersonalSnapshot: Codable, Equatable {
    static let schemaVersion = 1
    static let kindValue = "door581-appletest-personal"
    var schema = schemaVersion
    var kind = kindValue
    var savedAt: Double
    var preferences: MapPreferences
    var avoidAreas: [DoorAvoidArea]
    var routeMemories: [DoorRouteMemory]

    init(savedAt: Double = Date().timeIntervalSince1970 * 1000,
         preferences: MapPreferences = .init(),
         avoidAreas: [DoorAvoidArea] = [],
         routeMemories: [DoorRouteMemory] = []) {
        self.savedAt = savedAt; self.preferences = preferences; self.avoidAreas = avoidAreas; self.routeMemories = routeMemories
    }
}

actor NativePersonalStore {
    static let maxBackupBytes = 2_500_000
    private let root: URL
    private let fm = FileManager.default
    private var activeURL: URL { root.appendingPathComponent("personal.json") }
    private var previousURL: URL { root.appendingPathComponent("personal.previous.json") }
    private var latestBackupURL: URL { root.appendingPathComponent("backup-latest.json") }

    init(root: URL) throws {
        guard root.isFileURL, !root.path.isEmpty, root.path != "/" else { throw DoorPersonalError.storageFailure }
        self.root = root.standardizedFileURL
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
    }
    static func makeForTestApp() throws -> NativePersonalStore {
        guard Bundle.main.bundleIdentifier == "com.door581.appletest" else { throw DoorPersonalError.storageFailure }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return try NativePersonalStore(root: support.appendingPathComponent("581-AppleTest-Native/v1/personal", isDirectory: true))
    }
    private func validated(_ snapshot: NativePersonalSnapshot) throws -> NativePersonalSnapshot {
        guard snapshot.schema == NativePersonalSnapshot.schemaVersion,
              snapshot.kind == NativePersonalSnapshot.kindValue,
              snapshot.savedAt.isFinite, snapshot.savedAt >= 0 else { throw DoorPersonalError.invalidBackup }
        var result = snapshot
        var prefs = result.preferences; prefs.sanitize(); result.preferences = prefs
        result.avoidAreas = DoorDeliveryCore.sanitizeAreas(result.avoidAreas)
        guard result.avoidAreas.count <= DoorDeliveryCore.maxAreas else { throw DoorPersonalError.invalidBackup }
        result.routeMemories = try DoorPlannedMemory.sanitize(result.routeMemories, nowMS: Date().timeIntervalSince1970 * 1000)
        guard result.routeMemories.count <= DoorPlannedMemory.maxMemories else { throw DoorPersonalError.invalidBackup }
        return result
    }
    private func encode(_ snapshot: NativePersonalSnapshot) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maxBackupBytes else { throw DoorPersonalError.tooLarge }
        return data
    }
    func load(defaultPreferences: MapPreferences = .init()) throws -> NativePersonalSnapshot {
        guard fm.fileExists(atPath: activeURL.path) else { return .init(preferences: defaultPreferences) }
        let data = try Data(contentsOf: activeURL)
        guard data.count <= Self.maxBackupBytes,
              let decoded = try? JSONDecoder().decode(NativePersonalSnapshot.self, from: data) else { throw DoorPersonalError.invalidBackup }
        return try validated(decoded)
    }
    @discardableResult func save(_ snapshot: NativePersonalSnapshot) throws -> NativePersonalSnapshot {
        var normalized = try validated(snapshot); normalized.savedAt = Date().timeIntervalSince1970 * 1000
        let data = try encode(normalized)
        if fm.fileExists(atPath: activeURL.path) {
            let old = try Data(contentsOf: activeURL)
            if old.count <= Self.maxBackupBytes { try old.write(to: previousURL, options: .atomic) }
        }
        try data.write(to: activeURL, options: .atomic)
        try data.write(to: latestBackupURL, options: .atomic)
        return normalized
    }
    func exportData(_ snapshot: NativePersonalSnapshot) throws -> Data {
        var normalized = try validated(snapshot); normalized.savedAt = Date().timeIntervalSince1970 * 1000
        return try encode(normalized)
    }
    @discardableResult func importData(_ data: Data) throws -> NativePersonalSnapshot {
        guard data.count <= Self.maxBackupBytes,
              let decoded = try? JSONDecoder().decode(NativePersonalSnapshot.self, from: data) else {
            throw data.count > Self.maxBackupBytes ? DoorPersonalError.tooLarge : DoorPersonalError.invalidBackup
        }
        return try save(validated(decoded))
    }
    func rollback() throws -> NativePersonalSnapshot? {
        guard fm.fileExists(atPath: previousURL.path) else { return nil }
        let data = try Data(contentsOf: previousURL)
        guard data.count <= Self.maxBackupBytes,
              let decoded = try? JSONDecoder().decode(NativePersonalSnapshot.self, from: data) else { throw DoorPersonalError.invalidBackup }
        let normalized = try validated(decoded), encoded = try encode(normalized)
        try encoded.write(to: activeURL, options: .atomic)
        return normalized
    }
}
