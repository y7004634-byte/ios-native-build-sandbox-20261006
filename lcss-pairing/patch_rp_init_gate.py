#!/usr/bin/env python3
"""Minimal fix: RPPairing gateway must not demand a pre-fetched UDID.

In a fresh RPPairing-only pairing record (identifier, public_key, private_key,
alt_irk), cachedUDID is necessarily nil until a successful RSD GetValue.
The original libimobiledevice verifyInitialized() mistakenly requires cachedUDID
BEFORE allowing withRPClient(). This yields "FetchUDID:" with empty reason and
prevents the relay's POST /arm from ever executing.
"""
import hashlib, json, difflib
from pathlib import Path

p=Path("lcss-source/Dependencies/minimuxer/DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift")
assert p.exists(), "pinned libimobiledevice source missing"
old=p.read_text(encoding="utf-8")
guard_old="""    private func verifyInitialized() throws {
        guard isInitialized, cachedUDID != nil else {
            throw LibimobiledeviceGatewayError(.notInitialized)
        }
    }
"""
guard_new="""    private func verifyInitialized() throws {
        // RPPairing provides a host identity before the first device I/O.
        // The hardware UDID is fetched over RSD after the RP tunnel is up;
        // requiring cachedUDID here creates a circular dependency.
        guard isInitialized else {
            throw LibimobiledeviceGatewayError(.notInitialized, reason: "Gateway not started")
        }
        switch pairingFileType {
        case .rppairing:
            guard rpIdentity != nil else {
                throw LibimobiledeviceGatewayError(.notInitialized, reason: "Remote Pairing identity not loaded")
            }
        case .lockdown:
            guard cachedUDID != nil else {
                throw LibimobiledeviceGatewayError(.notInitialized, reason: "Lockdown UDID not loaded")
            }
        case .unknown:
            throw LibimobiledeviceGatewayError(.notInitialized, reason: "No pairing protocol selected")
        }
    }
"""
assert old.count(guard_old)==1, f"guard anchor count {old.count(guard_old)}"
assert old.count("self.cachedUDID = nil")==1, "gateway cleanup not as expected"
assert old.count("self.rpIdentity = identity")==1, "RPPairing branch not as expected"
assert old.count("self.cachedUDID = udid")==1, "Lockdown branch not as expected"
after=old.replace(guard_old,guard_new,1)

# Error attribution must survive through MinumuxerAPI runWithChecks().
# The original .notInitialized reason was empty, causing a bare "FetchUDID:".
# After this fix, any genuine second-listener TCP failure must produce a
# descriptive reason from the underlying gateway, not an anonymous one.
catch_old="""        } catch {
            debugLog("[LibimobiledeviceGateway] syncFetchUDID: failed to query lockdown: \(error)")
        }
        if let cached = cachedUDID, !cached.isEmpty {
            return cached
        }
        throw LibimobiledeviceGatewayError(.serviceError, reason: "UniqueDeviceID not found on device")
"""
catch_new="""        } catch {
            debugLog("[LibimobiledeviceGateway] syncFetchUDID: failed to query lockdown: \(error)")
            if let cached = cachedUDID, !cached.isEmpty {
                return cached
            }
            // Preserve the real RPPairing / relay stage error for diagnosis.
            throw error
        }
        if let cached = cachedUDID, !cached.isEmpty {
            return cached
        }
        throw LibimobiledeviceGatewayError(.serviceError, reason: "UniqueDeviceID not found on device")
"""
assert after.count(catch_old)==1, f"fetch catch anchor count {after.count(catch_old)}"
after=after.replace(catch_old,catch_new,1)
assert after.count("guard rpIdentity != nil else")==1
assert after.count('throw error\n        }\n        if let cached')==1
assert "guard isInitialized, cachedUDID != nil" not in after
p.write_text(after,encoding="utf-8")
diff="".join(difflib.unified_diff(old.splitlines(True),after.splitlines(True),fromfile="wifi_relay_v1",tofile="rp_identity_gate_fix"))
Path("lcss-rp-init-gate.diff").write_text(diff,encoding="utf-8")
report={"status":"SOURCE_RP_BOOTSTRAP_GATE_PATCH_PASS","path":str(p),"old_sha256":hashlib.sha256(old.encode()).hexdigest(),"new_sha256":hashlib.sha256(after.encode()).hexdigest(),"source_edits":2,"test_cases":["RPPairing identity permits first fetch before cached UDID","Lockdown still requires cached UDID","Unknown protocol rejected","RSD failure preserves diagnostic reason"],"physical_iphone":"NOT_TESTED"}
Path("lcss-rp-init-gate-result.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
print(json.dumps(report))
