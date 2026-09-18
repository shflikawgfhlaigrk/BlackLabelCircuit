# Circuit-PortCheck-20260918 — converted for windows by Circuit

Generated 2026-09-18T07:12:44.558Z from `/Users/michaelbarber/BlackLabel-LocalWorktrees/Circuit-PortCheck-20260918`. The source repo was not modified.

**Compiler check: passed** — simulated Windows configuration on macOS (-DCIRCUIT_WINDOWS_SIM); Apple Swift version 6.4 (swiftlang-6.4.0.33.1 clang-2100.3.33.1).

| | Files | Lines |
|---|---:|---:|
| Builds for Windows unchanged | 31 | 6,929 |
| Converted, builds for Windows | 0 | 0 |
| Builds for Windows with some declarations kept for the Mac | 1 | 253 build · 119 isolated |
| Needs a Windows part (kept byte-for-byte for the Mac build, compiled out elsewhere) | 4 | 826 |
| **Total app code considered** | **36** | **8,127** |

**88.4% of the app code builds for Windows** (7,182 of 8,127 lines) — measured by the compiler. The port check's estimate before converting was 85.9% of lines with no Mac-only parts; it reads imports and cannot see code that leans on a Mac-only file, so the compiler figure is the one to go by.

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
