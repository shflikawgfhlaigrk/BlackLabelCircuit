// CircuitPortKit — the Keychain on Windows: SecItemAdd / SecItemCopyMatching / SecItemUpdate /
// SecItemDelete for generic passwords, kept in the Windows Credential Manager (CredWriteW,
// CredReadW, CredDeleteW, CredEnumerateW: per user, encrypted by Windows with the user's sign-in
// secrets). Apple's names, call shapes and status codes, so Keychain code builds unchanged.
//
// How an item maps (stated once, here):
//   identity       namespace + service + account → one generic credential whose TargetName is
//                  "<namespace>/<service>/<account>", each part percent-encoded. Readable in
//                  Control Panel → Credential Manager → Windows Credentials. Credential Manager
//                  compares names without regard to case and the Keychain does not, so capital
//                  letters are encoded too ("Bob" and "bob" stay two items).
//   value          the credential blob. A value over 2,560 bytes (the blob limit) is split across
//                  extra credentials; a new value is written beside the old one and switched to in
//                  one step, so a failed write never leaves a half-old, half-new secret.
//   namespace      Apple's access group. Windows does not keep one user's apps out of each other's
//                  credentials, so every item is filed under the app's namespace and a query only
//                  matches items of that namespace. Default: the bundle identifier, else the
//                  executable name; `CircuitKeychain.namespace` sets it.
//   accessibility  every kSecAttrAccessible* class → stored for this machine only
//                  (CRED_PERSIST_LOCAL_MACHINE), readable while the user is signed in; never roams,
//                  so synchronizable items do not sync.
//   accepted       kSecUseDataProtectionKeychain (Windows has one store), kSecUseAuthenticationUI*
//                  (Credential Manager never prompts for a generic credential).
//   not supported  internet passwords, certificates, keys, references (kSecReturnRef /
//                  kSecReturnPersistentRef): errSecUnimplemented, never a pretend success.
//
// CIRCUIT_KIT_SELFTEST builds this on a Mac with an in-memory store that keeps Credential
// Manager's rules (case-insensitive names, 2,560-byte blobs, 256-byte attributes), so the
// logic is tested on every run; the real store is exercised on a Windows runner.
#if os(Windows) || CIRCUIT_KIT_SELFTEST
import Foundation
#if os(Windows)
import WinSDK
#endif

// MARK: - Apple's functions

public func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    CircuitKeychain.add(CircuitKeychain.plain(attributes), result)
}

public func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    CircuitKeychain.copyMatching(CircuitKeychain.plain(query), result)
}

public func SecItemUpdate(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
    CircuitKeychain.update(CircuitKeychain.plain(query), CircuitKeychain.plain(attributesToUpdate))
}

public func SecItemDelete(_ query: CFDictionary) -> OSStatus {
    CircuitKeychain.delete(CircuitKeychain.plain(query))
}

// MARK: - The store

/// One credential as the store keeps it (a Windows generic credential).
struct CircuitCredential {
    var target: String
    var userName: String
    var blob: [UInt8]
    var attributes: [String: [UInt8]]
    var lastWritten: Date?
}

protocol CircuitCredentialStore {
    /// `(errSecSuccess, nil)` when there is no such credential.
    func read(_ target: String) -> (OSStatus, CircuitCredential?)
    func write(_ credential: CircuitCredential) -> OSStatus
    /// `errSecItemNotFound` when there is no such credential.
    func delete(_ target: String) -> OSStatus
    /// Every credential whose name starts with `prefix`.
    func enumerate(prefix: String) -> (OSStatus, [CircuitCredential])
}

public enum CircuitKeychain {
    /// Credential Manager's per-credential limits (wincred.h): CRED_MAX_CREDENTIAL_BLOB_SIZE
    /// (5 * 512 bytes), CRED_MAX_VALUE_SIZE for an attribute value, CRED_MAX_ATTRIBUTES.
    static let blobLimit = 2560
    static let attributeValueLimit = 256
    static let attributeCountLimit = 64

    /// The app's namespace: the part of every item's name that keeps it apart from other apps'.
    public static var namespace: String {
        get { state.withLock { state.namespace ?? defaultNamespace() } }
        set { state.withLock { state.namespace = newValue } }
    }

