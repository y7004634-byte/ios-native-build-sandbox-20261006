import CryptoKit
import Foundation
import Network

/// App-internal loopback delivery keeps the accepted web storage/worker contracts.
/// It never binds to LAN, exposes arbitrary files, or accepts an arbitrary proxy URL.
final class NativeBundleServer {
    static let port: UInt16 = 58138
    static let origin = URL(string: "http://127.0.0.1:\(port)/")!
    private var boundPort: UInt16
    private var originURL: URL { URL(string:"http://127.0.0.1:\(boundPort)/")! }
    private let queue = DispatchQueue(label: "581.accepted.bundle.server", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private struct RawOSMFile { let bytes: Data; let sha256: String }
    private var osmRawFiles: [String: RawOSMFile] = [:]
    private var osmRawOrder: [String] = []
    private(set) var retainedOsmRawBytes = 0
    static let osmRawCacheBudget = 12 * 1024 * 1024
    private var osmIndex: [String: [[String: Any]]]?
    let memoryCounters = NativeServerMemoryCounters()
    private let bundleRoot: URL
    let simulated: Bool
    init(bundleRoot: URL, simulated: Bool = false, port: UInt16 = NativeBundleServer.port) { self.bundleRoot = bundleRoot; self.simulated = simulated; self.boundPort = port }
    func start(_ completion: @escaping (Result<URL, Error>) -> Void) {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: boundPort)!)
            // Specifying both requiredLocalEndpoint and init(on:) conflicts on iOS.
            let listener = try NWListener(using: parameters)
            self.listener = listener
            var reported = false
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                guard !reported else { return }
                switch state {
                case .ready: reported = true; self.boundPort=listener?.port?.rawValue ?? self.boundPort; let origin=self.originURL; DispatchQueue.main.async { completion(.success(origin)) }
                case .failed(let error): reported = true; DispatchQueue.main.async { completion(.failure(error)) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        } catch { completion(.failure(error)) }
    }
    func stop() {
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        queue.async { [self] in
            for task in self.tasks.values { task.cancel() }
            for connection in self.connections.values { connection.cancel() }
            self.tasks.removeAll(); self.connections.removeAll()
            self.clearOSMCache()
        }
    }
    deinit { listener?.cancel(); tasks.values.forEach { $0.cancel() }; connections.values.forEach { $0.cancel() } }
    func discardDisposableCaches(_ completion: (() -> Void)? = nil) {
        queue.async { [weak self] in self?.clearOSMCache(); if let completion { DispatchQueue.main.async(execute: completion) } }
    }
    private func clearOSMCache() {
        osmRawFiles.removeAll(); osmRawOrder.removeAll(); retainedOsmRawBytes = 0
        memoryCounters.set("retainedOsmRawBytes", 0); memoryCounters.set("retainedOsmDocumentCount", 0)
    }
    private func rawOSMFile(_ path: String, expectedBytes: Int, expectedSHA256: String) -> Data? {
        if let cached = osmRawFiles[path], cached.sha256 == expectedSHA256 {
            osmRawOrder.removeAll { $0 == path }; osmRawOrder.append(path)
            memoryCounters.add("osmRawCacheHitCount", 1)
            return cached.bytes
        }
        guard let bytes = readResource(path), bytes.count == expectedBytes,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expectedSHA256 else { return nil }
        memoryCounters.add("osmRawCacheMissCount", 1)
        if bytes.count <= Self.osmRawCacheBudget {
            while retainedOsmRawBytes + bytes.count > Self.osmRawCacheBudget || osmRawFiles.count >= 2 {
                guard let first = osmRawOrder.first else { break }
                osmRawOrder.removeFirst()
                if let removed = osmRawFiles.removeValue(forKey: first) { retainedOsmRawBytes -= removed.bytes.count }
            }
            osmRawFiles[path] = RawOSMFile(bytes: bytes, sha256: expectedSHA256)
            osmRawOrder.append(path); retainedOsmRawBytes += bytes.count
            memoryCounters.set("retainedOsmRawBytes", Double(retainedOsmRawBytes))
            memoryCounters.maximum("retainedOsmRawPeakBytes", Double(retainedOsmRawBytes))
        }
        return bytes
    }
    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.connections.removeValue(forKey: key); self?.tasks.removeValue(forKey: key)?.cancel() }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = buffer
            if let data { bytes.append(data) }
            if bytes.count > 2_600_000 { self.reply(connection, status: 413, data: Data()); return }
            guard let split = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { connection.cancel() } else { self.receive(connection, buffer: bytes) }
                return
            }
            guard let header = String(data: bytes[..<split.lowerBound], encoding: .utf8) else { connection.cancel(); return }
            let lines = header.components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ")
            guard first.count == 3, ["GET", "HEAD", "POST"].contains(String(first[0])),
                  let url = URL(string: String(first[1]), relativeTo: self.originURL)?.absoluteURL,
                  url.host == "127.0.0.1", url.port == Int(self.boundPort) else { self.reply(connection, status: 400, data: Data()); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let separator = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<separator]).lowercased()] = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            }
            guard headers["host"] == "127.0.0.1:\(self.boundPort)", headers["transfer-encoding"] == nil else { self.reply(connection, status: 400, data: Data()); return }
            let length = Int(headers["content-length"] ?? "0") ?? -1
            guard length >= 0, length <= 2_500_000 else { self.reply(connection, status: 413, data: Data()); return }
            let body = Data(bytes[split.upperBound...])
            if body.count < length {
                if complete || error != nil { connection.cancel() } else { self.receive(connection, buffer: bytes) }
                return
            }
            handle(connection, method: String(first[0]), url: url, body: Data(body.prefix(length)))
        }
    }
    func localFile(for path: String) -> URL? {
        let decoded = path.removingPercentEncoding ?? path
        guard !decoded.contains("\0"), !decoded.contains("\\"), !decoded.split(separator: "/").contains("..") else { return nil }
        let clean = decoded == "/" ? "index.html" : String(decoded.drop(while: { $0 == "/" }))
        let file = bundleRoot.appendingPathComponent(clean).standardizedFileURL
        guard file.path.hasPrefix(bundleRoot.standardizedFileURL.path + "/") else { return nil }
        return file
    }
    func readResource(_ path: String) -> Data? {
        guard let file=localFile(for:path) else{return nil}
        if let data=try? Data(contentsOf:file,options:.mappedIfSafe){return data}
        guard let compressed=try? Data(contentsOf:file.appendingPathExtension("gz"),options:.mappedIfSafe) else{return nil}
        let start = CFAbsoluteTimeGetCurrent()
        let decoded = try? NativeGzip.decode(compressed)
        if let decoded {
            memoryCounters.add("gzipReadCount", 1); memoryCounters.add("gzipDecodedBytes", Double(decoded.count))
            memoryCounters.maximum("largestDecodedResourceBytes", Double(decoded.count))
            memoryCounters.maximum("gzipDecodeMaximumMillis", (CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        return decoded
    }
    private func handle(_ connection: NWConnection, method: String, url: URL, body: Data) {
        let path = url.path
        if path.hasPrefix("/api/") {
            if path == "/api/house-numbers", let data = houseResponse(url) { reply(connection, data: data); return }
            if path == "/api/osm", let data = osmResponse(body) { reply(connection, data: data); return }
            if simulated { testResponse(connection, path: path, url: url, body: body); return }
            proxyExistingAPI(connection, method: method, url: url, body: body)
            return
        }
        guard method == "GET" || method == "HEAD", let file = localFile(for: path) else { reply(connection, status: 404, data: Data()); return }
        let raw=try? Data(contentsOf:file,options:.mappedIfSafe)
        let compressed:Data? = raw==nil ? (try? Data(contentsOf:file.appendingPathExtension("gz"),options:.mappedIfSafe)):nil
        guard let data=raw ?? compressed else{reply(connection,status:404,data:Data());return}
        let mime: String
        switch file.pathExtension.lowercased() {
        case "html": mime = "text/html; charset=utf-8"
        case "js", "mjs": mime = "text/javascript; charset=utf-8"
        case "css": mime = "text/css; charset=utf-8"
        case "json", "webmanifest": mime = "application/json; charset=utf-8"
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        default: mime = "application/octet-stream"
        }
        reply(connection, data: method == "HEAD" ? Data() : data, mime: mime,encoding:compressed==nil ? nil:"gzip")
    }
    private func proxyExistingAPI(_ connection: NWConnection, method: String, url: URL, body: Data) {
        let allowed: Set<String> = ["/api/route", "/api/route-status", "/api/search-suggest", "/api/google-resolve", "/api/osm", "/api/house-numbers", "/api/gogoro-stations", "/api/dest-sync/latest", "/api/geocode", "/api/reverse", "/api/poi-search"]
        guard allowed.contains(url.path), var components = URLComponents(url: AppConfig.liveBaseURL, resolvingAgainstBaseURL: false) else { reply(connection, status: 404, data: Data()); return }
        components.path = url.path; components.percentEncodedQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        guard let target = components.url, target.host == AppConfig.liveBaseURL.host else { reply(connection, status: 400, data: Data()); return }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = method; request.httpBody = method == "POST" ? body : nil
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" { request.setValue(url.path == "/api/osm" ? "text/plain;charset=UTF-8" : "application/json", forHTTPHeaderField: "Content-Type") }
        let key = ObjectIdentifier(connection)
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { connection.cancel(); return }
            self.queue.async {
                self.tasks.removeValue(forKey: key)
                if error != nil { self.reply(connection, status: 503, data: Data("{\"error\":\"既有服務暫時無法連線\"}".utf8)); return }
                guard let http = response as? HTTPURLResponse else { self.reply(connection, status: 502, data: Data()); return }
                // A denied remote response remains denied; no alternate host/UA/retry.
                self.reply(connection, status: http.statusCode, data: data ?? Data(), mime: http.value(forHTTPHeaderField: "Content-Type") ?? "application/json")
            }
        }
        tasks[key] = task; task.resume()
    }
    private func houseResponse(_ url: URL) -> Data? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let x = Int(query.first(where: { $0.name == "x" })?.value ?? ""),
              let y = Int(query.first(where: { $0.name == "y" })?.value ?? ""), (0..<32768).contains(x), (0..<32768).contains(y),
              let bytes = readResource("/offline/taichung-official-202608-v1/tiles/\(x)-\(y).json"), let tile = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let rows = tile["rows"] as? [[Any]] else { return nil }
        let converted = rows.filter { $0.count == 8 }.map { r -> [String: Any] in
            ["lat": r[0], "lng": r[1], "houseNumber": r[2], "road": r[3], "lane": r[4], "alley": r[5], "area": r[6], "district": r[7], "source": "taichung-official-address"]
        }
        return try? JSONSerialization.data(withJSONObject: ["version": "tcg-official-202608-v1", "tile": "\(x)/\(y)", "source": "taichung-official-address", "official": true, "rows": converted])
    }
    func osmResponse(_ body: Data) -> Data? {
        // Parse only the exact indexed tile; cache bounded raw bytes, never a bulk object tree.
        let responseStart = CFAbsoluteTimeGetCurrent()
        defer { memoryCounters.set("retainedOsmDocumentCount", 0); memoryCounters.maximum("osmResponseMaximumMillis", (CFAbsoluteTimeGetCurrent() - responseStart) * 1000) }
        guard let query = String(data: body, encoding: .utf8), let expression = try? NSRegularExpression(pattern: "around:[0-9.]+,([0-9.]+),([0-9.]+)"),
              let match = expression.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
              let latitudeRange = Range(match.range(at: 1), in: query), let longitudeRange = Range(match.range(at: 2), in: query),
              let latitude = Double(query[latitudeRange]), let longitude = Double(query[longitudeRange]) else { return nil }
        let n = pow(2.0, 12.0), x = Int((longitude + 180) / 360 * n), y = Int((1 - asinh(tan(latitude * .pi / 180)) / .pi) / 2 * n)
        if osmIndex == nil, let b = readResource("/native-data/osm-file-index.json") { osmIndex = try? JSONSerialization.jsonObject(with: b) as? [String: [[String: Any]]] }
        let radiusExpression=try? NSRegularExpression(pattern:"around:([0-9.]+)")
        let radius=(radiusExpression?.matches(in:query,range:NSRange(query.startIndex...,in:query)) ?? []).compactMap{m->Double? in guard let r=Range(m.range(at:1),in:query) else{return nil};return Double(query[r])}.max() ?? 250
        let latitudeRadius=min(8000,max(50,radius))/111320,longitudeRadius=latitudeRadius/max(0.3,cos(latitude * .pi/180))
        func near(_ row:[String:Any])->Bool {
            func inside(_ p:[String:Any])->Bool{guard let lat=p["lat"] as? Double,let lng=p["lon"] as? Double else{return false};return abs(lat-latitude)<=latitudeRadius&&abs(lng-longitude)<=longitudeRadius}
            if inside(row)||inside(row["center"] as? [String:Any] ?? [:]){return true}
            let geometry=(row["geometry"] as? [[String:Any]] ?? [])+((row["members"] as? [[String:Any]] ?? []).flatMap{$0["geometry"] as? [[String:Any]] ?? []})
            if geometry.contains(where:inside){return true}
            let latitudes=geometry.compactMap{$0["lat"] as? Double},longitudes=geometry.compactMap{$0["lon"] as? Double}
            guard let south=latitudes.min(),let north=latitudes.max(),let west=longitudes.min(),let east=longitudes.max() else{return false}
            return north>=latitude-latitudeRadius&&south<=latitude+latitudeRadius&&east>=longitude-longitudeRadius&&west<=longitude+longitudeRadius
        }
        var elements: [[String: Any]] = [], seen = Set<String>(), complete = true, found = false
        for tx in (x - 1)...(x + 1) { for ty in (y - 1)...(y + 1) {
            let tile = "12/\(tx)/\(ty)"
            guard let records = osmIndex?[tile] else { continue }
            found = true
            for record in records {
                autoreleasepool {
                    guard let path = record["path"] as? String,
                          let offset = record["byteOffset"] as? Int, let length = record["byteLength"] as? Int,
                          let fileBytes = record["fileBytes"] as? Int, let fileSHA = record["fileSHA256"] as? String,
                          let tileSHA = record["tileSHA256"] as? String,
                          offset >= 0, length > 0, offset <= fileBytes, length <= fileBytes - offset,
                          let raw = rawOSMFile(path, expectedBytes: fileBytes, expectedSHA256: fileSHA) else { complete = false; return }
                    let piece = raw.subdata(in: offset..<(offset + length)), parseStart = CFAbsoluteTimeGetCurrent()
                    guard SHA256.hash(data: piece).map({ String(format: "%02x", $0) }).joined() == tileSHA,
                          let item = try? JSONSerialization.jsonObject(with: piece) as? [String: Any],
                          item["key"] as? String == tile, (item["part"] as? Int ?? 0) == (record["part"] as? Int ?? 0),
                          let rows = item["elements"] as? [[String: Any]] else { complete = false; return }
                    memoryCounters.add("selectedTileParseCount", 1); memoryCounters.add("selectedTileParsedRawBytes", Double(piece.count))
                    memoryCounters.maximum("selectedTileParseMaximumMillis", (CFAbsoluteTimeGetCurrent() - parseStart) * 1000)
                    for row in rows { let id = "\(row["type"] ?? ""):\(row["id"] ?? "")"; if near(row),seen.insert(id).inserted { elements.append(row) } }
                }
            }
        } }
        guard found, complete else { return nil }
        memoryCounters.set("lastOsmResponseElements", Double(elements.count))
        return try? JSONSerialization.data(withJSONObject: ["elements": elements, "source": "accepted-original-prebuilt", "complete": true])
    }
    private func testResponse(_ connection: NWConnection, path: String, url: URL, body: Data) {
        // Explicit simulator-only fixture. This is never a claim of real routing.
        if path == "/api/route" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let input = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            func point(_ key: String) -> [Double] { let value = input[key] as? String ?? items.first(where: { $0.name == key })?.value ?? ""; return value.split(separator: ",").compactMap { Double($0) } }
            let a = point("from"), b = point("to")
            guard a.count == 2, b.count == 2 else { reply(connection, status: 400, data: Data()); return }
            let via = input["via"] as? [[String: Double]] ?? [], coordinates = [a] + via.compactMap { p -> [Double]? in guard let lng = p["lng"], let lat = p["lat"] else { return nil }; return [lng, lat] } + [b]
            let record: [String: Any] = ["geometry": ["type": "LineString", "coordinates": coordinates], "distance": 334, "duration": 90, "maneuvers": [], "label": "SIMULATED UI FIXTURE"]
            let result: [String: Any] = items.contains(where: { $0.name == "alternatives" }) ? ["routes": [record]] : record
            reply(connection, data: (try? JSONSerialization.data(withJSONObject: result)) ?? Data()); return
        }
        if path == "/api/gogoro-stations", let data = Bundle.main.url(forResource: "battery-stations-fallback", withExtension: "json").flatMap({ try? Data(contentsOf: $0) }) { reply(connection, data: data); return }
        if path == "/api/route-status" { reply(connection, data: Data("{\"version\":\"SIMULATED\",\"source\":\"UI test\"}".utf8)); return }
        reply(connection, status: 404, data: Data("{\"error\":\"SIMULATED endpoint unavailable\"}".utf8))
    }
    private func reply(_ connection: NWConnection, status: Int = 200, data: Data, mime: String = "application/json; charset=utf-8",encoding:String?=nil) {
        let reason = status == 200 ? "OK" : "Response"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-cache\r\nX-Content-Type-Options: nosniff\r\n"+(encoding.map{"Content-Encoding: \($0)\r\n"} ?? "")+"\r\n"
        var output = Data(header.utf8); output.append(data)
        connection.send(content: output, completion: .contentProcessed { _ in connection.cancel() })
    }
}
