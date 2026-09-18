"""
Homefront — WiFi-CSI pose inference (clean-room Python port).

A from-scratch NumPy reimplementation of the WiFi-DensePose pose network.
No Rust, no PyTorch, no Candle — just NumPy. We load the published MIT-licensed
trained weights (pose_v1.safetensors) and run the exact documented graph:

    Conv1d(56 -> 64,  k=3, dilation=1, padding=1) -> ReLU
    Conv1d(64 -> 128, k=3, dilation=2, padding=2) -> ReLU
    Conv1d(128-> 128, k=3, dilation=4, padding=4) -> ReLU
    GlobalAvgPool(time)                            -> [128]
    Linear(128 -> 256) -> ReLU
    Linear(256 -> 34)  -> Sigmoid                  -> 17 keypoints x (x, y) in [0,1]

Input is a [56 subcarriers x 20 frames] CSI amplitude window.

Honest accuracy (from the model card, 217 held-out samples):
    PCK@50 = 18.5% overall — coarse body structure only. r_hip/r_knee/torso
    carry real signal; wrists / ankles / face joints are near-random at the
    56-subcarrier / 20-frame resolution. Treat the skeleton as a coarse torso
    pose, not crisp full-body tracking.

Weights: ruvnet/RuView (MIT). See engine/NOTICE for attribution.
"""

import json
import struct
import numpy as np

KEYPOINT_NAMES = [
    "nose", "left_eye", "right_eye", "left_ear", "right_ear",
    "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
    "left_wrist", "right_wrist", "left_hip", "right_hip",
    "left_knee", "right_knee", "left_ankle", "right_ankle",
]

# Per-joint reliability (PCK@50 from the model card) — drives honest per-joint
# confidence in the UI so we never imply a wrist is as trustworthy as a hip.
JOINT_PCK50 = {
    "nose": 0.051, "left_eye": 0.083, "right_eye": 0.157, "left_ear": 0.032,
    "right_ear": 0.097, "left_shoulder": 0.088, "right_shoulder": 0.199,
    "left_elbow": 0.264, "right_elbow": 0.042, "left_wrist": 0.241,
    "right_wrist": 0.120, "left_hip": 0.273, "right_hip": 0.769,
    "left_knee": 0.208, "right_knee": 0.352, "left_ankle": 0.079,
    "right_ankle": 0.093,
}

# COCO-17 skeleton edges (for rendering).
SKELETON_EDGES = [
    (0, 1), (0, 2), (1, 3), (2, 4),            # head
    (5, 6), (5, 7), (7, 9), (6, 8), (8, 10),   # arms
    (5, 11), (6, 12), (11, 12),                # torso
    (11, 13), (13, 15), (12, 14), (14, 16),    # legs
]


def load_safetensors(path):
    """Parse a .safetensors file into {name: np.ndarray} using only stdlib + numpy."""
    with open(path, "rb") as f:
        header_len = struct.unpack("<Q", f.read(8))[0]
        header = json.loads(f.read(header_len))
        blob = f.read()
    header.pop("__metadata__", None)
    dtypes = {"F32": "<f4", "F16": "<f2", "F64": "<f8"}
    out = {}
    for name, meta in header.items():
        np_dtype = dtypes.get(meta["dtype"])
        if np_dtype is None:
            raise ValueError(f"unsupported dtype {meta['dtype']} for {name}")
        start, end = meta["data_offsets"]
        arr = np.frombuffer(blob[start:end], dtype=np_dtype).reshape(meta["shape"])
        out[name] = arr.astype(np.float32).copy()
    return out


def _conv1d(x, w, b, padding, dilation):
    """1-D convolution, stride 1. x:[Cin,L]  w:[Cout,Cin,K]  b:[Cout] -> [Cout,Lout]."""
    cin, length = x.shape
    cout, _, k = w.shape
    xp = np.pad(x, ((0, 0), (padding, padding)))
    lout = xp.shape[1] - dilation * (k - 1)
    acc = np.zeros((cout, lout), dtype=np.float32)
    for tap in range(k):
        seg = xp[:, tap * dilation: tap * dilation + lout]   # [Cin, Lout]
        acc += w[:, :, tap] @ seg                            # [Cout,Cin] @ [Cin,Lout]
    return acc + b[:, None]


def _relu(x):
    return np.maximum(x, 0.0, dtype=np.float32)


class PoseNet:
    """NumPy reimplementation of the WiFi-DensePose pose regressor."""

    def __init__(self, weights):
        self.w = weights

    def forward(self, window):
        """window: [56 subcarriers, 20 frames] -> (17, 2) keypoints in [0,1]."""
        w = self.w
        # numpy + Apple Accelerate (arm64) raises spurious FP-exception warnings
        # during matmul even when the result is finite and correct; ignore them.
        with np.errstate(all="ignore"):
            return self._forward(window)

    def _forward(self, window):
        w = self.w
        # float64 throughout for numerical stability (float32 matmul can overflow).
        x = self._normalize(window.astype(np.float64))
        h = _relu(_conv1d(x, w["enc.c1.weight"].astype(np.float64), w["enc.c1.bias"].astype(np.float64), 1, 1))
        h = _relu(_conv1d(h, w["enc.c2.weight"].astype(np.float64), w["enc.c2.bias"].astype(np.float64), 2, 2))
        h = _relu(_conv1d(h, w["enc.c3.weight"].astype(np.float64), w["enc.c3.bias"].astype(np.float64), 4, 4))
        pooled = h.mean(axis=1)                                       # [128]
        h1 = _relu(w["head.fc1.weight"].astype(np.float64) @ pooled + w["head.fc1.bias"].astype(np.float64))  # [256]
        logits = w["head.fc2.weight"].astype(np.float64) @ h1 + w["head.fc2.bias"].astype(np.float64)         # [34]
        logits = np.clip(logits, -30.0, 30.0)                        # guard sigmoid overflow
        out = 1.0 / (1.0 + np.exp(-logits))                          # sigmoid
        return out.reshape(17, 2)

    @staticmethod
    def _normalize(window):
        """Per-window standardization (zero mean, unit variance).

        The training preprocessing (align-ground-truth.js) is not published, so
        we apply the standard CSI normalization. This keeps inputs in the range
        the network was trained on regardless of absolute amplitude scale.
        """
        mu = window.mean()
        sd = window.std()
        if sd < 1e-6:
            return window - mu
        return (window - mu) / sd

    def keypoints(self, window):
        """Return a list of {name, x, y, reliability} dicts."""
        kp = self.forward(window)
        return [
            {"name": KEYPOINT_NAMES[i], "x": float(kp[i, 0]), "y": float(kp[i, 1]),
             "reliability": JOINT_PCK50[KEYPOINT_NAMES[i]]}
            for i in range(17)
        ]


def load_model(weights_path):
    return PoseNet(load_safetensors(weights_path))
