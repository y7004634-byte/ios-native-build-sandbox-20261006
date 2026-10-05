import Foundation
import WebKit

/// WKUserContentController owns its handlers; forward without owning the screen.
final class WeakNativeScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

protocol NativeBridgeDelegate: AnyObject {
    func requestNativeLocation()
    func setNativeLocationStreaming(_ enabled: Bool)
    func searchApple(
        requestID: String,
        query: String,
        latitude: Double?,
        longitude: Double?,
        radiusM: Double
    )
    func openExternalURL(_ url: URL)
    func webContentReady()
}

final class NativeBridge: NSObject, WKScriptMessageHandler {
    weak var delegate: NativeBridgeDelegate?

    static var bootstrapScript: WKUserScript {
        let source = """
        (() => {
          if (window.Door581Native) return;
          const pending = new Map();
          let seq = 0;

          const post = (type, payload = {}) => {
            window.webkit.messageHandlers.doorMapNative.postMessage({ type, payload });
          };
          const call = (type, payload = {}) => new Promise((resolve, reject) => {
            const requestID = 'n' + Date.now().toString(36) + '-' + (++seq).toString(36);
            pending.set(requestID, { resolve, reject });
            post(type, { ...payload, requestID });
          });

          window.Door581Native = Object.freeze({
            isNative: true,
            shell: '0.3.1',
            post,
            requestLocation() {
              post('requestLocation');
            },
            startLocation() {
              post('locationStream', { enabled: true });
            },
            stopLocation() {
              post('locationStream', { enabled: false });
            },
            searchApple(query, center = null, radiusM = 3000) {
              return call('appleSearch', { query, center, radiusM });
            },
            _resolve(requestID, ok, payload) {
              const entry = pending.get(requestID);
              if (!entry) return;
              pending.delete(requestID);
              if (ok) entry.resolve(payload);
              else entry.reject(new Error(payload?.message || 'Native request failed'));
            }
          });
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
    static var readyScript: WKUserScript {
        let source = """
        (() => {
          const detail = { platform: 'ios', shell: '0.3.1' };
          window.dispatchEvent(new CustomEvent('door581:nativeReady', { detail }));
          try {
            window.webkit.messageHandlers.doorMapNative.postMessage({ type: 'ready', payload: detail });
          } catch (_) {}
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == AppConfig.nativeBridgeName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        let payload = body["payload"] as? [String: Any] ?? [:]

        switch type {
        case "requestLocation":
            delegate?.requestNativeLocation()

        case "locationStream":
            let enabled = (payload["enabled"] as? Bool) ?? false
            delegate?.setNativeLocationStreaming(enabled)

        case "appleSearch":
            guard let requestID = payload["requestID"] as? String,
                  let query = payload["query"] as? String,
                  !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            let center = payload["center"] as? [String: Any]
            let latitude = center?["lat"] as? Double
            let longitude = center?["lng"] as? Double

            delegate?.searchApple(
                requestID: requestID,
                query: query,
                latitude: latitude,
                longitude: longitude,
                radiusM: min(8000, max(3000, payload["radiusM"] as? Double ?? 3000))
            )

        case "openExternal":
            guard let raw = payload["url"] as? String,
                  let url = URL(string: raw) else { return }
            delegate?.openExternalURL(url)

        case "ready":
            delegate?.webContentReady()

        default:
            break
        }
    }
}
