import CoreLocation
import Foundation
import UIKit
import WebKit

final class DoorMapViewController: UIViewController, NativeBridgeDelegate {
    private let nativeBridge = NativeBridge()
    private let locationBridge = LocationBridge()
    private let appleSearchBridge = AppleSearchBridge()
    private let initialDeepLink: URL?
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]
    private(set) var webView: WKWebView!

    init(initialDeepLink: URL?) {
        self.initialDeepLink = initialDeepLink
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureWebView()
        loadInitialContent()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateHeadingOrientation()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.updateHeadingOrientation()
        }
    }

    private func configureWebView() {
        let controller = WKUserContentController()
        controller.add(nativeBridge, name: AppConfig.nativeBridgeName)
        controller.addUserScript(NativeBridge.bootstrapScript)
        controller.addUserScript(NativeBridge.readyScript)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.applicationNameForUserAgent = AppConfig.userAgentSuffix
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        nativeBridge.delegate = self
        locationBridge.webView = webView
        appleSearchBridge.webView = webView
        self.webView = webView
    }

    private func loadInitialContent() {
        let payload = initialDeepLink.map(DeepLinkRouter.payload(from:)) ?? .home
        load(payload)
    }

    private func load(_ payload: DeepLinkPayload) {
        let url = DeepLinkRouter.webURL(for: payload)
        loadRequest(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy))
    }

    private func loadRequest(_ request: URLRequest) {
        guard let url = request.url else { return }
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: Bundle.main.bundleURL)
        } else {
            webView.load(request)
        }
    }

    func handleIncomingURL(_ url: URL) {
        load(DeepLinkRouter.payload(from: url))
    }

    func notifyLifecycle(_ state: String) {
        let active = state == "foreground" || state == "willForeground"
        if active { updateHeadingOrientation() }
        locationBridge.setAppActive(active)
        guard webView != nil else { return }
        let escaped = state.replacingOccurrences(of: "'", with: "\\'")
        let script = """
        window.dispatchEvent(new CustomEvent('door581:nativeLifecycle', {
          detail: { state: '\(escaped)' }
        }));
        """
        webView.evaluateJavaScript(script)
    }

    private func updateHeadingOrientation() {
        guard let orientation = view.window?.windowScene?.interfaceOrientation else { return }
        let deviceOrientation: CLDeviceOrientation
        switch orientation {
        case .portrait: deviceOrientation = .portrait
        case .portraitUpsideDown: deviceOrientation = .portraitUpsideDown
        case .landscapeLeft: deviceOrientation = .landscapeLeft
        case .landscapeRight: deviceOrientation = .landscapeRight
        default: deviceOrientation = .portrait
        }
        locationBridge.setHeadingOrientation(deviceOrientation)
    }

    func requestNativeLocation() {
        locationBridge.requestOneShot()
    }

    func setNativeLocationStreaming(_ enabled: Bool) {
        locationBridge.setContinuousLocationEnabled(enabled)
    }

    func searchApple(
        requestID: String,
        query: String,
        latitude: Double?,
        longitude: Double?,
        radiusM: Double
    ) {
        appleSearchBridge.search(
            requestID: requestID,
            query: query,
            latitude: latitude,
            longitude: longitude,
            radiusM: radiusM
        )
    }

    func openExternalURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return }
        UIApplication.shared.open(url)
    }

    func webContentReady() {
        notifyLifecycle(UIApplication.shared.applicationState == .active ? "foreground" : "background")
    }
}

extension DoorMapViewController: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame != false,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }

        if url.isFileURL || url.host == AppConfig.liveBaseURL.host {
            decisionHandler(.allow)
            return
        }

        if let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        if url.scheme?.lowercased() == "door581" {
            handleIncomingURL(url)
            decisionHandler(.cancel)
            return
        }

        if let scheme = url.scheme?.lowercased(), !["about", "blob", "data", "javascript"].contains(scheme) {
            UIApplication.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}

extension DoorMapViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        // Native builds source heading through CLLocationManager.
        // Never surface the WebKit motion/orientation permission sheet.
        decisionHandler(.deny)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else { return nil }
        if url.host == AppConfig.liveBaseURL.host || url.isFileURL {
            loadRequest(navigationAction.request)
        } else {
            UIApplication.shared.open(url)
        }
        return nil
    }
}


extension DoorMapViewController: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let safeName = suggestedFilename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let filename = safeName.isEmpty ? "581-DoorMap-export" : safeName
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoorMap581Downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(filename, isDirectory: false)
            downloadDestinations[ObjectIdentifier(download)] = destination
            completionHandler(destination)
        } catch {
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard let destination = downloadDestinations.removeValue(forKey: key) else { return }

        let share = UIActivityViewController(activityItems: [destination], applicationActivities: nil)
        let cleanupDirectory = destination.deletingLastPathComponent()
        share.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: cleanupDirectory)
        }

        let presenter = presentedViewController ?? self
        presenter.present(share, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        guard let destination = downloadDestinations.removeValue(forKey: key) else { return }
        try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
    }

    func download(
        _ download: WKDownload,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }
}