    final class State: @unchecked Sendable {
        let lock = NSLock()
        var namespace: String?
        #if os(Windows)
        let store: any CircuitCredentialStore = CredentialManagerStore()
        #else
        let store: any CircuitCredentialStore = MemoryCredentialStore()
        #endif
        func withLock<R>(_ body: () throws -> R) rethrows -> R {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }
    }
    static let state = State()

    static func defaultNamespace() -> String {
        if let id = Bundle.main.bundleIdentifier, !id.isEmpty { return id }
        var name = ProcessInfo.processInfo.processName
        if name.lowercased().hasSuffix(".exe") { name = String(name.dropLast(4)) }
        return name.isEmpty ? "app" : name
    }

    // MARK: dictionaries in, dictionaries out

    static func plain(_ dictionary: CFDictionary) -> [String: Any] {
        #if canImport(Darwin)
        return (dictionary as NSDictionary) as? [String: Any] ?? [:]
        #else
        var out: [String: Any] = [:]
        for (key, value) in dictionary {
            if let name = key.base as? String { out[name] = value }
        }
        return out
        #endif
    }

    static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let s = value as? Substring { return String(s) }
        return nil
    }

    static func flag(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? Int { return n != 0 }
        if let n = value as? NSNumber { return n.boolValue }
        return false
    }

    static func bytes(_ value: Any?) -> Data? {
        if let d = value as? Data { return d }
        if let d = value as? NSData { return Data(referencing: d) }
        if let b = value as? [UInt8] { return Data(b) }
        return nil
    }

    /// What the caller gets back through `CFTypeRef?`: Foundation objects, as on the Mac, so
    /// `result as? Data` and `result as? [String: Any]` read them the same way everywhere.
    static func object(_ value: Any) -> AnyObject {
        switch value {
        case let d as Data: return NSData(data: d)
        case let d as [String: Any]: return NSDictionary(dictionary: d)
        case let list as [Data]: return NSArray(array: list.map { NSData(data: $0) })
        case let list as [[String: Any]]: return NSArray(array: list.map { NSDictionary(dictionary: $0) })
        default: return NSNull()
        }
    }

    // MARK: identity and names

    struct Identity: Hashable {
        let namespace: String
        let service: String
        let account: String

        var target: String { "\(CircuitKeychain.encode(namespace))/\(CircuitKeychain.encode(service))/\(CircuitKeychain.encode(account))" }

        init(namespace: String, service: String, account: String) {
            self.namespace = namespace
            self.service = service
            self.account = account
        }

        /// The identity a credential name stands for; nil for anything that is not one of ours
        /// (another program's credential, or a continuation part of a long value).
        init?(target: String) {
            guard !target.contains("#") else { return nil }
            let parts = target.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let n = CircuitKeychain.decode(parts[0]), let s = CircuitKeychain.decode(parts[1]),
                  let a = CircuitKeychain.decode(parts[2]) else { return nil }
            self.init(namespace: n, service: s, account: a)
        }
    }

    /// Lower-case letters, digits and a few marks stay readable; everything else — capitals,
    /// the separators '/', '#', '%', the wildcard '*', spaces, non-ASCII — is %XX of its UTF-8.
    static func encode(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "@"),
                 UInt8(ascii: "+"), UInt8(ascii: "~"), UInt8(ascii: ":"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                let hex = Array("0123456789ABCDEF".utf8)
                out.unicodeScalars.append("%")
                out.unicodeScalars.append(Unicode.Scalar(hex[Int(byte >> 4)]))
                out.unicodeScalars.append(Unicode.Scalar(hex[Int(byte & 0x0F)]))
            }
        }
        return out
    }

    static func decode(_ text: Substring) -> String? {
        var out: [UInt8] = []
        var it = text.utf8.makeIterator()
        while let byte = it.next() {
            if byte != UInt8(ascii: "%") { out.append(byte); continue }
            guard let hi = it.next().flatMap(hexValue), let lo = it.next().flatMap(hexValue) else { return nil }
            out.append(hi << 4 | lo)
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        default: return nil
        }
    }

    // MARK: queries

    struct Query {
        var namespace: String
        var service: String?
        var account: String?
        var metadata: [String: [UInt8]] = [:]   // labl / desc / icmt / gena to match or store
        var value: Data?
        var limit: Int? = 1                       // nil = all
        var returnData = false
        var returnAttributes = false
    }

    static let metadataKeys = ["labl", "desc", "icmt", "gena"]

    static func parse(_ q: [String: Any]) -> (OSStatus, Query?) {
        guard let itemClass = string(q["class"]) else { return (errSecParam, nil) }
        guard itemClass == "genp" else { return (errSecUnimplemented, nil) }
        if flag(q["r_Ref"]) || flag(q["r_PersistentRef"]) { return (errSecUnimplemented, nil) }
        var query = Query(namespace: string(q["agrp"]) ?? namespace)
        query.service = string(q["svce"])
        query.account = string(q["acct"])
        query.value = bytes(q["v_Data"])
        query.returnData = flag(q["r_Data"])
        query.returnAttributes = flag(q["r_Attributes"])
        for key in metadataKeys {
            guard let raw = q[key] else { continue }
            let encoded: [UInt8]
            if key == "gena", let d = bytes(raw) { encoded = [UInt8](d) }
            else if let s = string(raw) { encoded = Array(s.utf8) }
            else { return (errSecParam, nil) }
            guard encoded.count <= attributeValueLimit else { return (errSecParam, nil) }
            query.metadata[key] = encoded
        }
        switch q["m_Limit"] {
        case nil: query.limit = 1
        case let v?:
            if let s = string(v) { query.limit = s == "m_LimitAll" ? nil : 1 }
            else if let n = v as? Int { query.limit = n > 0 ? n : nil }
            else { return (errSecParam, nil) }
        }
        return (errSecSuccess, query)
    }

    /// The items a query names, in a stable order (service, then account).
    static func matches(_ q: Query, in store: any CircuitCredentialStore) -> (OSStatus, [(Identity, CircuitCredential)]) {
        var found: [(Identity, CircuitCredential)] = []
        if let service = q.service, let account = q.account {
            let id = Identity(namespace: q.namespace, service: service, account: account)
            let (status, credential) = store.read(id.target)
            guard status == errSecSuccess else { return (status, []) }
            if let credential { found.append((id, credential)) }
        } else {
            var prefix = encode(q.namespace) + "/"
            if let service = q.service { prefix += encode(service) + "/" }
            let (status, list) = store.enumerate(prefix: prefix)
            guard status == errSecSuccess else { return (status, []) }
            for credential in list {
                guard let id = Identity(target: credential.target), id.namespace == q.namespace else { continue }
                if let service = q.service, id.service != service { continue }
                if let account = q.account, id.account != account { continue }
                found.append((id, credential))
            }
        }
        found = found.filter { item in q.metadata.allSatisfy { item.1.attributes["kc_" + $0.key] == $0.value } }
        found.sort { ($0.0.service, $0.0.account) < ($1.0.service, $1.0.account) }
        return (errSecSuccess, found)
    }

    // MARK: values (split across credentials when long)

    static func parts(of credential: CircuitCredential) -> (generation: String, count: Int)? {
        guard let raw = credential.attributes["kc_parts"], let text = String(bytes: raw, encoding: .utf8) else { return nil }
        let fields = text.split(separator: ":")
        guard fields.count == 2, let count = Int(fields[1]), count >= 2 else { return nil }
        return (String(fields[0]), count)
    }

    static func load(_ credential: CircuitCredential, from store: any CircuitCredentialStore) -> (OSStatus, Data?) {
        var value = credential.blob
        if let parts = parts(of: credential) {
            for k in 2...parts.count {
                let (status, part) = store.read("\(credential.target)#\(parts.generation).\(k)")
                guard status == errSecSuccess else { return (status, nil) }
                guard let part else { return (errSecDecode, nil) }
                value += part.blob
            }
        }
        return (errSecSuccess, Data(value))
    }

    static func save(_ id: Identity, value: Data, metadata: [String: [UInt8]], replacing previous: CircuitCredential?,
                     in store: any CircuitCredentialStore) -> OSStatus {
        let all = [UInt8](value)
        let target = id.target
        var attributes: [String: [UInt8]] = [:]
        for (key, v) in metadata { attributes["kc_" + key] = v }
        var written: [String] = []
        if all.count > blobLimit {
            var generator = SystemRandomNumberGenerator()
            let generation = String(generator.next() & 0xFFFF_FFFF, radix: 16)
            var k = 2
            var offset = blobLimit
            while offset < all.count {
                let part = CircuitCredential(target: "\(target)#\(generation).\(k)", userName: id.account,
                                             blob: Array(all[offset..<min(offset + blobLimit, all.count)]), attributes: [:])
                let status = store.write(part)
                guard status == errSecSuccess else {
                    for t in written { _ = store.delete(t) }
                    return status
                }
                written.append(part.target)
                offset += blobLimit
                k += 1
            }
            attributes["kc_parts"] = Array("\(generation):\(k - 1)".utf8)
        }
        guard attributes.count <= attributeCountLimit else { return errSecParam }
        let head = CircuitCredential(target: target, userName: id.account, blob: Array(all.prefix(blobLimit)), attributes: attributes)
        let status = store.write(head)
        guard status == errSecSuccess else {
            for t in written { _ = store.delete(t) }
            return status
        }
        // The new value is in place; the old continuation parts are now unreferenced.
        if let previous, let old = parts(of: previous) {
            for k in 2...old.count { _ = store.delete("\(previous.target)#\(old.generation).\(k)") }
        }
        return errSecSuccess
    }

    static func remove(_ credential: CircuitCredential, from store: any CircuitCredentialStore) -> OSStatus {
        let status = store.delete(credential.target)
        guard status == errSecSuccess || status == errSecItemNotFound else { return status }
        if let parts = parts(of: credential) {
            for k in 2...parts.count { _ = store.delete("\(credential.target)#\(parts.generation).\(k)") }
        }
        return errSecSuccess
    }

    static func attributes(of id: Identity, _ credential: CircuitCredential, value: Data?) -> [String: Any] {
        var out: [String: Any] = ["class": "genp", "svce": id.service, "acct": id.account, "agrp": id.namespace]
        for key in metadataKeys {
            guard let raw = credential.attributes["kc_" + key] else { continue }
            out[key] = key == "gena" ? Data(raw) as Any : String(decoding: raw, as: UTF8.self) as Any
        }
        if let date = credential.lastWritten { out["mdat"] = date }
        if let raw = credential.attributes["kc_cdat"], let seconds = Double(String(decoding: raw, as: UTF8.self)) {
            out["cdat"] = Date(timeIntervalSince1970: seconds)
        }
        if let value { out["v_Data"] = value }
        return out
    }

    /// The result object for the items found, shaped the way Apple shapes it.
    static func result(for items: [(Identity, CircuitCredential)], _ q: Query,
                       from store: any CircuitCredentialStore) -> (OSStatus, AnyObject?) {
        guard q.returnData || q.returnAttributes else { return (errSecSuccess, nil) }
        var values: [Data?] = []
        for (_, credential) in items {
            if q.returnData {
                let (status, value) = load(credential, from: store)
                guard status == errSecSuccess else { return (status, nil) }
                values.append(value)
            } else {
                values.append(nil)
            }
        }
        if q.limit == 1, let (id, credential) = items.first {
            if q.returnAttributes { return (errSecSuccess, object(attributes(of: id, credential, value: values[0]))) }
            return (errSecSuccess, object(values[0] ?? Data()))
        }
        if q.returnAttributes {
            return (errSecSuccess, object(zip(items, values).map { attributes(of: $0.0.0, $0.0.1, value: $0.1) }))
        }
        return (errSecSuccess, object(values.map { $0 ?? Data() }))
    }

    // MARK: the four calls

    static func add(_ a: [String: Any], _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        let (parsed, query) = parse(a)
        guard parsed == errSecSuccess, var q = query else { return parsed }
        q.service = q.service ?? ""
        q.account = q.account ?? ""
        q.limit = 1
        return state.withLock {
            let store = state.store
            let id = Identity(namespace: q.namespace, service: q.service!, account: q.account!)
            let (status, existing) = store.read(id.target)
            guard status == errSecSuccess else { return status }
            guard existing == nil else { return errSecDuplicateItem }
            var metadata = q.metadata
            metadata["cdat"] = Array(String(Int(Date().timeIntervalSince1970)).utf8)
            let saved = save(id, value: q.value ?? Data(), metadata: metadata, replacing: nil, in: store)
            guard saved == errSecSuccess else { return saved }
            if let result, q.returnData || q.returnAttributes {
                let (readStatus, credential) = store.read(id.target)
                guard readStatus == errSecSuccess, let credential else { return readStatus == errSecSuccess ? errSecIO : readStatus }
                let (status, object) = self.result(for: [(id, credential)], q, from: store)
                guard status == errSecSuccess else { return status }
                result.pointee = object
            }
            return errSecSuccess
        }
    }

    static func copyMatching(_ q0: [String: Any], _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        let (parsed, query) = parse(q0)
        guard parsed == errSecSuccess, let q = query else { return parsed }
        return state.withLock {
            let store = state.store
            let (status, found) = matches(q, in: store)
            guard status == errSecSuccess else { return status }
            guard !found.isEmpty else { return errSecItemNotFound }
            let items = q.limit.map { Array(found.prefix($0)) } ?? found
            let (built, object) = self.result(for: items, q, from: store)
            guard built == errSecSuccess else { return built }
            result?.pointee = object
            return errSecSuccess
        }
    }

    static func update(_ q0: [String: Any], _ changes: [String: Any]) -> OSStatus {
        let (parsed, query) = parse(q0)
        guard parsed == errSecSuccess, var q = query else { return parsed }
        q.limit = nil
        if let itemClass = changes["class"], string(itemClass) != "genp" { return errSecParam }
        if flag(changes["r_Data"]) || flag(changes["r_Attributes"]) { return errSecParam }
        var newMetadata: [String: [UInt8]] = [:]
        for key in metadataKeys {
            guard let raw = changes[key] else { continue }
            let encoded: [UInt8]
            if key == "gena", let d = bytes(raw) { encoded = [UInt8](d) }
            else if let s = string(raw) { encoded = Array(s.utf8) }
            else { return errSecParam }
            guard encoded.count <= attributeValueLimit else { return errSecParam }
            newMetadata[key] = encoded
        }
        let newService = string(changes["svce"])
        let newAccount = string(changes["acct"])
        let newValue = bytes(changes["v_Data"])
        return state.withLock {
            let store = state.store
            let (status, items) = matches(q, in: store)
            guard status == errSecSuccess else { return status }
            guard !items.isEmpty else { return errSecItemNotFound }
            // Check every rename first: an update either applies to all the items or to none.
            var plans: [(Identity, CircuitCredential, Identity)] = []
            var destinations = Set<Identity>()
            for (id, credential) in items {
                let to = Identity(namespace: id.namespace, service: newService ?? id.service, account: newAccount ?? id.account)
                guard destinations.insert(to).inserted else { return errSecDuplicateItem }
                if to != id {
                    let (s, existing) = store.read(to.target)
                    guard s == errSecSuccess else { return s }
                    guard existing == nil else { return errSecDuplicateItem }
                }
                plans.append((id, credential, to))
            }
            for (id, credential, to) in plans {
                let (s, current) = load(credential, from: store)
                guard s == errSecSuccess, let current else { return s == errSecSuccess ? errSecDecode : s }
                var metadata: [String: [UInt8]] = [:]
                for (key, v) in credential.attributes where key.hasPrefix("kc_") && key != "kc_parts" {
                    metadata[String(key.dropFirst(3))] = v
                }
                for (key, v) in newMetadata { metadata[key] = v }
                let saved = save(to, value: newValue ?? current, metadata: metadata,
                                 replacing: to == id ? credential : nil, in: store)
                guard saved == errSecSuccess else { return saved }
                if to != id {
                    let removed = remove(credential, from: store)
                    guard removed == errSecSuccess else { return removed }
                }
            }
            return errSecSuccess
        }
    }

    static func delete(_ q0: [String: Any]) -> OSStatus {
        let (parsed, query) = parse(q0)
        guard parsed == errSecSuccess, var q = query else { return parsed }
        q.limit = nil
        return state.withLock {
            let store = state.store
            let (status, items) = matches(q, in: store)
            guard status == errSecSuccess else { return status }
            guard !items.isEmpty else { return errSecItemNotFound }
            for (_, credential) in items {
                let removed = remove(credential, from: store)
                guard removed == errSecSuccess else { return removed }
            }
            return errSecSuccess
        }
    }
}

