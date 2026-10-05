import Foundation

/// Public-data seed only. Apple search responses/tiles are never included here.
struct NativeSeedBundle: Sendable {
    struct Decoded: Decodable, Sendable { let bytes: Int; let sha256: String }
    private struct Catalog: Decodable {
        let schema: Int
        let manifest: DoorOfflineManifest
        let decoded: [String: Decoded]
    }
    let root: URL
    let manifest: DoorOfflineManifest
    let decoded: [String: Decoded]
    private let entries: [String: DoorOfflineManifest.File]

    init(bundle: Bundle) throws {
        guard let root = bundle.url(forResource: "Behavior", withExtension: nil),
              let catalogURL = bundle.url(forResource: "seed-catalog", withExtension: "json", subdirectory: "NativeData") else {
            throw DoorOfflineError.missingFile("native seed catalog")
        }
        let bytes = try Data(contentsOf: catalogURL)
        guard bytes.count < 4 * 1024 * 1024, DoorDigest.sha256(bytes) == NativeSeedIdentity.catalogSHA256 else {
            throw DoorOfflineError.untrustedManifest
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: bytes)
        try catalog.manifest.validate()
        guard catalog.schema == 1, try catalog.manifest.identity == NativeSeedIdentity.manifestSHA256,
              catalog.manifest.files.count == NativeSeedIdentity.fileCount,
              catalog.decoded.count == catalog.manifest.files.count,
              catalog.manifest.files.reduce(Int64(0), { $0 + $1.bytes }) == NativeSeedIdentity.storedBytes else {
            throw DoorOfflineError.invalidManifest
        }
        for file in catalog.manifest.files {
            guard file.path.hasSuffix(".gz"), let value = catalog.decoded[String(file.path.dropLast(3))],
                  value.bytes >= 0, value.bytes <= 128 * 1024 * 1024, value.sha256.count == 64 else {
                throw DoorOfflineError.invalidManifest
            }
        }
        self.root = root.standardizedFileURL
        manifest = catalog.manifest; decoded = catalog.decoded
        entries = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
    }
    func encoded(_ path: String) throws -> Data {
        guard DoorOfflineManifest.safePath(path), let entry = entries[path] else { throw DoorOfflineError.unsafePath }
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw DoorOfflineError.unsafePath }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard Int64(data.count) == entry.bytes else { throw DoorOfflineError.size(path) }
        guard DoorDigest.sha256(data) == entry.sha256 else { throw DoorOfflineError.checksum(path) }
        return data
    }
    func decode(_ data: Data, path: String) throws -> Data {
        guard let expected = decoded[path] else { throw DoorOfflineError.missingFile(path) }
        let bytes = try NativeGzip.decode(data)
        guard bytes.count == expected.bytes else { throw DoorOfflineError.size(path) }
        guard DoorDigest.sha256(bytes) == expected.sha256 else { throw DoorOfflineError.checksum(path) }
        return bytes
    }
    func encodeValidatedDecoded(_ data: Data, path: String) throws -> Data {
        guard DoorOfflineManifest.safePath(path), let expected = decoded[path], let stored = entries[path + ".gz"] else {
            throw DoorOfflineError.missingFile(path)
        }
        guard data.count == expected.bytes else { throw DoorOfflineError.size(path) }
        guard DoorDigest.sha256(data) == expected.sha256 else { throw DoorOfflineError.checksum(path) }
        let encoded = try NativeGzip.encodeDeterministic(data)
        guard Int64(encoded.count) == stored.bytes else { throw DoorOfflineError.size(stored.path) }
        guard DoorDigest.sha256(encoded) == stored.sha256 else { throw DoorOfflineError.checksum(stored.path) }
        return encoded
    }
}

