import Foundation

struct NativeDestinationSyncPayload: Decodable, Equatable, Sendable {
    let lat: Double
    let lng: Double
    let updatedAt: Double

    func accepted(nowMS: Double, lastAppliedAt: Double) -> DoorCoordinate? {
        let point = DoorCoordinate(lat: lat, lng: lng)
        guard point.isValid, (20...27).contains(lat), (117...123).contains(lng),
              updatedAt.isFinite, nowMS - updatedAt <= 10 * 60 * 1000,
              updatedAt > lastAppliedAt else { return nil }
        return point
    }
}

@MainActor final class NativeDestinationSync {
    private static let appliedKey = "581.appletest.dest-sync-applied-at.v1"
    private let session: URLSession
    private var burstTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private(set) var lastAppliedAt: Double
    var onDestination: ((DoorCoordinate, Double, Bool) -> Void)?
    var onRequest: (() -> Void)?

    init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        lastAppliedAt = defaults.double(forKey: Self.appliedKey)
    }

    func scheduleBurst() {
        generation &+= 1
        let ticket = generation
        burstTask?.cancel()
        let delays: [UInt64] = [0, 450, 1200, 2600, 4800, 8000]
        burstTask = Task { [weak self] in
            guard let self else { return }
            var previous: UInt64 = 0
            for (index, absolute) in delays.enumerated() {
                let wait = absolute > previous ? absolute - previous : 0
                previous = absolute
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: wait * 1_000_000)
                }
                guard !Task.isCancelled, self.generation == ticket else { return }
                await self.poll(silent: index > 0, ticket: ticket)
            }
        }
    }

    func cancel() {
        generation &+= 1
        burstTask?.cancel(); burstTask = nil
    }

    private func poll(silent: Bool, ticket: UInt64) async {
        var components = URLComponents(url: AppConfig.liveBaseURL.appendingPathComponent("api/dest-sync/latest"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "ts", value: String(Int(Date().timeIntervalSince1970 * 1000)))]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "GET"; request.setValue("application/json", forHTTPHeaderField: "Accept")
        onRequest?()
        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled, generation == ticket, let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 404 { return }
            guard (200..<300).contains(http.statusCode), data.count <= 32_768,
                  let payload = try? JSONDecoder().decode(NativeDestinationSyncPayload.self, from: data) else { return }
            let now = Date().timeIntervalSince1970 * 1000
            guard let point = payload.accepted(nowMS: now, lastAppliedAt: lastAppliedAt) else { return }
            lastAppliedAt = payload.updatedAt
            UserDefaults.standard.set(payload.updatedAt, forKey: Self.appliedKey)
            onDestination?(point, payload.updatedAt, silent)
        } catch is CancellationError { }
        catch { }
    }

}