// MARK: - Windows Credential Manager

#if os(Windows)
struct CredentialManagerStore: CircuitCredentialStore {
    // wincred.h / winerror.h values, spelled out so the mapping reads in one place.
    static let typeGeneric = DWORD(1)                 // CRED_TYPE_GENERIC
    static let persistLocalMachine = DWORD(2)         // CRED_PERSIST_LOCAL_MACHINE
    static let errorNotFound = DWORD(1168)            // ERROR_NOT_FOUND
    static let errorNoSuchLogonSession = DWORD(1312)  // ERROR_NO_SUCH_LOGON_SESSION
    static let errorInvalidParameter = DWORD(87)      // ERROR_INVALID_PARAMETER
    static let errorInvalidFlags = DWORD(1004)        // ERROR_INVALID_FLAGS
    static let errorBadUsername = DWORD(2202)         // ERROR_BAD_USERNAME
    static let errorNotEnoughMemory = DWORD(8)        // ERROR_NOT_ENOUGH_MEMORY

    static func status(_ error: DWORD) -> OSStatus {
        switch error {
        case errorNotFound: return errSecItemNotFound
        case errorNoSuchLogonSession: return errSecNotAvailable
        case errorInvalidParameter, errorInvalidFlags, errorBadUsername: return errSecParam
        case errorNotEnoughMemory: return errSecAllocate
        default: return errSecIO
        }
    }