/// Single native data reader/installer. No loopback HTTP, WKWebView, or IDB.
/// The build8 UI is not switched to this until its native replacement is ready.
actor NativePublicResources {
    private let seed: NativeSeedBundle
    private let offline: DoorOfflineStore
    private let offlineRoot: URL
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    private var retainedBytes = 0
    private var cacheGeneration: String?
    static let decodedCacheBudget = 12 * 1024 * 1024

    init(seed: NativeSeedBundle, offlineRoot: URL) throws {
        self.seed = seed; self.offlineRoot = offlineRoot
        offline = try DoorOfflineStore(root: offlineRoot)
    }
    static func makeForTestApp(bundle: Bundle = .main) throws -> NativePublicResources {
        guard bundle.bundleIdentifier == "com.door581.appletest" else { throw DoorOfflineError.unsafePath }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("581-AppleTest-Native/v1/offline", isDirectory: true)
        return try NativePublicResources(seed: NativeSeedBundle(bundle: bundle), offlineRoot: root)
    }
    func receipt() async throws -> DoorOfflineReceipt? { try await offline.activeReceipt() }
    func verifyInstalled() async throws -> DoorOfflineReceipt? { try await offline.verifyActivePackage() }
    func cancelInstallation() async { await offline.cancelInstall() }
    func releaseDisposableCaches() { cache.removeAll(); order.removeAll(); retainedBytes = 0 }
    var cacheBytes: Int { retainedBytes }
    var seedFileCount: Int { seed.manifest.files.count }
    var seedComponents: [String] { seed.manifest.requiredComponents }

    /// This is an installation of bundled data, not a falsely reported download.
    func installBundledSeed(progress: (@Sendable (DoorOfflineStore.Status) -> Void)? = nil) async throws -> DoorOfflineReceipt {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: offlineRoot.path)
        guard let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else {
            throw DoorOfflineError.insufficientSpace
        }
        let seed = self.seed
        let receipt = try await offline.install(seed.manifest, trustedManifestSHA256: NativeSeedIdentity.manifestSHA256,
                                               origin: "bundled-seed", availableBytes: available,
                                               load: { file in try seed.encoded(file.path) }, progress: progress)
        releaseDisposableCaches(); cacheGeneration = receipt.generation
        return receipt
    }

    @discardableResult func removeInstalledCopy() async throws -> DoorOfflineReceipt? {
        let removed = try await offline.deleteInstalledCopy()
        releaseDisposableCaches(); cacheGeneration = nil
        return removed
    }

    /// Downloads only resources that already exist on the accepted Door Map public origin.
    /// App-specific derived indices remain the verified bundled bytes. Every downloaded
    /// decoded hash and the deterministic gzip hash must match the pinned build8 catalog.
    func installValidatedNetworkSeed(baseURL: URL = AppConfig.liveBaseURL,
                                     progress: (@Sendable (DoorOfflineStore.Status) -> Void)? = nil) async throws -> DoorOfflineReceipt {
        guard baseURL.scheme?.lowercased() == "https", baseURL.user == nil, baseURL.password == nil,
              baseURL.port == nil || baseURL.port == 443,
              baseURL.host?.lowercased() == AppConfig.liveBaseURL.host?.lowercased() else {
            throw DoorOfflineError.untrustedManifest
        }
        return try await installValidatedDownload(progress: progress) { path in
            var url = baseURL
            for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw DoorOfflineError.network((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            guard data.count <= 128 * 1024 * 1024 else { throw DoorOfflineError.invalidManifest }
            return data
        }
    }

    func installValidatedDownload(progress: (@Sendable (DoorOfflineStore.Status) -> Void)? = nil,
                                  fetch: @escaping @Sendable (String) async throws -> Data) async throws -> DoorOfflineReceipt {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: offlineRoot.path)
        guard let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else { throw DoorOfflineError.insufficientSpace }
        let seed = self.seed
        let remoteComponents: Set<String> = [
            "taichung-community-1150630-v1", "taichung-community-1150630-v2",
            "taichung-destination-v2", "taichung-official-202608-v1",
            "taichung-prebuilt", "taichung_sources.json"
        ]
        let receipt = try await offline.install(seed.manifest, trustedManifestSHA256: NativeSeedIdentity.manifestSHA256,
                                               origin: "validated-download", availableBytes: available,
                                               load: { file in
            guard remoteComponents.contains(file.component) else { return try seed.encoded(file.path) }
            guard file.path.hasSuffix(".gz") else { throw DoorOfflineError.invalidManifest }
            let decodedPath = String(file.path.dropLast(3))
            let raw = try await fetch(decodedPath)
            return try seed.encodeValidatedDecoded(raw, path: decodedPath)
        }, progress: progress)
        releaseDisposableCaches(); cacheGeneration = receipt.generation
        return receipt
    }

    func data(_ path: String) async throws -> Data {
        guard DoorOfflineManifest.safePath(path), seed.decoded[path] != nil else { throw DoorOfflineError.unsafePath }
        let active = try await offline.activeReceipt()
        let generation = active?.generation ?? "bundled-seed"
        // A future downloaded catalog must be explicitly trusted before activation.
        guard active == nil || active?.manifestSHA256 == NativeSeedIdentity.manifestSHA256 else {
            throw DoorOfflineError.untrustedManifest
        }
        if cacheGeneration != generation { releaseDisposableCaches(); cacheGeneration = generation }
        if let cached = cache[path] {
            order.removeAll { $0 == path }; order.append(path); return cached
        }
        let encoded: Data
        if let activeURL = try await offline.validatedResource(path + ".gz") {
            encoded = try Data(contentsOf: activeURL, options: .mappedIfSafe)
        } else { encoded = try seed.encoded(path + ".gz") }
        let bytes = try seed.decode(encoded, path: path)
        if bytes.count <= Self.decodedCacheBudget {
            while retainedBytes + bytes.count > Self.decodedCacheBudget || cache.count >= 2 {
                guard let first = order.first else { break }; order.removeFirst()
                if let prior = cache.removeValue(forKey: first) { retainedBytes -= prior.count }
            }
            cache[path] = bytes; order.append(path); retainedBytes += bytes.count
        }
        return bytes
    }
    func searchIndex() async throws -> DoorSearchIndex {
        let bytes = try await data("offline/taichung-prebuilt/search-index.json")
        let index = try JSONDecoder().decode(DoorSearchIndex.self, from: bytes)
        guard index.version == "tcg-search-202609-v4-master-r2", index.rowCount == 38950 else {
            throw DoorOfflineError.invalidManifest
        }
        return index
    }
}
