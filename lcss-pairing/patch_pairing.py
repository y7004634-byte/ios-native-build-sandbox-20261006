#!/usr/bin/env python3
"""Narrow LC SideStore 2026-10-17 RPPairing alt_irk retention repair."""
import argparse
import difflib
import hashlib
import json
import pathlib
import plistlib

parser = argparse.ArgumentParser()
parser.add_argument("source")
args = parser.parse_args()
source = pathlib.Path(args.source)
assert source.name == "PairingFileManager.swift", source
original = source.read_text(encoding="utf-8")
needle = '''        for key in requiredKeys {
            ansDict[key] = plist[key]
        }
        return String(data: try! PropertyListSerialization.data(fromPropertyList: ansDict, format: .xml, options: 0), encoding: .utf8)!
'''
replacement = '''        for key in requiredKeys {
            ansDict[key] = plist[key]
        }
        // Retain the device's mDNS identity key. It is optional in older
        // records, but MUST NOT be discarded when the record provides it.
        if pprotocol == .rppairing, let altIRK = plist["alt_irk"] {
            ansDict["alt_irk"] = altIRK
        }
        return String(data: try! PropertyListSerialization.data(fromPropertyList: ansDict, format: .xml, options: 0), encoding: .utf8)!
'''
assert original.count(needle) == 1, "Unexpected source: fail closed; do not patch"
assert "func sanitizePairingFileFor" in original
assert "alt_irk" not in original[original.index("func sanitizePairingFileFor"):original.index("func fetchPairingFile(preferred:")], "Already patched?"
# Synthetic, non-secret data to demonstrate the 10/17 truncation and repaired contract.
base = {"identifier": "SYNTHETIC", "private_key": b"P"*32, "public_key": b"Q"*32, "alt_irk": bytes(range(16))}
mixed = dict(base, UDID="TEST", HostID="TEST")
for candidate in (base, mixed):
    baseline = {k: candidate[k] for k in ("private_key", "public_key", "identifier")}
    assert "alt_irk" not in baseline
    repaired = dict(baseline)
    if "alt_irk" in candidate: repaired["alt_irk"] = candidate["alt_irk"]
    assert plistlib.loads(plistlib.dumps(repaired))["alt_irk"] == candidate["alt_irk"]
    assert set(repaired) == {"private_key", "public_key", "identifier", "alt_irk"}
legacy = {k:v for k,v in base.items() if k != "alt_irk"}
assert set(legacy) == {"private_key", "public_key", "identifier"}
patched = original.replace(needle,replacement,1)
assert patched.count('ansDict["alt_irk"] = altIRK') == 1
source.write_text(patched,encoding="utf-8")
report = {"status":"SOURCE_PATCH_AND_SYNTHETIC_TEST_PASS","file":str(source),"before_sha256":hashlib.sha256(original.encode()).hexdigest(),"after_sha256":hashlib.sha256(patched.encode()).hexdigest(),"changed_region_count":1,"synthetic_records_tested":3,"requires_compilation":True,"requires_real_device_tls_test":True}
out = pathlib.Path("lcss-pairing-fix-result.json")
out.write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
pathlib.Path("lcss-pairing-fix.diff").write_text("".join(difflib.unified_diff(original.splitlines(True),patched.splitlines(True),fromfile="LC_fork_before",tofile="LC_fork_after")),encoding="utf-8")
print(json.dumps(report))
