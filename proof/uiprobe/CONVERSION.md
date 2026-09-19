# uiprobe-src — converted for windows by Circuit

Generated 2026-09-19T03:49:40.030Z from `/private/tmp/claude-501/-Users-michaelbarber-Desktop-Black-Label-B-ots-BlackLabel-Team-black-label-city-spec-d2180e/5435c4da-dbf5-4ec9-af9b-866272aed8e6/scratchpad/uiprobe-src`. The source repo was not modified.

Source read: 2 files, sha256 `d81aa387feaa2626` (git cd6387e3b).

**Compiler check: passed** — simulated Windows configuration on macOS (-DCIRCUIT_WINDOWS_SIM); Apple Swift version 6.4 (swiftlang-6.4.0.33.1 clang-2100.3.33.1).

| | Files | Lines |
|---|---:|---:|
| Builds for Windows unchanged | 0 | 0 |
| Converted, builds for Windows | 1 | 15 |
| Builds for Windows with some declarations kept for the Mac | 1 | 1 build · 3 isolated |
| Needs a Windows part (kept byte-for-byte for the Mac build, compiled out elsewhere) | 0 | 0 |
| Left off Windows by the app's own `#if` (in files that build; not counted as building) | 2 | 3 |
| **Total app code considered** | **2** | **19** |

**68.4% of the app code builds for Windows** (13 of 19 lines) — measured by the compiler. The port check's estimate before converting was 0% of lines with no Mac-only parts; it reads imports and cannot see code that leans on a Mac-only file, so the compiler figure is the one to go by.

## Build it

```sh
swift build                                   # Windows, Linux or macOS
swift build -Xswiftc -DCIRCUIT_WINDOWS_SIM       # on a Mac: the Windows configuration
```

`.github/workflows/circuit-windows-build.yml` runs the same build on a Windows runner.

## What replaced the Apple-only parts

- `swift-cross-ui` — https://github.com/moreSwift/swift-cross-ui.git (from 0.9.0)
- `OpenCombine` — https://github.com/OpenCombine/OpenCombine.git (from 0.14.0)
- `CircuitPortKit` (in `kit/`) — Logger / os_log, UTType, the Combine scheduler bridge, and the Keychain (Windows Credential Manager) with SecRandomCopyBytes

## Windows parts still needed

| Apple part | Files | Lines | Size | Windows counterpart |
|---|---:|---:|---|---|
| (uses code that was isolated) | 1 | 3 |  |  |

## Code kept for the Mac only, with the compiler's reason

- `Sources/Symbols.swift` — 3 of 4 lines — 10:32 extraneous argument label 'systemName:' in call (+1 more)

## Converted files

- `Sources/Counter.swift` — SwiftUI → SwiftCrossUI (SwiftUI-style views; WinUI 3 on Windows); Combine → OpenCombine (same API); the file used Combine without importing it (SwiftUI and Foundation re-export it on the Mac)
