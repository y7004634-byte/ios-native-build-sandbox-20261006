#!/usr/bin/env python3
"""Source-only minimal CoreDevice RSD route for pinned LiveContainer/SideStore.

Depends on the existing verified release binary:
SideStore idevice v0.1.68-ss-3e55c84 sha256 445702d53942597deb4cdec2c4122d16a3f4ac124ce26cd75b68dab3dad92416
(tunnel_create_usb, idevice_tcp_provider_new, RSD client APIs present).
This does not access devices, Apple accounts, keychain, or pairing contents.
App acceptance requires a full authorized Lockdown record and iOS27 proof.
"""
from __future__ import annotations
from pathlib import Path
from difflib import unified_diff
import hashlib
import json

root=Path("lcss-source/Dependencies/minimuxer")
files={
    "gateway":root/"DeviceGateway/idevice/IdeviceGateway.swift",
    "parser":root/"Common/PairingFile.swift",
    "impl":root/"Sources/MinimuxerImpl.swift",
}
data={key:p.read_text(encoding="utf-8") for key,p in files.items()}
original=dict(data)

def replace_one(key,old,new,label):
    count=data[key].count(old)
    if count != 1:
        raise RuntimeError(f"{label}: need exactly one source anchor, found {count}")
    data[key]=data[key].replace(old,new,1)

replace_one("parser",'''        if hasRemoteRP && hasLockdown {
            throw PairingError.ambiguous("The pairing file contains credentials for both Remote Pairing and Lockdown protocols. Specify a preferred protocol to resolve ambiguity.")
        }''','''        if hasRemoteRP && hasLockdown {
            // Existing classic Lockdown credentials permit a CoreDevice RSD path.
            // Do not default a complete composite record back to RemotePairing TCP.
            return .lockdown
        }''',"composite preferred Lockdown")

replace_one("gateway",'''    private var pairingFile: OpaquePointer? = nil
    private var adapter: OpaquePointer? = nil
    private var handshake: OpaquePointer? = nil
''','''    private var pairingFile: OpaquePointer? = nil
    private var adapter: OpaquePointer? = nil
    private var handshake: OpaquePointer? = nil
    // Holds the TCP lockdown provider while a CoreDevice RSD tunnel is active.
    private var coreDeviceProvider: OpaquePointer? = nil

    private var shouldUseCoreDevice: Bool {
        if #available(iOS 26.4, *) {
            return pairingFileType == .lockdown
        }
        return false
    }
''',"CoreDevice state")

replace_one("gateway",'''    public override func invalidateConnection() {
        debugLog("[IdeviceGateway] invalidateConnection() called - clearing stale adapter and handshake")
        if let handshake = handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter = adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }
''','''    public override func invalidateConnection() {
        debugLog("[IdeviceGateway] invalidateConnection(): release RSD and provider in safe order")
        if let handshake = handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter = adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
        if let provider = coreDeviceProvider {
            idevice_provider_free(provider)
            coreDeviceProvider = nil
        }
    }
''',"CoreDevice provider lifetime")

