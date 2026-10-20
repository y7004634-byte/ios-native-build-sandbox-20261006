#!/usr/bin/env python3
"""Fail-closed, opt-in-only TEST candidate: split RPPairing first/second TCP endpoints.

This is a prototype for one private LAN. It does not touch credentials,
pairing state, unrelated LiveContainer functionality, or Mainnet. It uses
libimobiledevice RPPairing so the secondary TCP host can change without
recompiling the SideStore/idevice Rust binary XCFramework.
"""
from pathlib import Path
from difflib import unified_diff
from hashlib import sha256
import json

root=Path("lcss-source")
gateway=root/"Dependencies/minimuxer/DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift"
wrapper=root/"SideStore/Core/DeviceApi/MinimuxerWrapper.swift"
assert gateway.is_file() and wrapper.is_file(), "pinned source missing"
before=gateway.read_text(encoding="utf-8")
wbefore=wrapper.read_text(encoding="utf-8")
changes=[]

def one(s,needle,repl,tag):
    assert s.count(needle)==1, f"unexpected {tag} anchor count={s.count(needle)}"
    changes.append(tag)
    return s.replace(needle,repl,1)

# This backend uses direct RSD services for RP records and does not need the
# legacy fake-usbmuxd server. Without this, RP-only 4-key files fail startup
# because the legacy server expects UDID field not present in RP records.
before=one(before,
  "    public let requiresUsbmuxd: Bool = true",
  "    public let requiresUsbmuxd: Bool = false  // RP-only LAN relay TEST; classic mode unsupported",
  "rp_no_legacy_usbmuxd")

before=one(before,
  "    private var activeRsd: rppairing_rsd_t? = nil",
  """    private var activeRsd: rppairing_rsd_t? = nil
    // A single gateway owns mutable RP tunnel/identity handles.
    private let lcssSerialFFI = DispatchQueue(label: "io.sidestore.lcss.relay.ffi", qos: .userInitiated)""",
  "ffi_queue_declaration")
count=before.count("withFFIDispatch {")
assert count==22, f"expected 22 gateway FFI wrappers, found {count}"
before=before.replace("withFFIDispatch {","withFFIDispatch(on: lcssSerialFFI) {")
changes.append("ffi_dispatch_22")

arm_helper='''    // TEST-ONLY LAN relay configuration (one known home-network computer).
    // First RemotePairing pair-verify stays on the original 10.7.0.1 IP.
    // The second, device-allocated listener goes through a one-shot LAN relay.
    private final class WifiRelayHTTPResult: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int = 0
        private var payload: Data?
        func save(_ response: URLResponse?, _ data: Data?) {
            lock.lock()
            defer { lock.unlock() }
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            payload = data
        }
        func snapshot() -> (Int, Data?) {
            lock.lock()
            defer { lock.unlock() }
            return (status, payload)
        }
    }

    private func prepareWifiRelay(listenerPort: UInt16) throws -> (host: String, port: UInt16) {
        // TEST candidate only. Never publish router credentials or host keys.
        let pcIp = "192.168.31.203"
        let pcControlPort: UInt16 = 47952
        let pcDataPort: UInt16 = 47953
        guard listenerPort > 1024,
              let url = URL(string: "http://\\(pcIp):\\(pcControlPort)/arm") else {
            throw LibimobiledeviceGatewayError(.serviceError, reason: "LAN relay invalid configuration")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2.5
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("port=\\(listenerPort)".utf8)
        let result = WifiRelayHTTPResult()
        let finished = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: request) { data, response, _ in
            result.save(response, data)
            finished.signal()
        }
        task.resume()
        if finished.wait(timeout: .now() + 3.0) != .success {
            task.cancel()
            session.invalidateAndCancel()
            throw LibimobiledeviceGatewayError(.connectionFailed, reason: "LAN relay PC control request timeout")
        }
        session.finishTasksAndInvalidate()
        let (status, body) = result.snapshot()
        guard status == 200,
              let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              json["ok"] as? Bool == true,
              let returnedPort = json["relay_port"] as? Int,
              returnedPort == Int(pcDataPort) else {
            throw LibimobiledeviceGatewayError(.connectionFailed, reason: "LAN relay PC not ready or refused secondary listener")
        }
        debugLog("[LibimobiledeviceGateway] LCSS WiFi relay armed for second TCP listener, no PSK is sent")
        return (pcIp, pcDataPort)
    }

'''
before=one(before,
  "    private func withRPTunnel<T>(_ body: (rppairing_tunnel_t, rppairing_tunnel_info_t) throws -> T) throws -> T {",
  arm_helper+"    private func withRPTunnel<T>(_ body: (rppairing_tunnel_t, rppairing_tunnel_info_t) throws -> T) throws -> T {",
  "arm_helper")

before=one(before,
  "            let tunErr = rppairing_tunnel_connect(host, tunnelPort, psk, pskLen, &tunnelInfo, &tunnel)",
  """            // The device's second listener is reached from the Windows relay,
            // not by iOS hairpinning its own VPN endpoint.
            let relay = try prepareWifiRelay(listenerPort: tunnelPort)
            let tunErr = rppairing_tunnel_connect(relay.host, relay.port, psk, pskLen, &tunnelInfo, &tunnel)""",
  "second_listener_redirect")

# Test build's gateway selection is deliberate and unmistakable. Stock app
# has a separate user backend setting; this isolated build does not change it.
wbefore=one(wbefore,
  "    selectedGatewayBackendCache = GatewayBackend(rawValue: raw) ?? .idevice",
  """    selectedGatewayBackendCache = .libimobiledevice // LCSS Windows WiFi relay TEST build only
    debugLog("[LCSS WiFi Relay TEST] Libimobiledevice backend forced for SECOND listener forwarding")""",
  "backend_test_selection")

gnew=before
wnew=wbefore
assert gnew.count("withFFIDispatch(on: lcssSerialFFI) {")==22
assert gnew.count("rppairing_tunnel_connect(relay.host, relay.port")==1
assert gnew.count("rppairing_client_new(host, port")==1
assert "192.168.31.203" in gnew
assert "192.168.31.12" not in gnew
gateway.write_text(gnew,encoding="utf-8")
wrapper.write_text(wnew,encoding="utf-8")
diff="".join(unified_diff(gateway.read_text(encoding="utf-8").splitlines(True),gnew.splitlines(True),fromfile="gateway_before",tofile="gateway_after"))
# Generate actual diff from stored preimage fetched with git show to avoid fake evidence.
diff="".join(unified_diff(
    __import__("subprocess").check_output(["git","show","HEAD:DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift"],cwd=root/"Dependencies/minimuxer").decode().splitlines(True),
    gnew.splitlines(True),fromfile="minimuxer_pinned",tofile="gateway_wifi_relay_candidate"))
Path("lcss-wifi-relay.diff").write_text(diff,encoding="utf-8")
report={"status":"SOURCE_PATCH_READY_NEEDS_XCODE",
        "gateway":str(gateway),"wrapper":str(wrapper),
        "gateway_sha256":sha256(gnew.encode()).hexdigest(),
        "wrapper_sha256":sha256(wnew.encode()).hexdigest(),
        "changes":changes,
        "serialized_gateway_wrappers":22,
        "first_remote_pairing":"original direct endpoint",
        "second_remote_pairing":"PC LAN relay 192.168.31.203:47953",
        "paired_keys_modified":False,
        "device_acceptance":"NOT_TESTED"}
Path("lcss-wifi-relay-result.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
print(json.dumps(report))
