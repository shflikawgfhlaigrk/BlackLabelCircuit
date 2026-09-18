"""C2 — Gate 2: compact pure-numpy spectrogram CNN (DenseNet-flavored).

Operating envelope: classifies a single spectrogram window (nominally a 4 s
window at 100 Hz through a 0.5 s / 0.1 s-hop STFT → 36 frames × 26 bins ×
4 channels, but any [f, b, c] with f,b ≥ 8 works — the head is a global
average pool, so spatial size is free; channel count is fixed at train
time). Architecture: conv3x3(16) → 2 dense blocks (each 2 × [BN-ReLU-
conv3x3(growth 12)] with channel concat) each followed by a 2×2 avg-pool
transition → global avg pool → dense softmax over CLASSES. ~16k learnable
parameters (asserted < 2M). Trained with Adam + cross-entropy, seed-
deterministic. No torch: conv is im2col matmul, backward is hand-written.
Optional deps are lazy: `onnx` only inside export_onnx, `coremltools` only
inside export_coreml (RuntimeError with install hint if missing),
vigil.cleaning/vigil.spectral only inside spectrogram_window (with a local
scipy STFT fallback for standalone use). Accuracy numbers quoted anywhere
for this model are synthetic-data numbers until B4 recordings exist.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

import numpy as np

# Class order is fixed by CONTRACTS.md §6.
CLASSES = ["fall", "sit", "object", "pet", "walk", "other"]


# ---------------------------------------------------------------------------
# numpy layer primitives (NCHW)
# ---------------------------------------------------------------------------

def _im2col(x: np.ndarray, k: int = 3, pad: int = 1) -> np.ndarray:
    n, c, h, w = x.shape
    xp = np.pad(x, ((0, 0), (0, 0), (pad, pad), (pad, pad)))
    v = np.lib.stride_tricks.sliding_window_view(xp, (k, k), axis=(2, 3))
    return np.ascontiguousarray(v.transpose(0, 2, 3, 1, 4, 5).reshape(n, h * w, c * k * k))


def _conv_fwd(x, W, b):
    # single 2-D GEMM over the flattened batch (batched 3-D matmul is far
    # slower in numpy) — cols cached as [n*h*w, c*k*k] float32
    n, c, h, w = x.shape
    cols = _im2col(x).reshape(n * h * w, c * 9)
    out = cols @ W.T + b
    return (
        out.reshape(n, h * w, W.shape[0]).transpose(0, 2, 1).reshape(n, W.shape[0], h, w),
        cols,
    )


def _conv_bwd(dout, cols, W, x_shape, need_dx: bool = True):
    # dW/db from the cached im2col GEMM; dx (when needed) as another GEMM
    # convolution of dout with the spatially-flipped, in/out-swapped kernel
    # (equivalent to col2im scatter, but ~10x faster than strided adds).
    n, c, h, w = x_shape
    co = W.shape[0]
    d2 = np.ascontiguousarray(
        dout.reshape(n, co, h * w).transpose(0, 2, 1)).reshape(n * h * w, co)
    # (cols.T @ d2).T instead of d2.T @ cols: OpenBLAS is ~50x slower on the
    # tiny-M/huge-K orientation of this GEMM
    dW = (cols.T @ d2).T
    db = d2.sum(0)
    dx = None
    if need_dx:
        Wf = np.ascontiguousarray(
            W.reshape(co, c, 3, 3)[:, :, ::-1, ::-1].transpose(1, 0, 2, 3)
        ).reshape(c, co * 9)
        dx, _ = _conv_fwd(dout, Wf, np.zeros(c, dtype=dout.dtype))
    return dx, dW, db


def _bn_fwd(x, g, b, rm, rv, train: bool, momentum: float = 0.9, eps: float = 1e-5):
    if train:
        mu = x.mean((0, 2, 3))
        var = x.var((0, 2, 3))
        rm *= momentum
        rm += (1 - momentum) * mu
        rv *= momentum
        rv += (1 - momentum) * var
    else:
        mu, var = rm, rv
    inv = 1.0 / np.sqrt(var + eps)
    xhat = (x - mu[None, :, None, None]) * inv[None, :, None, None]
    return g[None, :, None, None] * xhat + b[None, :, None, None], (xhat, inv, g)


def _bn_bwd(dy, cache):
    xhat, inv, g = cache
    n, c, h, w = dy.shape
    m = n * h * w
    dg = (dy * xhat).sum((0, 2, 3))
    db = dy.sum((0, 2, 3))
    dxh = dy * g[None, :, None, None]
    dx = (inv[None, :, None, None] / m) * (
        m * dxh
        - dxh.sum((0, 2, 3), keepdims=True)
        - xhat * (dxh * xhat).sum((0, 2, 3), keepdims=True)
    )
    return dx, dg, db


def _pool_fwd(x):
    n, c, h, w = x.shape
    h2, w2 = h // 2, w // 2
    y = x[:, :, : h2 * 2, : w2 * 2].reshape(n, c, h2, 2, w2, 2).mean((3, 5))
    return y, (h, w)


def _pool_bwd(dy, hw):
    h, w = hw
    n, c, h2, w2 = dy.shape
    dx = np.zeros((n, c, h, w), dy.dtype)
    dx[:, :, : h2 * 2, : w2 * 2] = np.repeat(np.repeat(dy, 2, 2), 2, 3) / 4.0
    return dx


def _softmax(z):
    z = z - z.max(axis=1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=1, keepdims=True)


# ---------------------------------------------------------------------------
# classifier
# ---------------------------------------------------------------------------

class Gate2Classifier:
    """Compact DenseNet-flavored CNN over spectrogram windows (see module
    docstring). API per CONTRACTS §8."""

    def __init__(self, base_ch: int = 16, growth: int = 12,
                 n_blocks: int = 2, block_layers: int = 2) -> None:
        self.base_ch = int(base_ch)
        self.growth = int(growth)
        self.n_blocks = int(n_blocks)
        self.block_layers = int(block_layers)
        self.n_classes = len(CLASSES)
        self.in_ch: int | None = None
        self.eps = 1e-5
        self.p: dict[str, np.ndarray] = {}       # learnable params
        self.rs: dict[str, np.ndarray] = {}      # BN running stats
        self.last_train: dict = {}
        self.last_kfold: dict = {}
        self._adam: dict = {}
        self._adam_t = 0

    # -- construction -------------------------------------------------------

    def _layer_names(self):
        for bi in range(self.n_blocks):
            for li in range(self.block_layers):
                yield bi, li, f"b{bi}l{li}"

    def _in_channels(self, bi: int, li: int) -> int:
        ch = self.base_ch
        for b in range(bi):
            ch += self.block_layers * self.growth
        return ch + li * self.growth

    @property
    def feat_ch(self) -> int:
        return self.base_ch + self.n_blocks * self.block_layers * self.growth

    def _init_params(self, in_ch: int, seed: int) -> None:
        rng = np.random.default_rng(seed)
        self.in_ch = in_ch
        p, rs = {}, {}
        p["W0"] = (rng.standard_normal((self.base_ch, in_ch * 9))
                   * np.sqrt(2.0 / (in_ch * 9))).astype(np.float32)
        p["b0"] = np.zeros(self.base_ch, np.float32)
        for bi, li, nm in self._layer_names():
            cin = self._in_channels(bi, li)
            p[f"g_{nm}"] = np.ones(cin, np.float32)
            p[f"be_{nm}"] = np.zeros(cin, np.float32)
            rs[f"rm_{nm}"] = np.zeros(cin, np.float32)
            rs[f"rv_{nm}"] = np.ones(cin, np.float32)
            p[f"W_{nm}"] = (rng.standard_normal((self.growth, cin * 9))
                            * np.sqrt(2.0 / (cin * 9))).astype(np.float32)
            p[f"b_{nm}"] = np.zeros(self.growth, np.float32)
        p["Wd"] = (rng.standard_normal((self.feat_ch, self.n_classes))
                   * np.sqrt(1.0 / self.feat_ch)).astype(np.float32)
        p["bd"] = np.zeros(self.n_classes, np.float32)
        self.p, self.rs = p, rs
        self._adam, self._adam_t = {}, 0

    @property
    def n_params(self) -> int:
        """Learnable parameter count (conv/dense weights+biases, BN affine)."""
        return int(sum(v.size for v in self.p.values()))

    # -- forward / backward --------------------------------------------------

    def _forward(self, x: np.ndarray, train: bool):
        caches: dict = {"x_shape": x.shape}
        h, caches["cols0"] = _conv_fwd(x, self.p["W0"], self.p["b0"])
        feats = h
        for bi in range(self.n_blocks):
            for li in range(self.block_layers):
                nm = f"b{bi}l{li}"
                y, caches[f"bn_{nm}"] = _bn_fwd(
                    feats, self.p[f"g_{nm}"], self.p[f"be_{nm}"],
                    self.rs[f"rm_{nm}"], self.rs[f"rv_{nm}"], train, eps=self.eps)
                mask = y > 0
                r = y * mask
                caches[f"mask_{nm}"] = mask
                caches[f"rshape_{nm}"] = r.shape
                c, caches[f"cols_{nm}"] = _conv_fwd(r, self.p[f"W_{nm}"], self.p[f"b_{nm}"])
                feats = np.concatenate([feats, c], axis=1)
            feats, caches[f"pool{bi}"] = _pool_fwd(feats)
        caches["pre_gap_shape"] = feats.shape
        gap = feats.mean((2, 3))
        caches["gap_in"] = gap
        logits = gap @ self.p["Wd"] + self.p["bd"]
        return _softmax(logits), caches

    def _backward(self, probs, y_onehot, caches):
        grads: dict[str, np.ndarray] = {}
        n = probs.shape[0]
        dlog = (probs - y_onehot) / n
        gap = caches["gap_in"]
        grads["Wd"] = gap.T @ dlog
        grads["bd"] = dlog.sum(0)
        dgap = dlog @ self.p["Wd"].T
        _, _, hh, ww = caches["pre_gap_shape"]
        dfeats = np.broadcast_to(
            dgap[:, :, None, None] / (hh * ww),
            caches["pre_gap_shape"]).astype(np.float32).copy()
        for bi in range(self.n_blocks - 1, -1, -1):
            dfeats = _pool_bwd(dfeats, caches[f"pool{bi}"])
            for li in range(self.block_layers - 1, -1, -1):
                nm = f"b{bi}l{li}"
                cin = self._in_channels(bi, li)
                d_prev = dfeats[:, :cin]
                d_new = dfeats[:, cin:]
                dr, dWc, dbc = _conv_bwd(
                    d_new, caches[f"cols_{nm}"], self.p[f"W_{nm}"],
                    caches[f"rshape_{nm}"])
                grads[f"W_{nm}"] = dWc
                grads[f"b_{nm}"] = dbc
                dy = dr * caches[f"mask_{nm}"]
                dxbn, dg, dbe = _bn_bwd(dy, caches[f"bn_{nm}"])
                grads[f"g_{nm}"] = dg
                grads[f"be_{nm}"] = dbe
                dfeats = d_prev + dxbn
        _, dW0, db0 = _conv_bwd(dfeats, caches["cols0"], self.p["W0"],
                                caches["x_shape"], need_dx=False)
        grads["W0"] = dW0
        grads["b0"] = db0
        return grads

    def _adam_step(self, grads, lr, b1=0.9, b2=0.999, eps=1e-8):
        self._adam_t += 1
        t = self._adam_t
        for k, g in grads.items():
            m, v = self._adam.get(k, (np.zeros_like(g), np.zeros_like(g)))
            m = b1 * m + (1 - b1) * g
            v = b2 * v + (1 - b2) * g * g
            self._adam[k] = (m, v)
            mh = m / (1 - b1 ** t)
            vh = v / (1 - b2 ** t)
            self.p[k] -= lr * mh / (np.sqrt(vh) + eps)

    @staticmethod
    def _to_nchw(X: np.ndarray) -> np.ndarray:
        X = np.asarray(X, dtype=np.float32)
        if X.ndim == 3:
            X = X[None]
        return X.transpose(0, 3, 1, 2)  # [n,f,b,c] -> [n,c,f,b]

    # -- public API -----------------------------------------------------------

    def train(self, X: np.ndarray, y: np.ndarray, seed: int = 0,
              epochs: int = 30, lr: float = 3e-3, batch_size: int = 32,
              augment=None, verbose: bool = False) -> dict:
        """Train from scratch (re-initializes with `seed`). `augment`, if
        given, is a callable (X, y) -> (X_aug, y_aug) — e.g. vigil.falls.emd
        .augment — applied to the *training* data only, here at entry (in
        kfold it is applied per training fold)."""
        y = np.asarray(y, dtype=int)
        if augment is not None:
            X, y = augment(X, y)
            y = np.asarray(y, dtype=int)
        Xn = self._to_nchw(X)
        n = Xn.shape[0]
        self._init_params(Xn.shape[1], seed)
        rng = np.random.default_rng(seed + 1)
        onehot = np.eye(self.n_classes, dtype=np.float32)[y]
        loss = float("nan")
        for ep in range(epochs):
            order = rng.permutation(n)
            losses = []
            for i0 in range(0, n, batch_size):
                idx = order[i0:i0 + batch_size]
                probs, caches = self._forward(Xn[idx], train=True)
                losses.append(-np.mean(np.log(probs[np.arange(len(idx)), y[idx]] + 1e-12)))
                grads = self._backward(probs, onehot[idx], caches)
                self._adam_step(grads, lr)
            loss = float(np.mean(losses))
            if verbose:
                print(f"  epoch {ep + 1}/{epochs} loss={loss:.4f}")
        acc = float(np.mean(self.predict(X) == y))
        self.last_train = {"epochs": epochs, "lr": lr, "n": int(n),
                           "final_loss": loss, "train_acc": acc, "seed": seed}
        return dict(self.last_train)

    def predict(self, X: np.ndarray, batch_size: int = 64) -> np.ndarray:
        Xn = self._to_nchw(X)
        out = []
        for i0 in range(0, Xn.shape[0], batch_size):
            probs, _ = self._forward(Xn[i0:i0 + batch_size], train=False)
            out.append(np.argmax(probs, axis=1))
        return np.concatenate(out)

    def classify(self, spec_window: np.ndarray) -> tuple[str, np.ndarray]:
        """Single window [f,b,c] -> (label, probs[6])."""
        if not self.p:
            raise RuntimeError("classifier not trained/loaded")
        probs, _ = self._forward(self._to_nchw(spec_window), train=False)
        probs = probs[0]
        return CLASSES[int(np.argmax(probs))], probs.astype(np.float64)

    # -- persistence -----------------------------------------------------------

    def save(self, path: str | Path) -> None:
        meta = {"base_ch": self.base_ch, "growth": self.growth,
                "n_blocks": self.n_blocks, "block_layers": self.block_layers,
                "in_ch": self.in_ch, "classes": CLASSES,
                "last_train": self.last_train, "last_kfold": self.last_kfold}
        arrays = {f"p_{k}": v for k, v in self.p.items()}
        arrays.update({f"rs_{k}": v for k, v in self.rs.items()})
        arrays["meta_json"] = np.frombuffer(
            json.dumps(meta).encode("utf-8"), dtype=np.uint8)
        np.savez_compressed(Path(path), **arrays)

    def load(self, path: str | Path) -> "Gate2Classifier":
        with np.load(Path(path)) as z:
            meta = json.loads(bytes(z["meta_json"]).decode("utf-8"))
            self.base_ch = meta["base_ch"]
            self.growth = meta["growth"]
            self.n_blocks = meta["n_blocks"]
            self.block_layers = meta["block_layers"]
            self.in_ch = meta["in_ch"]
            self.last_train = meta.get("last_train", {})
            self.last_kfold = meta.get("last_kfold", {})
            self.p = {k[2:]: z[k].copy() for k in z.files if k.startswith("p_")}
            self.rs = {k[3:]: z[k].copy() for k in z.files if k.startswith("rs_")}
        self._adam, self._adam_t = {}, 0
        return self

    # -- exports -----------------------------------------------------------------

    def export_onnx(self, path: str | Path) -> None:
        """Export the inference graph (BN in inference mode with running
        stats) as ONNX. Lazy `onnx` import; graph is validated with
        onnx.checker before writing."""
        try:
            import onnx
            from onnx import TensorProto, helper, numpy_helper
        except ImportError as exc:  # pragma: no cover
            raise RuntimeError("onnx not installed — pip install onnx") from exc
        if not self.p:
            raise RuntimeError("classifier not trained/loaded")
        init = []

        def tens(name, arr):
            init.append(numpy_helper.from_array(np.asarray(arr, np.float32), name))
            return name

        nodes = []
        tens("W0", self.p["W0"].reshape(self.base_ch, self.in_ch, 3, 3))
        tens("b0", self.p["b0"])
        nodes.append(helper.make_node(
            "Conv", ["input", "W0", "b0"], ["h0"],
            kernel_shape=[3, 3], pads=[1, 1, 1, 1]))
        cur = "h0"
        for bi in range(self.n_blocks):
            for li in range(self.block_layers):
                nm = f"b{bi}l{li}"
                cin = self._in_channels(bi, li)
                tens(f"g_{nm}", self.p[f"g_{nm}"])
                tens(f"be_{nm}", self.p[f"be_{nm}"])
                tens(f"rm_{nm}", self.rs[f"rm_{nm}"])
                tens(f"rv_{nm}", self.rs[f"rv_{nm}"])
                nodes.append(helper.make_node(
                    "BatchNormalization",
                    [cur, f"g_{nm}", f"be_{nm}", f"rm_{nm}", f"rv_{nm}"],
                    [f"bn_{nm}"], epsilon=self.eps))
                nodes.append(helper.make_node("Relu", [f"bn_{nm}"], [f"relu_{nm}"]))
                tens(f"W_{nm}", self.p[f"W_{nm}"].reshape(self.growth, cin, 3, 3))
                tens(f"bc_{nm}", self.p[f"b_{nm}"])
                nodes.append(helper.make_node(
                    "Conv", [f"relu_{nm}", f"W_{nm}", f"bc_{nm}"], [f"conv_{nm}"],
                    kernel_shape=[3, 3], pads=[1, 1, 1, 1]))
                nodes.append(helper.make_node(
                    "Concat", [cur, f"conv_{nm}"], [f"cat_{nm}"], axis=1))
                cur = f"cat_{nm}"
            nodes.append(helper.make_node(
                "AveragePool", [cur], [f"pool{bi}"],
                kernel_shape=[2, 2], strides=[2, 2]))
            cur = f"pool{bi}"
        nodes.append(helper.make_node("GlobalAveragePool", [cur], ["gap"]))
        nodes.append(helper.make_node("Flatten", ["gap"], ["feat"], axis=1))
        tens("Wd", self.p["Wd"].T)  # Gemm with transB=1 wants [out, in]
        tens("bd", self.p["bd"])
        nodes.append(helper.make_node(
            "Gemm", ["feat", "Wd", "bd"], ["logits"], transB=1))
        nodes.append(helper.make_node("Softmax", ["logits"], ["probs"], axis=1))
        graph = helper.make_graph(
            nodes, "gate2_densenet",
            [helper.make_tensor_value_info(
                "input", TensorProto.FLOAT, ["N", self.in_ch, "H", "W"])],
            [helper.make_tensor_value_info(
                "probs", TensorProto.FLOAT, ["N", self.n_classes])],
            init)
        model = helper.make_model(
            graph, opset_imports=[helper.make_opsetid("", 17)],
            producer_name="vigil-gate2")
        model.ir_version = 8
        onnx.checker.check_model(model, full_check=True)
        onnx.save(model, str(path))

    def export_coreml(self, path: str | Path) -> None:
        """CoreML export (guarded — coremltools is an optional dep)."""
        try:
            import coremltools  # noqa: F401
        except ImportError as exc:
            raise RuntimeError(
                "coremltools not installed — pip install coremltools to "
                "export a CoreML model (ONNX export works without it)"
            ) from exc
        raise RuntimeError(
            "CoreML export path is gated: coremltools' modern converters "
            "require a torch/tensorflow source model. Use export_onnx() and "
            "convert offline.")  # pragma: no cover

    # -- evaluation -------------------------------------------------------------

    def kfold(self, X: np.ndarray, y: np.ndarray, k: int = 5, seed: int = 0,
              epochs: int = 20, lr: float = 3e-3, batch_size: int = 32,
              augment=None) -> dict:
        """Stratified k-fold cross-validation. `augment` (if given) is
        applied to each *training* fold only — validation always scores real
        samples. Returns and stores a benchmark-report-friendly dict."""
        X = np.asarray(X)
        y = np.asarray(y, dtype=int)
        rng = np.random.default_rng(seed)
        folds: list[list[int]] = [[] for _ in range(k)]
        for cls in np.unique(y):
            idx = rng.permutation(np.where(y == cls)[0])
            for j, i in enumerate(idx):
                folds[j % k].append(int(i))
        conf = np.zeros((self.n_classes, self.n_classes), dtype=int)
        for fi in range(k):
            va = np.asarray(folds[fi], dtype=int)
            tr = np.asarray([i for fj in range(k) if fj != fi for i in folds[fj]],
                            dtype=int)
            m = Gate2Classifier(self.base_ch, self.growth,
                                self.n_blocks, self.block_layers)
            m.train(X[tr], y[tr], seed=seed + fi, epochs=epochs, lr=lr,
                    batch_size=batch_size, augment=augment)
            pred = m.predict(X[va])
            for t, pr in zip(y[va], pred):
                conf[t, pr] += 1
        per_class = {}
        for ci, cname in enumerate(CLASSES):
            tp = int(conf[ci, ci])
            support = int(conf[ci].sum())
            predicted = int(conf[:, ci].sum())
            per_class[cname] = {
                "precision": tp / predicted if predicted else 0.0,
                "recall": tp / support if support else 0.0,
                "support": support,
            }
        fall_i = CLASSES.index("fall")
        non_fall = [i for i in range(self.n_classes) if i != fall_i]
        n_nonfall = int(conf[non_fall].sum())
        fp_fall = int(conf[non_fall, fall_i].sum())
        confounders = [CLASSES.index(c) for c in ("sit", "object", "pet", "walk")]
        n_conf = int(conf[confounders].sum())
        fp_conf = int(conf[confounders, fall_i].sum())
        report = {
            "k": k,
            "seed": seed,
            "epochs": epochs,
            "confusion": conf.tolist(),
            "classes": CLASSES,
            "per_class": per_class,
            "accuracy": float(np.trace(conf) / conf.sum()) if conf.sum() else 0.0,
            "fall_recall": per_class["fall"]["recall"],
            "fall_fp_rate_nonfall": fp_fall / n_nonfall if n_nonfall else 0.0,
            "fall_fp_rate_confounders": fp_conf / n_conf if n_conf else 0.0,
        }
        self.last_kfold = report
        return report

    def to_report_dict(self) -> dict:
        """Benchmark-report-friendly summary (E3 embeds this in report.html)."""
        return {
            "model": "Gate2Classifier",
            "arch": {
                "base_ch": self.base_ch, "growth": self.growth,
                "n_blocks": self.n_blocks, "block_layers": self.block_layers,
                "feat_ch": self.feat_ch, "in_ch": self.in_ch,
            },
            "classes": CLASSES,
            "n_params": self.n_params if self.p else 0,
            "train": self.last_train,
            "kfold": self.last_kfold,
            "measured_on": "synthetic (vigil.synth) — real-data numbers gated on B4 recordings",
        }


# ---------------------------------------------------------------------------
# feature extraction from a Session
# ---------------------------------------------------------------------------

def _local_spectrogram(window: np.ndarray, fs: float = 100.0,
                       nperseg: int = 50, hop: int = 10) -> np.ndarray:
    """Standalone fallback feature extractor (documented fallback — used
    when vigil.cleaning / vigil.spectral are not importable, e.g. while
    Track B is in flight): remove the static per-subcarrier profile, average
    the 52 subcarriers into 4 groups of 13, STFT each group (0.5 s Hann /
    0.1 s hop) and stack log1p magnitudes -> [n_frames, n_bins, 4] float32."""
    from scipy import signal

    x = np.asarray(window, dtype=np.float64)
    x = x - x.mean(axis=0, keepdims=True)
    n_sub = x.shape[1]
    g = max(1, n_sub // 4)
    chans = [x[:, i * g:(i + 1) * g if i < 3 else n_sub].mean(axis=1) for i in range(4)]
    specs = []
    for series in chans:
        _, _, Z = signal.stft(series, fs=fs, window="hann", nperseg=nperseg,
                              noverlap=nperseg - hop, boundary=None, padded=False)
        specs.append(np.log1p(np.abs(Z)).T)  # [frames, bins]
    return np.stack(specs, axis=-1).astype(np.float32)


def spectrogram_window(session, node_id: int, t_center: float,
                       fs: float = 100.0) -> np.ndarray:
    """Extract the Gate-2 input for one node around `t_center`: a 4 s amps
    window through CleaningStage.process + SpectralStage (auto-fit on the
    window itself is acceptable for a 4 s excerpt) -> [f, b, 4] float32.

    vigil.cleaning / vigil.spectral are imported lazily *here* (CONTRACTS
    §8); if they are missing (Track B in flight) this falls back to
    `_local_spectrogram`, which produces the same [36, 26, 4] shape for the
    nominal 0.5 s / 0.1 s STFT — that fallback is for standalone use and is
    not the production feature path.
    """
    half = 2.0
    a = session.amps[node_id]
    n = int(4 * fs)
    i0 = int((t_center - half) * fs)
    i0 = max(0, min(i0, max(0, a.shape[0] - n)))
    win = a[i0:i0 + n]
    if win.shape[0] < n:  # pad short sessions at the edge
        win = np.pad(win, ((0, n - win.shape[0]), (0, 0)), mode="edge")
    try:
        from ..cleaning import CleaningStage
        from ..spectral import SpectralStage
    except ImportError:
        return _local_spectrogram(win, fs=fs)
    try:
        clean = CleaningStage(fs=fs).process(win.astype(np.float32))
        stage = SpectralStage(fs=fs)
        stage.fit(clean.motion)  # auto-fit on the excerpt
        res = stage.transform(clean.motion)
        return np.asarray(res.spectrogram, dtype=np.float32)
    except Exception:
        # B-track present but incompatible/failed on this excerpt: degrade
        # to the standalone path rather than dropping the candidate.
        return _local_spectrogram(win, fs=fs)


def benchmark_inference(classifier: Gate2Classifier, spec_window: np.ndarray,
                        n_iter: int = 20) -> float:
    """Median single-window classify() latency in milliseconds."""
    classifier.classify(spec_window)  # warm-up
    times = []
    for _ in range(n_iter):
        t0 = time.perf_counter()
        classifier.classify(spec_window)
        times.append((time.perf_counter() - t0) * 1000.0)
    return float(np.median(times))