    static func text(_ pointer: UnsafeMutablePointer<WCHAR>?) -> String {
        guard let pointer else { return "" }
        return String(decodingCString: pointer, as: UTF16.self)
    }

    static func record(_ c: CREDENTIALW) -> CircuitCredential {
        var blob: [UInt8] = []
        if let p = c.CredentialBlob, c.CredentialBlobSize > 0 {
            blob = Array(UnsafeBufferPointer(start: p, count: Int(c.CredentialBlobSize)))
        }
        var attributes: [String: [UInt8]] = [:]
        if let list = c.Attributes {
            for i in 0..<Int(c.AttributeCount) {
                let a = list[i]
                var value: [UInt8] = []
                if let v = a.Value, a.ValueSize > 0 { value = Array(UnsafeBufferPointer(start: v, count: Int(a.ValueSize))) }
                attributes[text(a.Keyword)] = value
            }
        }
        // FILETIME: 100-nanosecond intervals since 1601-01-01 UTC.
        let ticks = UInt64(c.LastWritten.dwHighDateTime) << 32 | UInt64(c.LastWritten.dwLowDateTime)
        let written = ticks == 0 ? nil : Date(timeIntervalSince1970: Double(ticks) / 10_000_000 - 11_644_473_600)
        return CircuitCredential(target: text(c.TargetName), userName: text(c.UserName), blob: blob,
                                 attributes: attributes, lastWritten: written)
    }

