import CoreImage
import MapKit
import UIKit

/// On-demand NLSC display tiles only. No prefetch, no disk cache, no Apple data.
/// A replacing tile overlay keeps the inset separate from the main Apple map.
final class NativeMiniRaster: MKTileOverlay {
    private let session: URLSession
    private let fixture: Data?
    private let lock = NSLock()
    private var generation = 0
    private var paused = false
    private var tasks: [UUID: URLSessionDataTask] = [:]
    private let context = CIContext(options: [.cacheIntermediates: false])
    private(set) var delivered = 0
    private(set) var failed = 0
    var onFailure: (() -> Void)?
    init(fixture: Data? = nil) {
        self.fixture = fixture
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0; maximumZ = 23; canReplaceMapContent = true
    }
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        lock.lock(); let captured = generation, paused = self.paused; lock.unlock()
        guard !paused, path.z >= 0, path.z <= 23, path.x >= 0, path.y >= 0 else { result(nil, URLError(.cancelled)); return }
        if let fixture { result(fixture, nil); return }
        let z = min(19, path.z), factor = 1 << max(0, path.z - z)
        let x = path.x / factor, y = path.y / factor
        guard x < (1 << z), y < (1 << z) else { result(nil, URLError(.badURL)); return }
        let url = URL(string: "https://wmts.nlsc.gov.tw/wmts/EMAP2/default/GoogleMapsCompatible/\(z)/\(y)/\(x)")!
        let identity = UUID()
        let task = session.dataTask(with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)) { [weak self] data, response, error in
            guard let self else { result(nil, URLError(.cancelled)); return }
            self.lock.lock(); self.tasks.removeValue(forKey: identity)
            let obsolete = self.paused || captured != self.generation; self.lock.unlock()
            guard !obsolete else { result(nil, URLError(.cancelled)); return }
            guard let data, data.count <= 2 * 1024 * 1024,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data)?.cgImage else {
                self.lock.lock(); self.failed += 1; self.lock.unlock()
                DispatchQueue.main.async { [weak self] in self?.onFailure?() }
                result(nil, error ?? URLError(.badServerResponse)); return
            }
            let size = Double(image.width) / Double(factor)
            let crop = CGRect(x: Double(path.x % factor) * size, y: Double(path.y % factor) * size, width: size, height: size)
            guard let cropped = image.cropping(to: crop) else { result(nil, URLError(.cannotDecodeContentData)); return }
            let input = CIImage(cgImage: cropped).transformed(by: CGAffineTransform(scaleX: Double(factor), y: Double(factor)))
            guard let output = self.context.createCGImage(input, from: input.extent), let bytes = UIImage(cgImage: output).pngData() else {
                result(nil, URLError(.cannotDecodeContentData)); return
            }
            self.lock.lock(); self.delivered += 1; self.lock.unlock()
            result(bytes, nil)
        }
        lock.lock(); let obsolete = paused || generation != captured
        if !obsolete { tasks[identity] = task }; lock.unlock()
        if obsolete { result(nil, URLError(.cancelled)) } else { task.resume() }
    }
    func setActive(_ value: Bool) {
        lock.lock(); paused = !value; generation += 1
        let pending = Array(tasks.values); tasks.removeAll(); lock.unlock()
        pending.forEach { $0.cancel() }
        if !value { context.clearCaches() }
    }
    func shutdown() { setActive(false); onFailure = nil; session.invalidateAndCancel() }
    deinit { session.invalidateAndCancel() }
}
