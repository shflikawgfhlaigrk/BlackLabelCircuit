"""
CSI streamer — proves the CSI reader end-to-end without hardware.

Replays the bundled capture as live UDP CSI frames in the reader's wire format,
exactly as a real ESP32 would. Run `home_engine.py --source udp` in one shell and
this in another; the engine should light up `live=true` and produce pose/range/
vitals from the streamed CSI — same path a real radio drives.

    python csi_sim.py [--host 127.0.0.1 --port 5005 --rate 100]
"""

import argparse
import json
import os
import socket
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=5005)
    ap.add_argument("--rate", type=float, default=100.0)
    ap.add_argument("--tier", default=None,
                    help="mimic a branded node: Homefront-Node | Homefront-Sentry | Homefront-Pulse")
    args = ap.parse_args()

    doc = json.load(open(os.path.join(HERE, "assets", "replay_csi.json")))
    frames = doc["frames"]
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    addr = (args.host, args.port)
    print(f"streaming {len(frames)} CSI frames -> udp {addr} at {args.rate}Hz (Ctrl-C to stop)")

    i = 0
    period = 1.0 / args.rate
    while True:
        fr = frames[i % len(frames)]
        amp = np.asarray(fr["amplitude"], dtype=np.float32).mean(axis=0)  # [56]
        ph = np.asarray(fr["phase"], dtype=np.float32).mean(axis=0)
        csi = amp * np.exp(1j * ph)
        iq = np.empty(csi.size * 2, dtype=np.float32)
        iq[0::2] = csi.real * 64.0      # scale toward ESP32 int8 magnitude
        iq[1::2] = csi.imag * 64.0
        # Honest provenance: this is the SYNTHETIC replay capture, not a real ESP32. The engine
        # reads this flag and suppresses vitals + marks the frame demo, so a fabricated BPM from
        # the synthetic cardiac tone can never be shown as a live measurement (CHARTER 5.1).
        msg = {"csi": [int(round(v)) for v in iq.tolist()], "rssi": -45, "ts": time.time(), "sim": True}
        if args.tier:
            msg["tier"] = args.tier          # stand in for a branded Homefront node
        payload = json.dumps(msg)
        sock.sendto(payload.encode(), addr)
        i += 1
        time.sleep(period)


if __name__ == "__main__":
    main()
