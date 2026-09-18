"""Vigil — Wi-Fi CSI sensing core for Homefront.

Operating envelope: ESP32 WROOM-32 fleet (802.11n HT20, 52 information
subcarriers, amplitude-only CSI) streaming to a single Mac at a nominal
100 Hz per node. Everything downstream of `vigil.ingest` assumes that
contract; see CONTRACTS.md for the binding formats.
"""

__version__ = "0.1.0"

N_SUB = 52
FS = 100.0
