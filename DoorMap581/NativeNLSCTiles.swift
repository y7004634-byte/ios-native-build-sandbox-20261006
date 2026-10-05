import CoreImage
import MapKit
import UIKit

/// The same close-range NLSC raster used by the accepted web release.
/// Apple tiles and search metadata never enter this independent overlay.
final class NativeNLSCTiles: MKTileOverlay {
    private let brightness: Double
    private let saturation: Double
    private static let imageContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    private let taskLock = NSLock()
    private var tasks: [UUID: URLSessionDataTask] = [:]
    private var suspended = false
    private var generation = 0
    private(set) var deliveredTiles = 0
    init(brightness: Double, saturation: Double) {
        self.brightness = brightness; self.saturation = saturation
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256); minimumZ = 0; maximumZ = 24
        canReplaceMapContent = false
    }
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        taskLock.lock(); let currentGeneration = generation, paused = suspended; taskLock.unlock()
        guard !paused else { result(nil, URLError(.cancelled)); return }
        let z = min(19, path.z), factor = 1 << max(0, path.z - z)
        let x = path.x / factor, y = path.y / factor
        let url = URL(string: "https://wmts.nlsc.gov.tw/wmts/EMAP2/default/GoogleMapsCompatible/\(z)/\(y)/\(x)")!
        let identity = UUID()
        let task = URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 15)) { [weak self] data, response, error in
            guard let self else { result(nil, URLError(.cancelled)); return }
            self.taskLock.lock(); self.tasks.removeValue(forKey: identity); let obsolete = self.suspended || self.generation != currentGeneration; self.taskLock.unlock()
            guard !obsolete else { result(nil, URLError(.cancelled)); return }
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data)?.cgImage else { result(nil, error ?? URLError(.badServerResponse)); return }
            let size = Double(image.width) / Double(factor)
            let rect = CGRect(x: Double(path.x % factor) * size, y: Double(path.y % factor) * size, width: size, height: size)
            guard let cropped = image.cropping(to: rect) else { result(nil, URLError(.cannotDecodeContentData)); return }
            let input = CIImage(cgImage: cropped).transformed(by: CGAffineTransform(scaleX: Double(factor), y: Double(factor)))
            let gray = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: max(0, 1 + self.saturation)])
            let scale = CIVector(x: CGFloat(self.brightness), y: 0, z: 0, w: 0)
            let adjusted = gray.applyingFilter("CIColorMatrix", parameters: ["inputRVector": scale,
                "inputGVector": CIVector(x: 0, y: CGFloat(self.brightness), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(self.brightness), w: 0)])
            guard let output = Self.imageContext.createCGImage(adjusted, from: adjusted.extent), let bytes = UIImage(cgImage: output).pngData() else { result(nil, URLError(.cannotDecodeContentData)); return }
            DispatchQueue.main.async { self.deliveredTiles += 1 }; result(bytes, nil)
        }
        taskLock.lock()
        let cancelled = suspended || generation != currentGeneration
        if !cancelled { tasks[identity] = task }
        taskLock.unlock()
        if cancelled { result(nil, URLError(.cancelled)) } else { task.resume() }
    }
    func suspendRequests() {
        taskLock.lock(); suspended = true; generation += 1; let pending = Array(tasks.values); tasks.removeAll(); taskLock.unlock()
        pending.forEach { $0.cancel() }; Self.clearImageCaches()
    }
    @discardableResult func resumeRequests() -> Bool {
        taskLock.lock(); defer { taskLock.unlock() }; let changed = suspended; suspended = false; return changed
    }
    static func clearImageCaches() { imageContext.clearCaches() }
    deinit { tasks.values.forEach { $0.cancel() } }
}
