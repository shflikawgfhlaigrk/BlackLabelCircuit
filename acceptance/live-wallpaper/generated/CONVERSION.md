# BlackLabelLiveWallpaper — converted for windows by Circuit

Generated 2026-09-22T00:43:48.000Z from `/Users/michaelbarber/BlackLabelLiveWallpaper`. The source repo was not modified.

Source read: 1 files, sha256 `c3ad978d0b11fda5` (git c3972f7ea + 5 uncommitted change(s)).

**Not verified.** The rewrites were applied but no compiler has judged them. Run `--convert … --verify`.

## WinUI source generation

1 view(s) generated under `winui/`; 1 of 11 recognized UI nodes (9.1%) and 18 explicit residual(s).

**Mac-generated source only. This is not a real-Windows compile, install, launch, accessibility, packaging, or feature-parity verification.**


## Complete Windows application

Circuit generated a complete `live-wallpaper` project under `windows-app/` with 10 required feature rows and **0 required residuals**.

The generated application still requires the real-Windows compile, install, launch, package, and parity receipt before acceptance.


| | Files | Lines |
|---|---:|---:|
| Builds for Windows unchanged | 0 | 0 |
| Converted, builds for Windows | 0 | 0 |
| Builds for Windows with some declarations kept for the Mac | 0 | 0 build · 0 isolated |
| Needs a Windows part (kept byte-for-byte for the Mac build, compiled out elsewhere) | 0 | 0 |
| Not verified | 1 | 561 |
| **Total app code considered** | **1** | **561** |

## Build it

```sh
swift build                                   # Windows, Linux or macOS
swift build -Xswiftc -DCIRCUIT_WINDOWS_SIM       # on a Mac: the Windows configuration
```

`.github/workflows/circuit-windows-build.yml` runs the same build on a Windows runner.