replace_one("gateway",'''    private func ensureRPConnection() throws {
        debugLog("[IdeviceGateway] ensureRPConnection() started, adapter: \(String(describing: adapter)), handshake: \(String(describing: handshake))")
''','''    private func ensureCoreDeviceConnection() throws {
        if adapter != nil && handshake != nil {
            return
        }
        // A complete imported Lockdown record is required. A 502-byte
        // RemotePairing-only record cannot authorize CoreDeviceProxy.
        guard pairingFileType == .lockdown, let data = pairingFileData,
              !data.isEmpty else {
            throw IdeviceGatewayError(.invalidPairingFile,
                                     reason: "CoreDevice requires a complete Lockdown pairing record")
        }
        guard let ip = deviceEndpointIp, !ip.isEmpty else {
            throw IdeviceGatewayError(.deviceEndpointIpNotAvailable,
                                     reason: "CoreDevice peer IP is not available")
        }

        var temporaryPairing: OpaquePointer? = nil
        let parseError = data.withUnsafeBytes { bytes in
            idevice_pairing_file_from_bytes(
                bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                UInt(data.count),
                &temporaryPairing
            )
        }
        if let parseError {
            let message = getErrorMessage(from: parseError)
            idevice_error_free(parseError)
            throw IdeviceGatewayError(.invalidPairingFile,
                                     reason: "CoreDevice Lockdown parse failed: \(message)")
        }
        guard let temporaryPairing else {
            throw IdeviceGatewayError(.invalidPairingFile, reason: "CoreDevice Lockdown parsing returned nil")
        }
        var pairingConsumed = false
        defer {
            if !pairingConsumed {
                idevice_pairing_file_free(temporaryPairing)
            }
        }

        // The idevice provider owns a successfully consumed temporaryPairing.
        // Do not pass self.pairingFile here: it belongs to the gateway.
        var provider: OpaquePointer? = nil
        let providerError = try withSockaddr(ip: ip, port: MinimuxerConstants.lockdowndPort) { addr, _ in
            addr.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { raw in
                idevice_tcp_provider_new(raw, temporaryPairing, MinimuxerConstants.appName, &provider)
            }
        }
        pairingConsumed = providerError == nil
        if let providerError {
            let message = getErrorMessage(from: providerError)
            idevice_error_free(providerError)
            throw IdeviceGatewayError(.connectionFailed,
                                     reason: "CoreDevice TCP provider creation failed: \(message)")
        }
        guard let provider else {
            throw IdeviceGatewayError(.connectionFailed, reason: "CoreDevice provider was nil")
        }

        // The pinned SideStore binary already exports this native Rust FFI.
        debugLog("[LCSS_COREDEVICE] TUNNEL_CONNECT_START transport=lockdown_coredevice")
        let tunnelError = tunnel_create_usb(provider, &adapter, &handshake)
        if let tunnelError {
            let message = getErrorMessage(from: tunnelError)
            let code = tunnelError.pointee.code
            idevice_error_free(tunnelError)
            invalidateConnection()
            idevice_provider_free(provider)
            debugLog("[LCSS_COREDEVICE] TUNNEL_CONNECT_FAIL code=\(code) message=\(message)")
            throw IdeviceGatewayError(.connectionFailed,
                                     reason: "CoreDeviceProxy tunnel failed: \(message)")
        }
        guard adapter != nil && handshake != nil else {
            invalidateConnection()
            idevice_provider_free(provider)
            throw IdeviceGatewayError(.connectionFailed, reason: "CoreDevice RSD transport handles missing")
        }
        coreDeviceProvider = provider
        debugLog("[LCSS_COREDEVICE] TUNNEL_CONNECT_PASS")
    }

    private func ensureRPConnection() throws {
        if shouldUseCoreDevice {
            try ensureCoreDeviceConnection()
            return
        }
        debugLog("[IdeviceGateway] ensureRPConnection() started, adapter: \(String(describing: adapter)), handshake: \(String(describing: handshake))")
''',"first modern Lockdown CoreDevice RSD transport")

replace_one("gateway",'''        if pairingFileType == .rppairing {
            return try performWithService(connect: connectRP, cleanup: cleanup, serviceName: serviceName, action: action)
        } else {
            return try performWithTcpService(connect: connectLockdown, cleanup: cleanup, serviceName: serviceName, action: action)
        }
''','''        if pairingFileType == .rppairing || shouldUseCoreDevice {
            return try performWithService(connect: connectRP, cleanup: cleanup, serviceName: serviceName, action: action)
        } else {
            return try performWithTcpService(connect: connectLockdown, cleanup: cleanup, serviceName: serviceName, action: action)
        }
''',"RSD service dispatch for CoreDevice")

replace_one("gateway",'''            if self.pairingFileType == .lockdown, let pairingFileData = self.pairingFileData {
''','''            if self.pairingFileType == .lockdown && !self.shouldUseCoreDevice,
               let pairingFileData = self.pairingFileData {
''',"skip legacy Lockdown session for RSD service")

replace_one("gateway",'''        if pairingFileType == .rppairing {
            try mountPersonalizedDdiRsd(image: image, trustcache: trustcache, manifest: manifest)
''','''        if pairingFileType == .rppairing || shouldUseCoreDevice {
            try mountPersonalizedDdiRsd(image: image, trustcache: trustcache, manifest: manifest)
''',"image mounter uses RSD for CoreDevice")

