#!/usr/bin/env python3
"""
Raw-CSI capture probe — records per-subcarrier CSI from every node so we can
analyze subcarrier responsiveness and prove a better motion metric offline.

Binds :5005 (stop the Sentinel first), runs the same engine-feed keepalive so
boards don't starve, and records two labeled phases (still / moving) of raw
amplitude[56] per node into an .npz for analysis.

    python3 csi_capture.py --secs 15 --out /tmp/csi_still.npz   --label still
    python3 csi_capture.py --secs 15 --out /tmp/csi_moving.npz  --label moving
"""
import argparse, json, socket, threading, time
import numpy as np

SUB = 56

def parse(obj):
    raw = obj.get("csi")
    if not raw: return None
    a = np.asarray(raw, dtype=np.float32)
    even = (a.size//2)*2
    if even < 2: return None
    iq = a[:even].reshape(-1,2)
    csi = iq[:,0] + 1j*iq[:,1]
    csi = csi[:SUB] if csi.size>=SUB else np.pad(csi,(0,SUB-csi.size))
    return np.abs(csi).astype(np.float32)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--secs", type=float, default=15)
    ap.add_argument("--out", required=True)
    ap.add_argument("--label", default="")
    ap.add_argument("--csi-port", type=int, default=5005)
    ap.add_argument("--feed-port", type=int, default=5006)
    ap.add_argument("--feed-hz", type=int, default=110)
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", args.csi_port))
    sock.settimeout(0.5)

    data = {}     # node_id -> list of (ts, amp[56])
    nodes_seen = set()
    stop = False

    def feeder():
        fs = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        pkt = b"hf-csi-keepalive"
        while not stop:
            for nid in list(nodes_seen):
                for _ in range(4):
                    try: fs.sendto(pkt, (nid, args.feed_port))
                    except OSError: pass
            time.sleep(4.0/max(20,args.feed_hz))
    threading.Thread(target=feeder, daemon=True).start()

    print(f"capturing '{args.label}' for {args.secs}s — GO")
    t0 = time.time()
    while time.time()-t0 < args.secs:
        try:
            buf, addr = sock.recvfrom(16384)
        except socket.timeout:
            continue
        try:
            amp = parse(json.loads(buf.decode("utf-8","ignore")))
            if amp is None: continue
            nid = addr[0]
            nodes_seen.add(nid)
            data.setdefault(nid, []).append((time.time(), amp))
        except Exception:
            continue
    stop = True
    sock.close()

    out = {"label": args.label}
    for nid, rows in data.items():
        ts = np.array([r[0] for r in rows], dtype=np.float64)
        amp = np.stack([r[1] for r in rows]) if rows else np.zeros((0,SUB))
        key = nid.replace(".","_")
        out[f"amp_{key}"] = amp
        out[f"ts_{key}"] = ts
        rate = len(rows)/args.secs
        print(f"  {nid:<15} {len(rows):>5} frames  {rate:>5.1f}/s  amp[{amp.shape}]")
    np.savez(args.out, **out)
    print(f"saved {args.out}")

if __name__ == "__main__":
    main()
