// CircuitPortKit — the parts of Apple's Security framework that mean the same thing off
// Apple platforms: the Keychain item keys (`kSec…`), the `errSec…` status codes, `OSStatus`,
// `SecCopyErrorMessageString` and `SecRandomCopyBytes` (the system's cryptographic random
// source: BCryptGenRandom on Windows, getrandom on Linux). The Keychain calls themselves are in
// Keychain.swift (Windows Credential Manager).
//
// Not here, on purpose, so the compiler keeps that code for the Mac: code signing (SecCode,
// SecStaticCode, SecRequirement, SecTask), trust and certificates (SecTrust, SecCertificate),
// keys (SecKey) and access control (SecAccessControl, kSecAttrAccessControl,
// kSecUseAuthenticationContext). Windows has no same-meaning counterpart behind this API and a
// stand-in would silently weaken what that code protects.
//
// Compiled only where Security is missing. On a Mac simulating Windows, Foundation already
// re-exports Apple's Security, so this file stays empty there (no ambiguity); the native
// Windows build is where it is judged. CIRCUIT_KIT_SELFTEST compiles it on a Mac inside the
// kit's own self-test module, where these declarations shadow Apple's.
#if !canImport(Security) || CIRCUIT_KIT_SELFTEST
import Foundation

#if !canImport(Darwin)
// Core Foundation's names for the types the Keychain API is spelled in. Foundation off Apple
// platforms does not export Core Foundation, and no bridging `as` exists there, so the names
// resolve to the Swift types the same code already builds with Apple's toll-free bridging:
// `query as CFDictionary` is `[String: Any]` upcast to `[AnyHashable: Any]`, `kSecClass as
// String` is a String, and a result comes back through `AnyObject?` as on the Mac.
public typealias OSStatus = Int32
public typealias CFString = String
public typealias CFTypeRef = AnyObject
public typealias CFDictionary = [AnyHashable: Any]
#endif

// ---- status codes (the values and messages are Apple's) ----
public let errSecSuccess: OSStatus = 0
public let errSecUnimplemented: OSStatus = -4
public let errSecIO: OSStatus = -36
public let errSecParam: OSStatus = -50
public let errSecAllocate: OSStatus = -108
public let errSecUserCanceled: OSStatus = -128
public let errSecBadReq: OSStatus = -909
public let errSecNotAvailable: OSStatus = -25291
public let errSecAuthFailed: OSStatus = -25293
public let errSecDuplicateItem: OSStatus = -25299
public let errSecItemNotFound: OSStatus = -25300
public let errSecDataTooLarge: OSStatus = -25302
public let errSecInteractionNotAllowed: OSStatus = -25308
public let errSecDecode: OSStatus = -26275
public let errSecMissingEntitlement: OSStatus = -34018

public func SecCopyErrorMessageString(_ status: OSStatus, _ reserved: UnsafeMutableRawPointer?) -> CFString? {
    let message: String
    switch status {
    case errSecSuccess: message = "No error."
    case errSecUnimplemented: message = "Function or operation not implemented."
    case errSecIO: message = "I/O error."
    case errSecParam: message = "One or more parameters passed to a function were not valid."
    case errSecAllocate: message = "Failed to allocate memory."
    case errSecUserCanceled: message = "User canceled the operation."
    case errSecBadReq: message = "Bad parameter or invalid state for operation."
    case errSecNotAvailable: message = "No keychain is available. You may need to restart your computer."
    case errSecAuthFailed: message = "The user name or passphrase you entered is not correct."
    case errSecDuplicateItem: message = "The specified item already exists in the keychain."
    case errSecItemNotFound: message = "The specified item could not be found in the keychain."
    case errSecDataTooLarge: message = "This item contains information which is too large or in a format that cannot be displayed."
    case errSecInteractionNotAllowed: message = "User interaction is not allowed."
    case errSecDecode: message = "Unable to decode the provided data."
    case errSecMissingEntitlement: message = "A required entitlement is not present."
    default: message = "OSStatus \(status)"
    }
    return message as CFString
}

// ---- Keychain item keys and values (the raw strings are Apple's) ----
public let kSecClass: CFString = "class" as CFString
public let kSecClassGenericPassword: CFString = "genp" as CFString
public let kSecClassInternetPassword: CFString = "inet" as CFString
public let kSecAttrService: CFString = "svce" as CFString
public let kSecAttrAccount: CFString = "acct" as CFString
public let kSecAttrLabel: CFString = "labl" as CFString
public let kSecAttrDescription: CFString = "desc" as CFString
public let kSecAttrComment: CFString = "icmt" as CFString
public let kSecAttrGeneric: CFString = "gena" as CFString
public let kSecAttrAccessGroup: CFString = "agrp" as CFString
public let kSecAttrCreationDate: CFString = "cdat" as CFString
public let kSecAttrModificationDate: CFString = "mdat" as CFString
public let kSecAttrIsInvisible: CFString = "invi" as CFString
public let kSecAttrSynchronizable: CFString = "sync" as CFString
public let kSecAttrSynchronizableAny: CFString = "syna" as CFString
public let kSecAttrAccessible: CFString = "pdmn" as CFString
public let kSecAttrAccessibleWhenUnlocked: CFString = "ak" as CFString
public let kSecAttrAccessibleAfterFirstUnlock: CFString = "ck" as CFString
public let kSecAttrAccessibleWhenUnlockedThisDeviceOnly: CFString = "aku" as CFString
public let kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: CFString = "cku" as CFString
public let kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly: CFString = "akpu" as CFString
public let kSecValueData: CFString = "v_Data" as CFString
public let kSecReturnData: CFString = "r_Data" as CFString
public let kSecReturnAttributes: CFString = "r_Attributes" as CFString
public let kSecReturnRef: CFString = "r_Ref" as CFString
public let kSecReturnPersistentRef: CFString = "r_PersistentRef" as CFString
public let kSecMatchLimit: CFString = "m_Limit" as CFString
public let kSecMatchLimitOne: CFString = "m_LimitOne" as CFString
public let kSecMatchLimitAll: CFString = "m_LimitAll" as CFString
public let kSecUseDataProtectionKeychain: CFString = "nleg" as CFString
public let kSecUseAuthenticationUI: CFString = "u_AuthUI" as CFString
public let kSecUseAuthenticationUIAllow: CFString = "u_AuthUIA" as CFString
public let kSecUseAuthenticationUIFail: CFString = "u_AuthUIF" as CFString
public let kSecUseAuthenticationUISkip: CFString = "u_AuthUIS" as CFString

// ---- random bytes ----
/// Apple's `SecRandomRef` is an opaque pointer; the only value callers pass is `kSecRandomDefault`.
public typealias SecRandomRef = OpaquePointer
nonisolated(unsafe) public let kSecRandomDefault: SecRandomRef? = nil

/// Fills `bytes` from the operating system's cryptographically secure generator
/// (`SystemRandomNumberGenerator`: BCryptGenRandom on Windows, getrandom on Linux).
public func SecRandomCopyBytes(_ rnd: SecRandomRef?, _ count: Int, _ bytes: UnsafeMutableRawPointer) -> Int32 {
    guard count >= 0 else { return errSecParam }
    var generator = SystemRandomNumberGenerator()
    var offset = 0
    while offset < count {
        var word = generator.next()
        let n = min(MemoryLayout<UInt64>.size, count - offset)
        withUnsafeBytes(of: &word) { (bytes + offset).copyMemory(from: $0.baseAddress!, byteCount: n) }
        offset += n
    }
    return errSecSuccess
}
#endif