# Avoid forcing original legacy debug flow through the RSD tunnel. Do not
# change ordinary RP or pre-modern operating systems.
replace_one("gateway",'''        if pairingFileType == .lockdown {
            verboseLog("[IdeviceGateway] debugApp() attempting legacy lockdownd debugserver via launchAppPre17")
''','''        if pairingFileType == .lockdown && !shouldUseCoreDevice {
            verboseLog("[IdeviceGateway] debugApp() attempting legacy lockdownd debugserver via launchAppPre17")
''',"modern CoreDevice debug forwarding")
replace_one("gateway",'''        if pairingFileType == .rppairing {
            try performWithService(
                connect: debug_proxy_connect_rsd,
''','''        if pairingFileType == .rppairing || shouldUseCoreDevice {
            try performWithService(
                connect: debug_proxy_connect_rsd,
''',"debugProcess modern RSD forwarding")

replace_one("impl",'''                // check iKEv2 too if in lockdown mode and ios >= 26.4
                if self.gateway.pairingFileType != .rppairing && !net.isIKEv2IPSecAvailable {
                    if #available(iOS 26.4, *) {
                        debugLog("[minimuxer] minimuxer not ready: no ipsec interface (required for lockdown on iOS 26.4+)")
                        return .failure(.invalidVPN("utun is present but no ipsec/IKEv2 interface found — LocalDevVPN may not support the lockdown protocol on iOS 26.4+"))
                    }
                }
''','''                // CoreDeviceProxy uses the existing utun path. Legacy
                // extra IPSec-interface gating prevents attempting a live RSD
                // connection and is not a valid proof of availability.
''',"remove raw IPSec gate for modern Lockdown RSD")

replace_one("impl",'''        let peerReachable = testDeviceConnection(ifaddr: deviceIp)
        if !peerReachable {
''','''        let peerReachable = testDeviceConnection(ifaddr: deviceIp)
        // On iOS 26.4+ a complete Lockdown record is served through
        // CoreDeviceProxy. The old raw TCP poll is not an authoritative
        // check of that tunnel; fetchUDID() will verify actual RSD.
        let liveCoreDeviceCheck: Bool
        if #available(iOS 26.4, *) {
            liveCoreDeviceCheck = (pairingType == .lockdown && connectionMode == .localVPN)
        } else {
            liveCoreDeviceCheck = false
        }
        if !peerReachable && !liveCoreDeviceCheck {
''',"use actual CoreDevice RSD result instead of legacy raw TCP poll")

for key,p in files.items():
    p.write_text(data[key],encoding="utf-8")
    diff="".join(unified_diff(original[key].splitlines(keepends=True),
                              data[key].splitlines(keepends=True),
                              fromfile="pinned-original/"+key,tofile="CoreDevice-test/"+key))
    Path(f"lcss-coredevice-{key}.diff").write_text(diff,encoding="utf-8")

assert all(data[k]!=original[k] for k in files)
assert data["gateway"].count("tunnel_create_usb(provider, &adapter, &handshake)")==1
assert data["gateway"].count("coreDeviceProvider")==5, data["gateway"].count("coreDeviceProvider")
assert 'return .lockdown\n        }\n\n        if hasRemoteRP' in data["parser"]
assert "no ipsec interface (required for lockdown on iOS 26.4+)" not in data["impl"]
report={
    "result":"MINIMAL_COREDEVICE_SWIFT_SOURCE_PATCH_PASS_BUILD_NOT_RUN",
    "source_pinned_minimuxer":"12be70dc2627307a16bfd2dc7a009080d5bec909",
    "ffi_binary_pinned":"SideStore idevice v0.1.68-ss-3e55c84",
    "binary_usb_export_verified_in_separate_job":True,
    "changed_files":{key:{"path":str(files[key]),
                          "before_sha256":hashlib.sha256(original[key].encode()).hexdigest(),
                          "after_sha256":hashlib.sha256(data[key].encode()).hexdigest()} for key in files},
    "pairing_mode":"Complete composite or classic Lockdown required; RP-only remains unchanged",
    "ios27_runtime_test":"NOT_TESTED",
    "app_refresh":"NOT_TESTED",
    "secrets_touched":False,
}
Path("lcss-coredevice-source-result.json").write_text(json.dumps(report,indent=2)+"\n")
print(json.dumps(report))
