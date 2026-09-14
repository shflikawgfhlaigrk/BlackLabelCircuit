#!/usr/bin/env python3
"""Rebuild the portable zip from the previous one, replacing only the launcher and README."""
import sys, zipfile, os
src, out = sys.argv[1], sys.argv[2]
here = os.path.dirname(os.path.abspath(__file__))
replace = {'BlackLabelCircuit/README.txt': 'README.txt', 'BlackLabelCircuit/Launch Circuit.cmd': 'Launch Circuit.cmd'}
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as zout:
    names = zin.namelist()
    for info in zin.infolist():
        if info.filename in replace:
            continue
        zout.writestr(info, zin.read(info.filename))
    for name, local in replace.items():
        assert name in names, name
        zout.write(os.path.join(here, local), name)
print('wrote', out)
