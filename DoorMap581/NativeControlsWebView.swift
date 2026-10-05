import UIKit
import WebKit

/// Legacy hybrid-only transparent controls view. The full-native build target
/// excludes this file so NativeCameraAdapter does not link WebKit.
final class NativeControlsWebView: WKWebView {
    var controlRects: [CGRect] = []
    var modalOpen = false
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        modalOpen || controlRects.contains { $0.contains(point) }
    }
}
