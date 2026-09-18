"""Fall-detection track (C1-C4): gate1 energy trigger, gate2 spectrogram
CNN, EMD augmentation, gate3 fusion + alerting.

Operating envelope: everything in this package is tuned and tested on
synthetic CSI (vigil.synth). Detection thresholds and classifier accuracy
numbers are *synthetic-data* numbers until recorded B4 sessions and a
crash-mat live test exist. Submodules import numpy/scipy only at top level;
optional deps (onnx, coremltools, twilio) and the parallel B-track modules
(vigil.cleaning, vigil.spectral) are imported lazily inside the functions
that need them, so a missing module raises only when that entry point is
actually used.
"""

from importlib import import_module

_SUBMODULES = ("gate1", "gate2", "emd", "fusion", "alerts")

__all__ = list(_SUBMODULES)


def __getattr__(name: str):
    if name in _SUBMODULES:
        return import_module(f".{name}", __name__)
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
