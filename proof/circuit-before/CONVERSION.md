# circuit-698 — converted for windows by Circuit

Generated 2026-09-19T01:25:41.809Z from `/private/tmp/claude-501/-Users-michaelbarber-Desktop-Black-Label-B-ots-BlackLabel-Team-black-label-city-spec-d2180e/5435c4da-dbf5-4ec9-af9b-866272aed8e6/scratchpad/circuit-698`. The source repo was not modified.

**Compiler check: passed** — simulated Windows configuration on macOS (-DCIRCUIT_WINDOWS_SIM); Apple Swift version 6.4 (swiftlang-6.4.0.33.1 clang-2100.3.33.1).

| | Files | Lines |
|---|---:|---:|
| Builds for Windows unchanged | 32 | 7,228 |
| Converted, builds for Windows | 0 | 0 |
| Builds for Windows with some declarations kept for the Mac | 1 | 253 build · 119 isolated |
| Needs a Windows part (kept byte-for-byte for the Mac build, compiled out elsewhere) | 4 | 826 |
| **Total app code considered** | **37** | **8,426** |

**88.8% of the app code builds for Windows** (7,481 of 8,426 lines) — measured by the compiler. The port check's estimate before converting was 86.3% of lines with no Mac-only parts; it reads imports and cannot see code that leans on a Mac-only file, so the compiler figure is the one to go by.

## Build it

```sh
swift build                                   # Windows, Linux or macOS
swift build -Xswiftc -DCIRCUIT_WINDOWS_SIM       # on a Mac: the Windows configuration
```

`.github/workflows/circuit-windows-build.yml` runs the same build on a Windows runner.

## What replaced the Apple-only parts

- `swift-crypto` — https://github.com/apple/swift-crypto.git (from 3.0.0)

## Windows parts still needed

| Apple part | Files | Lines | Size | Windows counterpart |
|---|---:|---:|---|---|
| AppKit | 2 | 490 | L | WinUI 3 / Win32 windows, menus and dialogs |
| (uses code that was isolated) | 3 | 455 |  |  |
| Security | 1 | 119 | M | Windows Credential Manager (CredRead/CredWrite) and DPAPI |

## Code kept for the Mac only, with the compiler's reason

- `macos/CircuitLauncher.swift` — whole file (371 lines) — 9:23 cannot find type 'NSView' in scope (+15 more)
- `macos/CircuitUpdater.swift` — 119 of 372 lines — 338:17 cannot find 'NSAlert' in scope (+6 more)
