import Foundation

enum AppConfig {
    static let liveBaseURL = URL(string: "https://rider-door-map-canary.pages.dev/")!
    static let nativeBridgeName = "doorMapNative"
    static let userAgentSuffix = "DoorMap581Native/0.2"

    enum ContentMode {
        case remoteLive
        case bundledAssets
    }

    // Phase 1 intentionally starts from the verified live build.
    // This prevents accidentally bundling an older Door Map snapshot.
    static let contentMode: ContentMode = .remoteLive

    static func initialURL() -> URL {
        switch contentMode {
        case .remoteLive:
            return liveBaseURL
        case .bundledAssets:
            return bundledIndexURL() ?? liveBaseURL
        }
    }

    static func bundledIndexURL() -> URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web")
    }
}
