import CoreLocation
import MapKit
import WebKit

final class NLSCMiniMapView: UIView, WKScriptMessageHandler, WKNavigationDelegate {
    private var webView: WKWebView!
    private var ready = false, editing = false, active = false, dark = true, correctionEnabled = false
    private var pending: [String: Any]?
    private var lastSize = CGSize.zero
    private var editSession = UUID().uuidString
    var onCorrection: ((CLLocationCoordinate2D) -> Void)?
    var onError: ((String) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        let content = WKUserContentController(); content.add(NLSCMessageRelay(owner: self), name: "nlscMini")
        let config = WKWebViewConfiguration(); config.userContentController = content; config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config); webView.navigationDelegate = self
        webView.isOpaque = false; webView.backgroundColor = .systemBackground
        webView.scrollView.isScrollEnabled = false; webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.translatesAutoresizingMaskIntoConstraints = false; webView.accessibilityIdentifier = "nlsc-map"
        addSubview(webView)
        NSLayoutConstraint.activate([webView.leadingAnchor.constraint(equalTo: leadingAnchor),webView.trailingAnchor.constraint(equalTo: trailingAnchor),webView.topAnchor.constraint(equalTo: topAnchor),webView.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func beginEditing(map: MKMapView, rider: CLLocation?, heading: Double, dark: Bool) {
        editing = true; active = true; self.dark = dark; editSession = UUID().uuidString
        // Snapshot only viewport and device position. Apple items, labels, pins and route never cross this bridge.
        let center = CGPoint(x: map.bounds.midX, y: map.bounds.midY)
        let a = map.convert(center,toCoordinateFrom: map)
        let b = map.convert(CGPoint(x: center.x+20,y: center.y),toCoordinateFrom: map)
        let scale = CLLocation(latitude: a.latitude,longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude,longitude: b.longitude))/20
        var value: [String: Any] = ["center":[a.longitude,a.latitude],"metersPerPoint":max(0.02,scale),"bearing":map.camera.heading,"heading":heading]
        if let rider, rider.horizontalAccuracy>=0, abs(rider.timestamp.timeIntervalSinceNow)<30 { value["rider"] = [rider.coordinate.longitude,rider.coordinate.latitude] }
        pending = value
        if webView.url == nil, let url = Bundle.main.url(forResource: "nlsc-map",withExtension: "html",subdirectory: "MiniMap") { webView.loadFileURL(url,allowingReadAccessTo: url.deletingLastPathComponent()) }
        flush(reset: true)
    }
    func endEditing() { editing = false; active = false; editSession = UUID().uuidString; evaluate("window.NLSCMini?.end();") }
    func setActive(_ value: Bool) { active = value && editing; evaluate("window.NLSCMini?.pause(\(active ? "false" : "true"));") }
    func setTheme(dark: Bool) { self.dark = dark; evaluate("window.NLSCMini?.theme(\(dark ? "true" : "false"));") }
    func setCorrectionEnabled(_ value: Bool) { correctionEnabled = value; evaluate("window.NLSCMini?.allowCorrection(\(value ? "true" : "false"));") }
    func resize() {
        guard bounds.size != lastSize else { return }; lastSize = bounds.size; evaluate("window.NLSCMini?.resize();")
    }
    private func evaluate(_ code: String) { if ready { webView.evaluateJavaScript(code) } }
    private func flush(reset: Bool) {
        guard ready, let pending, let data = try? JSONSerialization.data(withJSONObject: pending),let json = String(data: data,encoding: .utf8) else { return }
        evaluate("window.NLSCMini.theme(\(dark ? "true" : "false"));window.NLSCMini.allowCorrection(\(correctionEnabled ? "true" : "false"));window.NLSCMini.begin(\(json), '\(editSession)');window.NLSCMini.pause(\(active ? "false" : "true"));window.NLSCMini.resize();")
    }
    func userContentController(_ controller: WKUserContentController,didReceive message: WKScriptMessage) {
        guard message.name == "nlscMini",message.frameInfo.isMainFrame,message.webView === webView,webView.url?.isFileURL == true,
              let value = message.body as? [String: Any],let type = value["type"] as? String else { return }
        if type == "ready" { ready = true; webView.accessibilityIdentifier = "nlsc-ready-map"; flush(reset: true) }
        if type == "error" && active { onError?("NLSC 圖磚暫不可用") }
        if type == "correct",editing,active,correctionEnabled,value["session"] as? String == editSession,let c = value["center"] as? [Double],c.count == 2 {
            let point = CLLocationCoordinate2D(latitude: c[1],longitude: c[0])
            if point.latitude.isFinite && point.longitude.isFinite && (20...27).contains(point.latitude) && (117...123).contains(point.longitude) { onCorrection?(point) }
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { ready = false; webView.accessibilityIdentifier = "nlsc-map"; if active { webView.reload() } }
    func webView(_ webView: WKWebView,decidePolicyFor action: WKNavigationAction,decisionHandler: @escaping (WKNavigationActionPolicy)->Void) { decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel) }
}
private final class NLSCMessageRelay: NSObject,WKScriptMessageHandler {
    weak var owner: NLSCMiniMapView?
    init(owner: NLSCMiniMapView) { self.owner = owner; super.init() }
    func userContentController(_ controller: WKUserContentController,didReceive message: WKScriptMessage) { owner?.userContentController(controller,didReceive: message) }
}
