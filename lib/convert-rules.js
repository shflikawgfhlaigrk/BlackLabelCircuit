// Convert rules: the rewrites Circuit applies when it converts a macOS codebase for
// Windows. Pure data + pure functions, used by lib/convert.js. Deterministic — no
// model, no network (the same air-gap posture as the grader and the port check).
//
// A rule is only listed here when its replacement is a real, named thing:
//   dropin   a package with the same API (the import is swapped per platform)
//   kit      a part Circuit ships in CircuitPortKit (lib/convert-kit/)
//   platform the standard per-platform import for a C library
// Anything else is NOT converted: the file is isolated to Apple platforms and
// reported with the Windows part it needs (lib/port-map.js). Whether a rewritten
// file really builds is decided by the compiler (convert --verify), never assumed.

// The compilation condition that lets a Mac exercise the Windows configuration:
// `swift build -Xswiftc -DCIRCUIT_WINDOWS_SIM` hides every Apple-only module, so the
// same errors a Windows build would raise for missing frameworks show up locally.
export const SIM_FLAG = 'CIRCUIT_WINDOWS_SIM';

// Swift packages the drop-ins come from (pinned by minimum version).
export const SWIFT_PACKAGES = {
  OpenCombine: { url: 'https://github.com/OpenCombine/OpenCombine.git', from: '0.14.0', package: 'OpenCombine' },
  'swift-crypto': { url: 'https://github.com/apple/swift-crypto.git', from: '3.0.0', package: 'swift-crypto' },
  'swift-toolchain-sqlite': { url: 'https://github.com/swiftlang/swift-toolchain-sqlite.git', from: '1.0.0', package: 'swift-toolchain-sqlite' },
  // SwiftUI-style views with a native Windows backend (WinUI 3), GTK on Linux, AppKit on a Mac.
  // Still 0.x, so held to the minor version it was checked against.
  'swift-cross-ui': { url: 'https://github.com/moreSwift/swift-cross-ui.git', from: '0.9.0', package: 'swift-cross-ui', requirement: '.upToNextMinor(from: "0.9.0")' },
};

// Swift `import X` rewrites. `imports` is what the non-Apple branch imports;
// `products` are the SwiftPM products the module target must then depend on.
export const SWIFT_IMPORT_RULES = {
  Combine: {
    type: 'dropin', imports: ['OpenCombine', 'OpenCombineFoundation', 'OpenCombineDispatch'],
    products: [['OpenCombine', 'OpenCombine'], ['OpenCombineFoundation', 'OpenCombine'], ['OpenCombineDispatch', 'OpenCombine']],
    kit: true, // DispatchQueue/RunLoop scheduler conformances live in the kit
    note: 'OpenCombine (same API)',
  },
  CryptoKit: { type: 'dropin', imports: ['Crypto'], products: [['Crypto', 'swift-crypto']], note: 'swift-crypto (same API)' },
  // SwiftUI → SwiftCrossUI: the views, stacks, controls, state and environment it shares with
  // SwiftUI build as written and render through WinUI 3 on Windows. SwiftUI's names it spells
  // differently (StateObject, ObservedObject, EnvironmentObject over Combine models) are bridged
  // in the kit; whatever it does not have is left to the compiler, which keeps that view for
  // the Mac. OpenCombine comes along: on Apple platforms SwiftUI re-exports Combine.
  SwiftUI: {
    type: 'dropin', imports: ['SwiftCrossUI'],
    products: [['SwiftCrossUI', 'swift-cross-ui'], ['OpenCombine', 'OpenCombine'], ['OpenCombineFoundation', 'OpenCombine'], ['OpenCombineDispatch', 'OpenCombine']],
    kit: true,
    note: 'SwiftCrossUI (SwiftUI-style views; WinUI 3 on Windows)',
  },
  SQLite3: { type: 'dropin', imports: ['SwiftToolchainCSQLite'], products: [['SwiftToolchainCSQLite', 'swift-toolchain-sqlite']], note: 'swift-toolchain-sqlite (the same C API)' },
  os: { type: 'kit', imports: ['CircuitPortKit'], kit: true, note: 'CircuitPortKit Logger / os_log' },
  OSLog: { type: 'kit', imports: ['CircuitPortKit'], kit: true, note: 'CircuitPortKit Logger / os_log' },
  UniformTypeIdentifiers: { type: 'kit', imports: ['CircuitPortKit'], kit: true, note: 'CircuitPortKit UTType (extensions + MIME types)' },
  // The Keychain (generic passwords, over the Windows Credential Manager), SecRandomCopyBytes and
  // the status codes. Code signing, trust, keys and access control are not in the kit: code that
  // uses them fails to compile off the Mac and the compiler keeps it for the Mac, as before.
  Security: { type: 'kit', imports: ['CircuitPortKit'], kit: true, note: 'CircuitPortKit Keychain (Windows Credential Manager) + SecRandomCopyBytes' },
  Darwin: { type: 'platform', note: 'ucrt on Windows, Glibc on Linux' },
  // Off Apple platforms Foundation itself has CoreGraphics' geometry: CGFloat, CGPoint, CGSize,
  // CGRect and their members. So the import is hidden only where CoreGraphics really is missing,
  // never in the Mac simulation: hiding it there hides members Windows does have, and with
  // MemberImportVisibility the simulation rejected code the Windows compiler accepts (Ace,
  // 2026-09-18). Drawing (CGContext, CGImage, CGColor) still fails on Windows and the native
  // pass isolates it.
  CoreGraphics: { type: 'visible', note: 'Foundation has the geometry types off Apple platforms; drawing needs Direct2D / WIC' },
};

