# BlackLabelAcademy — converted for windows by Circuit

Generated 2026-09-19T01:30:56.716Z from `/Users/michaelbarber/BlackLabelAcademy`. The source repo was not modified.

Source read: 22 files, sha256 `53a5bdf0c83d44d9` (git fc888d5ff + 4 uncommitted change(s)).

**Compiler check: passed** — simulated Windows configuration on macOS (-DCIRCUIT_WINDOWS_SIM); Apple Swift version 6.4 (swiftlang-6.4.0.33.1 clang-2100.3.33.1).

| | Files | Lines |
|---|---:|---:|
| Builds for Windows unchanged | 6 | 1,487 |
| Converted, builds for Windows | 6 | 1,965 |
| Builds for Windows with some declarations kept for the Mac | 4 | 742 build · 515 isolated |
| Needs a Windows part (kept byte-for-byte for the Mac build, compiled out elsewhere) | 6 | 2,157 |
| **Total app code considered** | **22** | **6,866** |

**61.1% of the app code builds for Windows** (4,194 of 6,866 lines) — measured by the compiler. The port check's estimate before converting was 17.6% of lines with no Mac-only parts; it reads imports and cannot see code that leans on a Mac-only file, so the compiler figure is the one to go by.

## Build it

```sh
swift build                                   # Windows, Linux or macOS
swift build -Xswiftc -DCIRCUIT_WINDOWS_SIM       # on a Mac: the Windows configuration
```

`.github/workflows/circuit-windows-build.yml` runs the same build on a Windows runner.

## What replaced the Apple-only parts

- `OpenCombine` — https://github.com/OpenCombine/OpenCombine.git (from 0.14.0)
- `swift-toolchain-sqlite` — https://github.com/swiftlang/swift-toolchain-sqlite.git (from 1.0.0)
- `CircuitPortKit` (in `kit/`) — Logger / os_log, UTType, the Combine scheduler bridge, and the Keychain (Windows Credential Manager) with SecRandomCopyBytes

## Windows parts still needed

| Apple part | Files | Lines | Size | Windows counterpart |
|---|---:|---:|---|---|
| SwiftUI | 7 | 2,405 | L | WinUI 3 through swift-winrt, or SwiftCrossUI (SwiftUI-style views on WinUI) |
| CoreSpotlight | 2 | 1,706 | M | Windows Search (no app index API): an in-app index |
| CoreGraphics | 1 | 269 | M | Direct2D / WIC for drawing, Win32 for displays and window lists |
| (uses code that was isolated) | 2 | 172 |  |  |

## Code kept for the Mac only, with the compiler's reason

- `Sources/App.swift` — whole file (67 lines) — 6:1 'BlackLabelAcademyApp' is annotated with '@main' and must provide a main static function of type () -> Void, () throws -> Void, () async -> Void, or () async throws -> Void (+9 more)
- `Sources/Calculators.swift` — 74 of 189 lines — 134:41 type annotation missing in pattern (+54 more)
- `Sources/Certificates.swift` — 269 of 383 lines — 141:24 cannot find 'Color' in scope (+16 more)
- `Sources/Cohort.swift` — 57 of 545 lines — 383:6 generic struct 'StateObject' requires that 'CohortClient' conform to 'ObservableObject'
- `Sources/Holographic.swift` — whole file (58 lines) — 11:59 type annotation missing in pattern (+18 more)
- `Sources/Markdown.swift` — whole file (175 lines) — 51:38 cannot find type 'View' in scope (+59 more)
- `Sources/Spotlight.swift` — whole file (95 lines) — 52:43 cannot find type 'CSSearchableItem' in scope (+6 more)
- `Sources/Theme.swift` — whole file (151 lines) — 48:26 cannot find type 'LinearGradient' in scope (+17 more)
- `Sources/Tutor.swift` — 115 of 140 lines — 88:17 cannot find 'MD' in scope (+6 more)
- `Sources/Views.swift` — whole file (1,611 lines) — 18:11 cannot find type 'Image' in scope (+128 more)

## Converted files

- `Sources/ContentDB.swift` — SQLite3 → swift-toolchain-sqlite (the same C API)
- `Sources/Model.swift` — SwiftUI → WinUI 3 through swift-winrt, or SwiftCrossUI (SwiftUI-style views on WinUI); Combine → OpenCombine (same API); SQLite3 → swift-toolchain-sqlite (the same C API)
- `Sources/Recall.swift` — Combine → OpenCombine (same API); SQLite3 → swift-toolchain-sqlite (the same C API)
- `Sources/StudyHabit.swift` — Combine → OpenCombine (same API); SQLite3 → swift-toolchain-sqlite (the same C API)
- `Sources/Trial.swift` — Combine → OpenCombine (same API); the file used Combine without importing it (SwiftUI and Foundation re-export it on the Mac)
- `Sources/Updater.swift` — Security → CircuitPortKit Keychain names (the Mac gets them through Foundation); FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
