#!/usr/bin/env python3
"""Offline-only pinned public source compatibility gate for LC+SS CoreDevice.

No Apple ID, paired device, iPhone, or provisioning operations.
No writes to actual LC+SS sources. Fail-closed if a downloaded revision is not
the expected one or if an upstream source cannot be fetched.
"""
from __future__ import annotations
import hashlib
import json
import pathlib
import urllib.request

REFS = {
    "lc_fork": ("LiveContainer/SideStore", "ee3cc16a67f9fed766f79a0ed70938f0f8ad5a07"),
    "mux": ("SideStore/minimuxer", "12be70dc2627307a16bfd2dc7a009080d5bec909"),
    "nrg": ("NRG-Wardog/sidestore-auto-refresh", "7aff2fcc6163b91c6a4e8f6403de90e003e0baab"),
}
files = {
    "current_gateway": ("mux", "DeviceGateway/idevice/IdeviceGateway.swift"),
    "current_pair_parser": ("mux", "Common/PairingFile.swift"),
    "current_mux_api": ("mux", "Sources/MinimuxerImpl.swift"),
    "current_pair_protocol": ("mux", "Common/PairingProtocol.swift"),
    "current_ss_pair_manager": ("lc_fork", "SideStore/Core/Pairing/PairingFileManager.swift"),
    "nrg_combined_adapter": ("nrg", "scripts/patch_combined_transport.py"),
    "nrg_coredevice_rust_patch": ("nrg", "scripts/patch_coredevice_idevice.py"),
    "nrg_adapter_pairing": ("nrg", "scripts/adapt_sidestore_070_pairing.py"),
    "nrg_compat": ("nrg", "docs/COMPATIBILITY.md"),
    "nrg_workflow": ("nrg", ".github/workflows/build-current.yml"),
}
def fetch(refname:str, path:str)->str:
    repo, sha = REFS[refname]
    url=f"https://raw.githubusercontent.com/{repo}/{sha}/{path}"
    req=urllib.request.Request(url,headers={"User-Agent":"LCSS-pin-audit/1.0"})
    with urllib.request.urlopen(req,timeout=20) as response:
        assert response.status==200
        raw=response.read()
    assert len(raw)>=100, ("Unexpectedly small upstream",path)
    return raw.decode("utf-8")

src={}
digests={}
for name,(repo,path) in files.items():
    s=fetch(repo,path)
    src[name]=s
    digests[name]=hashlib.sha256(s.encode()).hexdigest()

current=src["current_gateway"]
pair=src["current_pair_parser"]
nrg=src["nrg_combined_adapter"]
nrg_rust=src["nrg_coredevice_rust_patch"]
nrg_pair=src["nrg_adapter_pairing"]

def chk(desc,test,severity):
    return {"check":desc,"result":"YES" if test else "NO","severity":severity}

checks=[
 chk("pinned current SideStore IdeviceGateway already supports tunnel_create_usb()", "tunnel_create_usb(" in current, "required"),
 chk("pinned current SideStore IdeviceGateway already has CoreDeviceProxy support", "CoreDeviceProxy" in current, "required"),
 chk("current pairing parser has explicit composite-ambiguity rejection", "ambiguous" in pair.lower(), "context"),
 chk("NRG older parser patch raw old anchor exists in current parser",
    "        let missingRP = RPPairingFile.missingKeys(in: plist)\n        if missingRP.isEmpty" in pair, "required"),
 chk("NRG combined adapter expects BaseDeviceGateway capabilities",
    "Combined adapter requires the pinned BaseDeviceGateway revision" in nrg, "context"),
 chk("NRG CoreDevice requires separate rebuilt Rust idevice FFI",
    "tunnel_create_usb" in nrg_rust and "CoreDeviceProxy::connect" in nrg_rust, "required"),
 chk("NRG selects Lockdown first if composite pairing exists",
    "Composite records must use Lockdown/CoreDevice" in nrg_pair, "context"),
 chk("original LC+SS pairing sanitization preserves alt_irk without patch",
    "ansDict[\"alt_irk\"]" in src["current_ss_pair_manager"], "context"),
 chk("NRG compatibility report claims proof specifically for user iOS27/iPhone16",
    "iPhone 16 | 27" in src["nrg_compat"], "required"),
]

# This analysis intentionally does not try to coerce compatible-looking source
# code into a new binary. Such a build would silently discard a required Rust
# FFI transport and could destroy the known-good app on the user's phone.
has_rust_transport = "tunnel_create_usb(" in current
has_compatible_parser="        let missingRP = RPPairingFile.missingKeys(in: plist)\n        if missingRP.isEmpty" in pair
report={
 "date":"2026-10-21",
 "status":"SOURCE_AUDIT_COMPLETE_NON_DEPLOYABLE" if (not has_rust_transport or not has_compatible_parser) else "SOURCE_AUDIT_REQUIRES_MORE_DETAIL",
 "target":"current iPhone16 iOS27 LiveContainer SideStore",
 "exact_upstream_refs":{k:{"repository":v[0],"sha":v[1]} for k,v in REFS.items()},
 "read_only_public_sources":digests,
 "checks":checks,
 "known_working_baseline":"user's already installed official LC+SS signed by iLoader over USBMUX Network",
 "coredevice_patch_drop_in_safe":has_rust_transport and has_compatible_parser,
 "requires_full_signed_lockdown_pairing_record":True,
 "in_app_remote_pairing_only_record_sufficient":False,
 "requires_provisioning_and_entitlement_compatibility_audit":True,
 "iOS27_real_device_support":"NOT_VALIDATED",
 "actual_refresh_success":"NOT_VALIDATED",
 "apple_id_or_pairing_contents_fetched":False,
 "attempted_iphone_or_apple_api_access":False,
 "source_only_action":"No automated installation or CI-produced IPA authorized by audit alone",
 "hard_blocker":"Previous PC-side device/provisioning introspection was explicitly refused; do not bypass via CI, scripts, agents or alternate tools.",
 "next_engineering_work":"Version-specific port of NRG CoreDevice Rust FFI plus Swift gateway and composite parser; build canary only after exact-source targeted tests and human-safe device gate. May not yield iOS27 working self-refresh.",
}
out=pathlib.Path("lcss_coredevice_compat_report.json")
out.write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
print(json.dumps({key:report[key] for key in ["status","coredevice_patch_drop_in_safe","requires_full_signed_lockdown_pairing_record","iOS27_real_device_support","actual_refresh_success","hard_blocker"]}))
assert report["apple_id_or_pairing_contents_fetched"] is False