// Keychain names a Mac file can use without importing Security: Foundation re-exports it there.
// Off the Mac they come from CircuitPortKit, so a file that uses them gets the kit's import.
export const KEYCHAIN_SYMBOLS = /\b(?:kSec[A-Z]\w*|errSec[A-Z]\w*|SecItem(?:Add|CopyMatching|Update|Delete)|SecRandomCopyBytes|SecCopyErrorMessageString|OSStatus)\b/;

// Combine names a Mac file can use without importing Combine (SwiftUI and Foundation re-export
// it there). Off the Mac such a file gets the same OpenCombine imports as one that says
// `import Combine` (native Windows run 35373516902: "unknown attribute 'Published'").
export const COMBINE_SYMBOLS = /@Published\b|\b(?:ObservableObject|ObservableObjectPublisher|AnyCancellable|PassthroughSubject|CurrentValueSubject|AnyPublisher)\b|\bTimer\.publish\(|\.autoconnect\(\)|\.eraseToAnyPublisher\(\)/;

// Foundation types that live in FoundationNetworking outside Apple platforms.
export const NETWORKING_SYMBOLS = /\b(URLSession|URLRequest|HTTPURLResponse|URLSessionConfiguration|URLSessionTask|URLSessionDataTask|URLSessionDownloadTask|URLSessionUploadTask|URLSessionWebSocketTask|URLSessionDelegate|URLSessionDataDelegate|URLSessionTaskDelegate|URLCredential|URLAuthenticationChallenge|URLProtectionSpace|HTTPCookie|HTTPCookieStorage|URLCache|CachedURLResponse)\b/;

// `line` is the import exactly as written (`import os.log`, `@preconcurrency import X`):
// the Apple branch keeps it verbatim; `attrs` travel to the replacement imports.
export function swiftImportBlock(module, rule, line = `import ${module}`, attrs = '') {
  if (rule.type === 'visible') return [`#if canImport(${module})`, line, '#endif'];
  if (rule.type === 'platform') {
    return [
      `#if canImport(Darwin) && !${SIM_FLAG}`,
      'import Darwin',
      // ucrt only: code written against Darwin calls the C library, never Win32, and WinSDK
      // brings Windows' own `UUID`, which makes Foundation's ambiguous in the whole file
      // (native Windows run 35373516902 isolated nine Ace files for exactly that).
      '#elseif canImport(ucrt)',
      'import ucrt',
      '#elseif canImport(Glibc)',
      'import Glibc',
      '#endif',
    ];
  }
  return [
    `#if canImport(${module}) && !${SIM_FLAG}`,
    line,
    '#else',
    ...rule.imports.map((m) => `${attrs}import ${m}`),
    '#endif',
  ];
}

// An Apple-only import with no Windows counterpart yet: hidden off Apple platforms
// so the rest of the file still gets its chance with the compiler.
export function swiftGuardedImport(line, module) {
  return [`#if canImport(${module}) && !${SIM_FLAG}`, line, '#endif'];
}

export const NETWORKING_BLOCK = ['#if canImport(FoundationNetworking)', 'import FoundationNetworking', '#endif'];

// A file the compiler rejected for Windows is kept byte-for-byte for the Mac build
// and compiled out everywhere else.
export const ISOLATE_OPEN = `#if canImport(Darwin) && !${SIM_FLAG} // circuit-convert: Apple platforms only — see CONVERSION.md`;
export const ISOLATE_CLOSE = '#endif // circuit-convert';

// ---------- Python ----------
// Each rule rewrites one exact call shape into the portable helper (circuit_port.py,
// shipped next to the converted sources). `hit` is the port-check id it clears.
export const PYTHON_RULES = [
  {
    hit: '~/Library', helper: 'app_support',
    // os.path.expanduser("~/Library/Application Support/Name[/more]")
    re: /os\.path\.expanduser\(\s*(f?)(["'])~\/Library\/Application Support\/([^"']+)\2\s*\)/g,
    to: (_m, f, q, rest) => `circuit_port.app_support(${f}${q}${rest}${q})`,
  },
  {
    hit: '~/Library', helper: 'caches',
    re: /os\.path\.expanduser\(\s*(f?)(["'])~\/Library\/Caches\/([^"']+)\2\s*\)/g,
    to: (_m, f, q, rest) => `circuit_port.caches(${f}${q}${rest}${q})`,
  },
  {
    hit: '~/Library', helper: 'logs',
    re: /os\.path\.expanduser\(\s*(f?)(["'])~\/Library\/Logs\/([^"']+)\2\s*\)/g,
    to: (_m, f, q, rest) => `circuit_port.logs(${f}${q}${rest}${q})`,
  },
  {
    hit: 'open', helper: 'open_path',
    // subprocess.run(["open", target]) / Popen / call / check_call with exactly two items
    re: /subprocess\.(run|Popen|call|check_call)\(\s*\[\s*(["'])(?:\/usr\/bin\/)?open\2\s*,\s*([^,\]\[]+?)\s*\]\s*(?:,\s*check\s*=\s*(?:True|False)\s*)?\)/g,
    to: (_m, _fn, _q, target) => `circuit_port.open_path(${target})`,
  },
  {
    hit: 'say', helper: 'say',
    re: /subprocess\.(run|Popen|call|check_call)\(\s*\[\s*(["'])(?:\/usr\/bin\/)?say\2\s*,\s*([^,\]\[]+?)\s*\]\s*(?:,\s*check\s*=\s*(?:True|False)\s*)?\)/g,
    to: (_m, _fn, _q, text) => `circuit_port.say(${text})`,
  },
  {
    hit: 'afplay', helper: 'play_sound',
    re: /subprocess\.(run|Popen|call|check_call)\(\s*\[\s*(["'])(?:\/usr\/bin\/)?afplay\2\s*,\s*([^,\]\[]+?)\s*\]\s*(?:,\s*check\s*=\s*(?:True|False)\s*)?\)/g,
    to: (_m, _fn, _q, p) => `circuit_port.play_sound(${p})`,
  },
];

// `import fcntl` is converted only when every use is flock() with the LOCK_* flags —
// that is the part circuit_port implements on Windows (msvcrt.locking).
export const PY_FCNTL_IMPORT = /^([ \t]*)import[ \t]+fcntl[ \t]*$/m;
export const PY_FCNTL_OTHER_USE = /\bfcntl\.(?!flock\b|LOCK_(?:EX|SH|NB|UN)\b)\w+/;

// ---------- JavaScript / TypeScript ----------
export const JS_RULES = [
  {
    hit: '~/Library', helper: 'appSupport',
    // path.join(os.homedir(), 'Library', 'Application Support', ...rest)
    re: /path\.join\(\s*os\.homedir\(\)\s*,\s*(["'`])Library\1\s*,\s*(["'`])Application Support\2\s*,\s*/g,
    to: () => 'circuitPort.appSupport(',
  },
  {
    hit: '~/Library', helper: 'appSupport',
    re: /path\.join\(\s*os\.homedir\(\)\s*,\s*(["'`])Library\/Application Support\1\s*,\s*/g,
    to: () => 'circuitPort.appSupport(',
  },
  {
    hit: '~/Library', helper: 'caches',
    re: /path\.join\(\s*os\.homedir\(\)\s*,\s*(["'`])Library\1\s*,\s*(["'`])Caches\2\s*,\s*/g,
    to: () => 'circuitPort.caches(',
  },
  {
    hit: '~/Library', helper: 'logs',
    re: /path\.join\(\s*os\.homedir\(\)\s*,\s*(["'`])Library\1\s*,\s*(["'`])Logs\2\s*,\s*/g,
    to: () => 'circuitPort.logs(',
  },
];
