#!/usr/bin/env python3
"""
Per-node calibration — name a node, learn its empty-room baseline, verify clean.

Run with the node PLACED in its spot and the room EMPTY + STILL (the baseline is
what 'quiet' looks like there; motion later is measured against it).

  python3 calibrate_node.py --node 192.168.4.54 --room "Parents Bedroom - NE corner"
"""
import argparse, json, time, urllib.request

BASE = "http://127.0.0.1:8790"

def post(path, body):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    return json.load(urllib.request.urlopen(req, timeout=10))

def get_node(nid):
    d = json.load(urllib.request.urlopen(BASE + "/nodes", timeout=5))
    return next((n for n in d["nodes"] if n["node_id"] == nid), None)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--node", required=True)
    ap.add_argument("--room", required=True)
    ap.add_argument("--settle", type=float, default=14.0, help="empty-room baseline learn time")
    args = ap.parse_args()

    n = get_node(args.node)
    if not n:
        print(f"  ✗ {args.node} is not streaming. Is it powered + on WiFi?")
        return
    if not n["online"]:
        print(f"  ✗ {args.node} is offline.")
        return

    print(f"  naming {args.node} -> '{args.room}'")
    post("/assign", {"node_id": args.node, "room": args.room})

    print(f"  recalibrating empty-room baseline (keep the room still ~{int(args.settle)}s)…")
    post("/recalibrate", {"node_id": args.node})
    time.sleep(args.settle)

    n = get_node(args.node)
    if not n:
        print("  ✗ node dropped during calibration"); return
    cal = n.get("calibrated"); motion = n.get("motion", 0)
    print(f"  calibrated={cal}  empty-room motion floor={motion:.3f}")
    if cal and motion < 0.05:
        print(f"  ✅ {args.node} '{args.room}' calibrated clean (floor {motion:.3f}).")
    elif cal:
        print(f"  ⚠ calibrated but floor is {motion:.3f} (>0.05) — was something moving? re-run when still.")
    else:
        print(f"  ⚠ still calibrating ({int(n.get('calibrating',0)*100)}%) — give it a few more seconds, re-check.")

if __name__ == "__main__":
    main()
