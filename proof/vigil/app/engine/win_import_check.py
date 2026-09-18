#!/usr/bin/env python3
"""
Windows-portability import gate for the Vigil CSI engine (Phase W4 PREP).

Contract: windows-w4-vigil-prep-20260720. This is a STATIC portability probe,
not a ship step. It proves two things a Windows build depends on:

  1. The node-fed sensing path (ESP32 UDP :5005/:5566 -> engine -> pose/vitals)
     imports cleanly with ONLY Windows-available deps (numpy, scipy, stdlib).
  2. NO Apple-only / pyobjc module is pulled in transitively by that path
     (CoreWLAN, Vision, AppKit, Quartz, objc, AVFoundation, ...). Those live
     only in the Swift Mac-radio layer, never in the node-fed Python path.

Run from a cold shell:  /usr/bin/python3 engine/win_import_check.py
Exit 0 = portable-clean. Exit 1 = a blocker for the Windows port.
"""
import importlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# Apple / pyobjc module name prefixes that must NEVER appear in sys.modules
# after importing the node-fed path. Any hit = Apple lock-in on a Windows path.
APPLE_PREFIXES = (
    "Quartz", "Vision", "AppKit", "Cocoa", "Foundation", "CoreWLAN",
    "CoreLocation", "CoreBluetooth", "AVFoundation", "ScreenCaptureKit",
    "Metal", "objc", "PyObjCTools", "LaunchServices", "CoreFoundation",
)

# The node-fed sensing path + the pose/vitals it drives. Importing home_engine
# transitively pulls pose_infer, predict, fall_detect, vigil_paths. We import
# the fleet source (:5566), the CSI reader (:5005), and the scipy vitals/spectral
# stack explicitly so a lazy Apple import anywhere in them would surface here.
NODE_FED_MODULES = [
    "pose_infer",              # CSI->17kp pose net (pure numpy over pose_v1.safetensors)
    "predict",                 # anomaly/baseline
    "fall_detect",             # eldercare fall monitor
    "vigil_paths",
    "vigil_source",            # ESP32 fleet source, UDP :5566
    "csi_reader",              # generic CSI source, UDP :5005
    "vigil_bus",
    "vigil_safety",
    "vigil_home",
    "vigil_steam",
    "vigil_spectra",           # -> vigil.machines.spectra (scipy)
    "vigil.machines.spectra",
    "vigil.vitals.heart",      # scipy.signal
    "vigil.vitals.breathing",  # scipy.signal
    "home_engine",             # the whole HTTP sidecar entrypoint (top-level imports)
]

def main():
    # Preconditions: the two Windows-available third-party deps.
    deps = {}
    for d in ("numpy", "scipy"):
        try:
            m = importlib.import_module(d)
            deps[d] = getattr(m, "__version__", "?")
        except Exception as e:  # noqa: BLE001
            print(f"FAIL: required Windows dep '{d}' missing: {e}")
            return 1
    print(f"deps: numpy {deps['numpy']}, scipy {deps['scipy']}")

    failed = []
    for name in NODE_FED_MODULES:
        try:
            importlib.import_module(name)
            print(f"  ok   import {name}")
        except Exception as e:  # noqa: BLE001
            failed.append((name, repr(e)))
            print(f"  FAIL import {name}: {e!r}")

    # Scan everything that got loaded for Apple lock-in.
    apple_hits = sorted(
        m for m in sys.modules
        if any(m == p or m.startswith(p + ".") for p in APPLE_PREFIXES)
    )

    print("")
    if failed:
        print(f"IMPORT FAILURES: {len(failed)} module(s) did not import")
        return 1
    if apple_hits:
        print(f"APPLE LOCK-IN: node-fed path pulled {apple_hits}")
        return 1
    print(f"PASS: {len(NODE_FED_MODULES)} node-fed modules import clean on "
          f"numpy+scipy+stdlib; 0 Apple/pyobjc modules loaded.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
