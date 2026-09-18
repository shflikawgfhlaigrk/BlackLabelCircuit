#!/usr/bin/env python3
"""
Ground-truth vitals calibration — tune a node's heart/breathing detection against
a REAL reference reading.

Protocol (per person, per bedside node):
  1. Person lies still, ESP beside the bed. Reference device on (pulse-ox / watch).
  2. We pull the last `--secs` of raw CSI from that node (no service interruption).
  3. You pass the TRUE heart rate (--hr) and optionally breathing rate (--br) the
     reference showed during that minute.
  4. This script checks whether the true rhythm is actually PRESENT in the CSI,
     finds which subcarriers + analysis settings surface it cleanest, reports the
     error, and saves a per-node profile the live detector then uses.

  python3 calibrate_vitals.py --node 192.168.4.51 --person "Mom" --hr 64 --br 14 --secs 60

Honesty: if the true rate is NOT present in the signal (no spectral energy at the
reference frequency above noise), it says so plainly — that node/position cannot
see that vital, and no tuning can fake it. Better placement or breathing-only.
"""
import argparse, json, os, urllib.request
import numpy as np

DATA_DIR = os.environ.get("HF_DATA", os.path.expanduser("~/.homefront"))
PROFILE_PATH = os.path.join(DATA_DIR, "vitals_profiles.json")
SUB = 56


def pull_raw(base, node, secs):
    url = f"{base}/raw?node={node}&secs={secs}"
    d = json.load(urllib.request.urlopen(url, timeout=20))
    ts = np.array(d.get("ts", []), dtype=np.float64)
    amp = np.array(d.get("amp", []), dtype=np.float64)   # [T, 56]
    return ts, amp, d.get("span_s", 0)


def hampel(x, ns=3.0):
    med = np.median(x, axis=0); mad = np.median(np.abs(x - med), axis=0) + 1e-9
    bad = np.abs(x - med) > ns * 1.4826 * mad
    y = x.copy()
    for j in range(x.shape[1]):
        if bad[:, j].any():
            y[bad[:, j], j] = med[j]
    return y


def resample_uniform(ts, sig, fs_target):
    span = ts[-1] - ts[0]
    n = int(span * fs_target)
    if n < 16:
        return None, None
    grid = np.linspace(ts[0], ts[-1], n)
    return grid, np.interp(grid, ts, sig)


def band_energy(sig, fs, f_lo, f_hi):
    """Return (peak_freq_hz, peak/noise_snr, spectrum, freqs) within [f_lo,f_hi]."""
    x = sig - sig.mean()
    t = np.arange(x.size)
    x = x - np.polyval(np.polyfit(t, x, 2), t)
    spec = np.abs(np.fft.rfft(x * np.hanning(x.size)))
    freqs = np.fft.rfftfreq(x.size, d=1.0 / fs)
    band = (freqs >= f_lo) & (freqs <= f_hi)
    if not band.any() or spec[band].max() <= 0:
        return None, 0.0, spec, freqs
    pk = int(np.where(band)[0][int(np.argmax(spec[band]))])
    ref = (freqs >= 0.05).copy(); ref[max(0, pk - 2):pk + 3] = False
    noise = np.median(spec[ref]) + 1e-9 if ref.any() else 1e-9
    return float(freqs[pk]), float(spec[pk] / noise), spec, freqs


def analyze(ts, amp, true_hz, f_lo, f_hi, label):
    """Find the subcarriers whose spectrum peaks closest to the true frequency."""
    fs = (ts.size - 1) / (ts[-1] - ts[0])
    amp = hampel(amp)
    results = []
    for j in range(amp.shape[1]):
        g, s = resample_uniform(ts, amp[:, j], fs)
        if g is None:
            continue
        pf, snr, _, _ = band_energy(s, fs, f_lo, f_hi)
        if pf is None:
            continue
        err = abs(pf - true_hz)
        results.append((j, pf, snr, err))
    if not results:
        return None
    # rank by: close to truth AND strong SNR
    results.sort(key=lambda r: (r[3], -r[2]))
    best = results[:12]                      # the subcarriers that see this vital best
    # combined estimate from the best subcarriers (median of their peaks)
    near = [r for r in results if r[3] < (0.15 if f_hi < 0.6 else 0.30)]  # within tolerance of truth
    combined = float(np.median([r[1] for r in near])) if near else best[0][1]
    return {
        "fs": round(fs, 2),
        "true_hz": true_hz, "true_bpm": round(true_hz * 60, 1),
        "best_subcarriers": [int(r[0]) for r in best],
        "best_peak_bpm": round(np.median([r[1] for r in best]) * 60, 1),
        "combined_bpm": round(combined * 60, 1),
        "n_subcarriers_near_truth": len(near),
        "median_snr_near": round(float(np.median([r[2] for r in near])), 2) if near else 0.0,
        "detectable": len(near) >= 3,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--node", required=True)
    ap.add_argument("--person", default="")
    ap.add_argument("--hr", type=float, help="ground-truth heart rate (bpm)")
    ap.add_argument("--br", type=float, help="ground-truth breathing rate (br/min)")
    ap.add_argument("--secs", type=float, default=60)
    ap.add_argument("--base", default="http://127.0.0.1:8790")
    args = ap.parse_args()

    ts, amp, span = pull_raw(args.base, args.node, args.secs)
    print(f"pulled {amp.shape[0] if amp.size else 0} frames over {span}s from {args.node}")
    if amp.size == 0 or amp.shape[0] < 200:
        print("  NOT ENOUGH DATA — is the person lying near the node and is it streaming?")
        return
    fs = (ts.size - 1) / (ts[-1] - ts[0])
    print(f"  measured rate: {fs:.1f} frames/s\n")

    profile = {"person": args.person, "node": args.node, "fs": round(fs, 2)}

    if args.br:
        r = analyze(ts, amp, args.br / 60.0, 0.1, 0.6, "breathing")
        print(f"BREATHING — truth {args.br} br/min:")
        if r:
            print(f"  sensor combined: {r['combined_bpm']} br/min  | error {r['combined_bpm']-args.br:+.1f}")
            print(f"  detectable: {r['detectable']}  ({r['n_subcarriers_near_truth']} subcarriers see it, SNR {r['median_snr_near']})")
            profile["breathing"] = r
        else:
            print("  no usable spectrum")

    if args.hr:
        r = analyze(ts, amp, args.hr / 60.0, 0.7, 2.2, "heart")
        print(f"HEART — truth {args.hr} bpm:")
        if r:
            print(f"  sensor combined: {r['combined_bpm']} bpm  | error {r['combined_bpm']-args.hr:+.1f}")
            print(f"  detectable: {r['detectable']}  ({r['n_subcarriers_near_truth']} subcarriers peak at the true rate, SNR {r['median_snr_near']})")
            if r["detectable"]:
                print("  ✅ heartbeat IS present in this node's signal — tuning saved.")
            else:
                print("  ⚠ heartbeat NOT cleanly present — this node/position can't see HR reliably.")
                print("    Options: move ESP closer/beside chest height, or run breathing-only here.")
            profile["heart"] = r
        else:
            print("  no usable spectrum")

    # persist the per-node/person profile
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        allp = {}
        if os.path.exists(PROFILE_PATH):
            allp = json.load(open(PROFILE_PATH))
        allp[f"{args.node}|{args.person}"] = profile
        json.dump(allp, open(PROFILE_PATH, "w"), indent=2)
        print(f"\nsaved profile -> {PROFILE_PATH}  key '{args.node}|{args.person}'")
    except Exception as e:
        print("profile save failed:", e)


if __name__ == "__main__":
    main()
