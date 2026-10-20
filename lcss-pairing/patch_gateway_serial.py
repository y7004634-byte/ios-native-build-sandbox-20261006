#!/usr/bin/env python3
"""Serialize all idevice FFI calls accessing shared RP adapter/handshake.

This is deliberately scoped to SideStore/minimuxer@12be70dc IdeviceGateway.
No pairing files, Apple credentials, installed app data, or network config are touched.
"""
import hashlib
import json
from pathlib import Path
from difflib import unified_diff

src=Path("lcss-source/Dependencies/minimuxer/DeviceGateway/idevice/IdeviceGateway.swift")
assert src.is_file(),f"missing pinned source {src}"
before=src.read_text(encoding="utf-8")
anchor="    private var handshake: OpaquePointer? = nil\n"
insertion="""    private var handshake: OpaquePointer? = nil
    // All gateway FFI calls mutate shared pairing/adapter/handshake handles.
    // Default withFFIDispatch(on: .global()) permits concurrent handshakes.
    // Use a single serial queue for the lifetime of THIS gateway instance.
    private let ffiDispatchQueue = DispatchQueue(label: "io.sidestore.idevice.ffi.serial", qos: .userInitiated)
"""
target="withFFIDispatch {"
replacement="withFFIDispatch(on: ffiDispatchQueue) {"
assert before.count(anchor)==1,"unexpected gateway fields"
assert before.count(target)==24,"unexpected FFI call count"
assert before.count(replacement)==0,"already patched; fail closed"
assert 'public final class IdeviceGateway: BaseDeviceGateway' in before
after=before.replace(anchor,insertion,1).replace(target,replacement)
assert after.count(target)==0
assert after.count(replacement)==24
assert after.count('private let ffiDispatchQueue = DispatchQueue(')==1
src.write_text(after,encoding="utf-8")
report={
  "status":"SOURCE_SINGLE_QUEUE_PATCH_PASS",
  "target":str(src),
  "source_sha256":hashlib.sha256(before.encode()).hexdigest(),
  "patched_sha256":hashlib.sha256(after.encode()).hexdigest(),
  "ffi_dispatch_calls_serialized":24,
  "pairing_state_handles":"adapter, handshake, pairingFile",
  "validation":"static scope checks only; requires Xcode compiler + physical TLS acceptance",
  "device_test":"NOT_TESTED"
}
Path("lcss-ffi-serial-result.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
Path("lcss-ffi-serial.diff").write_text("".join(unified_diff(before.splitlines(True),after.splitlines(True),fromfile="minimuxer_pinned_before",tofile="minimuxer_serial_candidate")),encoding="utf-8")
print(json.dumps(report))