    func read(_ target: String) -> (OSStatus, CircuitCredential?) {
        var found: UnsafeMutablePointer<CREDENTIALW>? = nil
        let ok = target.withCString(encodedAs: UTF16.self) { CredReadW($0, Self.typeGeneric, 0, &found) }
        guard ok, let found else {
            let error = GetLastError()
            return error == Self.errorNotFound ? (errSecSuccess, nil) : (Self.status(error), nil)
        }
        defer { CredFree(found) }
        return (errSecSuccess, Self.record(found.pointee))
    }

    func write(_ credential: CircuitCredential) -> OSStatus {
        var wide: [UnsafeMutablePointer<WCHAR>] = []
        var raw: [(UnsafeMutablePointer<UInt8>, Int)] = []
        defer {
            for p in wide { p.deallocate() }
            for (p, n) in raw { p.update(repeating: 0, count: n); p.deallocate() }
        }
        func copy(_ s: String) -> UnsafeMutablePointer<WCHAR> {
            let units = Array(s.utf16) + [0]
            let p = UnsafeMutablePointer<WCHAR>.allocate(capacity: units.count)
            p.initialize(from: units, count: units.count)
            wide.append(p)
            return p
        }
        func copy(_ b: [UInt8]) -> UnsafeMutablePointer<UInt8>? {
            guard !b.isEmpty else { return nil }
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: b.count)
            p.initialize(from: b, count: b.count)
            raw.append((p, b.count))
            return p
        }
        let keys = credential.attributes.keys.sorted()
        let list = UnsafeMutablePointer<CREDENTIAL_ATTRIBUTEW>.allocate(capacity: max(1, keys.count))
        defer { list.deallocate() }
        for (i, key) in keys.enumerated() {
            let value = credential.attributes[key] ?? []
            var a = CREDENTIAL_ATTRIBUTEW()
            a.Keyword = copy(key)
            a.Flags = 0
            a.ValueSize = DWORD(value.count)
            a.Value = copy(value)
            (list + i).initialize(to: a)
        }
        var c = CREDENTIALW()
        c.Flags = 0
        c.`Type` = Self.typeGeneric
        c.TargetName = copy(credential.target)
        c.UserName = copy(String(credential.userName.prefix(256)))
        c.CredentialBlobSize = DWORD(credential.blob.count)
        c.CredentialBlob = copy(credential.blob)
        c.Persist = Self.persistLocalMachine
        c.AttributeCount = DWORD(keys.count)
        c.Attributes = keys.isEmpty ? nil : list
        guard CredWriteW(&c, 0) else { return Self.status(GetLastError()) }
        return errSecSuccess
    }

    func delete(_ target: String) -> OSStatus {
        let ok = target.withCString(encodedAs: UTF16.self) { CredDeleteW($0, Self.typeGeneric, 0) }
        return ok ? errSecSuccess : Self.status(GetLastError())
    }

    func enumerate(prefix: String) -> (OSStatus, [CircuitCredential]) {
        var count: DWORD = 0
        var list: UnsafeMutablePointer<UnsafeMutablePointer<CREDENTIALW>?>? = nil
        let ok = (prefix + "*").withCString(encodedAs: UTF16.self) { CredEnumerateW($0, 0, &count, &list) }
        guard ok, let list else {
            let error = GetLastError()
            return error == Self.errorNotFound ? (errSecSuccess, []) : (Self.status(error), [])
        }
        defer { CredFree(list) }
        var out: [CircuitCredential] = []
        for i in 0..<Int(count) {
            guard let c = list[i], c.pointee.`Type` == Self.typeGeneric else { continue }
            out.append(Self.record(c.pointee))
        }
        return (errSecSuccess, out)
    }
}
#else
/// The self-test's store: Credential Manager's rules, in memory.
final class MemoryCredentialStore: CircuitCredentialStore, @unchecked Sendable {
    private var items: [String: CircuitCredential] = [:]   // key: the name, lower-cased (Windows ignores case)

    func read(_ target: String) -> (OSStatus, CircuitCredential?) { (errSecSuccess, items[target.lowercased()]) }

    func write(_ credential: CircuitCredential) -> OSStatus {
        guard credential.blob.count <= CircuitKeychain.blobLimit,
              credential.attributes.count <= CircuitKeychain.attributeCountLimit,
              credential.attributes.values.allSatisfy({ $0.count <= CircuitKeychain.attributeValueLimit }) else { return errSecParam }
        var stored = credential
        stored.lastWritten = Date()
        items[credential.target.lowercased()] = stored
        return errSecSuccess
    }

    func delete(_ target: String) -> OSStatus { items.removeValue(forKey: target.lowercased()) == nil ? errSecItemNotFound : errSecSuccess }

    func enumerate(prefix: String) -> (OSStatus, [CircuitCredential]) {
        (errSecSuccess, items.filter { $0.key.hasPrefix(prefix.lowercased()) }.map(\.value))
    }
}
#endif
#endif
