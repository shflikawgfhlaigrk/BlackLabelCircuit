// CircuitPortKit self-test: the Keychain calls exactly as the converted apps make them
// (`[String: Any]` queries passed `as CFDictionary`, results read back through `AnyObject?`),
// against the real Windows Credential Manager on Windows and against the in-memory store with
// Credential Manager's rules on a Mac. `circuit --kit-selftest <dir>` builds and runs it.
//
//   (no argument)     the whole suite; leaves one item behind when CIRCUIT_KIT_SELFTEST_MARKER=1 so
//                     a second program (cmdkey /list) can see it really is in the Windows store
//   --remove-marker   deletes that item again
import Foundation
#if !CIRCUIT_KIT_SELFTEST_SINGLE
import CircuitPortKit
#endif

struct SelfTest {
    var failures = 0
    var passes = 0

    mutating func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL") \(what)")
        if ok { passes += 1 } else { failures += 1 }
    }

    static func item(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(_ base: [String: Any]) -> (OSStatus, Data?) {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var output: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &output)
        return (status, output as? Data)
    }

    mutating func run() -> Int32 {
        let alice = Self.item("circuit.selftest.tokens", "alice")
        _ = SecItemDelete([kSecClass as String: kSecClassGenericPassword] as CFDictionary)   // a clean namespace

        // add, the way MarketingKeychain / SovereignKeychain write
        var add = alice
        add[kSecValueData as String] = Data("s3cret".utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecUseDataProtectionKeychain as String] = true
        check(SecItemAdd(add as CFDictionary, nil) == errSecSuccess, "SecItemAdd stores a generic password")
        check(SecItemAdd(add as CFDictionary, nil) == errSecDuplicateItem, "adding the same item again is errSecDuplicateItem")

        // read, the MarketingKeychain.copy pattern: var output: AnyObject? + output as? Data
        let (status, value) = Self.read(alice)
        check(status == errSecSuccess && value == Data("s3cret".utf8), "SecItemCopyMatching returns the value (output as? Data)")

        // the CFTypeRef spelling
        var ref: CFTypeRef?
        var q = alice
        q[kSecReturnData as String] = true
        check(SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess && (ref as? Data) == Data("s3cret".utf8), "the same through CFTypeRef?")

        // attributes + data, the GmailAccount pattern: item as? [String: Any], then attributes[kSecValueData]
        var qa = alice
        qa[kSecReturnAttributes as String] = true
        qa[kSecReturnData as String] = true
        var item: AnyObject?
        let st = SecItemCopyMatching(qa as CFDictionary, &item)
        let attributes = item as? [String: Any]
        check(st == errSecSuccess && attributes != nil, "kSecReturnAttributes returns a dictionary (item as? [String: Any])")
        check((attributes?[kSecValueData as String] as? Data) == Data("s3cret".utf8), "the dictionary carries kSecValueData as Data")
        check((attributes?[kSecAttrAccount as String] as? String) == "alice" && (attributes?[kSecAttrService as String] as? String) == "circuit.selftest.tokens", "and the service and account")
        check(attributes?[kSecAttrModificationDate as String] is Date, "and the modification date")

        // update the value
        check(SecItemUpdate(alice as CFDictionary, [kSecValueData as String: Data("n3w".utf8)] as CFDictionary) == errSecSuccess, "SecItemUpdate changes the value")
        check(Self.read(alice).1 == Data("n3w".utf8), "the new value reads back")

        // a missing item
        check(Self.read(Self.item("circuit.selftest.tokens", "nobody")).0 == errSecItemNotFound, "a missing item is errSecItemNotFound")

        // case: Credential Manager ignores it, the Keychain does not
        var upper = Self.item("circuit.selftest.tokens", "Alice")
        upper[kSecValueData as String] = Data("capital".utf8)
        check(SecItemAdd(upper as CFDictionary, nil) == errSecSuccess, "\"Alice\" and \"alice\" are two items")
        check(Self.read(alice).1 == Data("n3w".utf8) && Self.read(Self.item("circuit.selftest.tokens", "Alice")).1 == Data("capital".utf8), "each keeps its own value")

        // a long value: split across credentials (the blob limit is 2,560 bytes), then replaced by a short one
        var long = Data(count: 9_000)
        let filled = long.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 9_000, $0.baseAddress!) }
        check(filled == errSecSuccess, "SecRandomCopyBytes fills 9,000 bytes")
        let big = Self.item("circuit.selftest.big", "blob")
        var addBig = big
        addBig[kSecValueData as String] = long
        check(SecItemAdd(addBig as CFDictionary, nil) == errSecSuccess, "a 9,000-byte value is stored")
        check(Self.read(big).1 == long, "and reads back byte for byte")
        long.append(contentsOf: [1, 2, 3])
        check(SecItemUpdate(big as CFDictionary, [kSecValueData as String: long] as CFDictionary) == errSecSuccess && Self.read(big).1 == long, "a long value replaces a long value")
        check(SecItemUpdate(big as CFDictionary, [kSecValueData as String: Data("short".utf8)] as CFDictionary) == errSecSuccess && Self.read(big).1 == Data("short".utf8), "a short value replaces it")

        // every item of one service, the "list my accounts" query
        var all: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "circuit.selftest.tokens"]
        all[kSecMatchLimit as String] = kSecMatchLimitAll
        all[kSecReturnAttributes as String] = true
        var list: AnyObject?
        let listed = SecItemCopyMatching(all as CFDictionary, &list)
        let accounts = ((list as? [[String: Any]]) ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
        check(listed == errSecSuccess && accounts == ["Alice", "alice"], "kSecMatchLimitAll lists the service's accounts (got \(accounts))")

        // rename an account
        check(SecItemUpdate(Self.item("circuit.selftest.tokens", "Alice") as CFDictionary, [kSecAttrAccount as String: "carol"] as CFDictionary) == errSecSuccess, "SecItemUpdate renames an account")
        check(Self.read(Self.item("circuit.selftest.tokens", "carol")).1 == Data("capital".utf8) && Self.read(Self.item("circuit.selftest.tokens", "Alice")).0 == errSecItemNotFound, "the value moved with it")
        check(SecItemUpdate(Self.item("circuit.selftest.tokens", "carol") as CFDictionary, [kSecAttrAccount as String: "alice"] as CFDictionary) == errSecDuplicateItem, "renaming onto an existing item is errSecDuplicateItem")

        // another app's namespace sees none of this
        let mine = CircuitKeychain.namespace
        CircuitKeychain.namespace = "circuit-kit-selftest-other"
        check(Self.read(alice).0 == errSecItemNotFound, "another namespace does not see the item")
        CircuitKeychain.namespace = mine

        // what the kit refuses rather than pretends
        var internet = alice
        internet[kSecClass as String] = kSecClassInternetPassword
        check(SecItemAdd(internet as CFDictionary, nil) == errSecUnimplemented, "internet passwords are errSecUnimplemented")
        var noClass = alice
        noClass.removeValue(forKey: kSecClass as String)
        check(SecItemCopyMatching(noClass as CFDictionary, nil) == errSecParam, "a query without kSecClass is errSecParam")

        // messages and randomness
        check((SecCopyErrorMessageString(errSecItemNotFound, nil) as String?) == "The specified item could not be found in the keychain.", "SecCopyErrorMessageString has Apple's text")
        var a = [UInt8](repeating: 0, count: 32), b = [UInt8](repeating: 0, count: 32)
        check(SecRandomCopyBytes(kSecRandomDefault, a.count, &a) == errSecSuccess && SecRandomCopyBytes(kSecRandomDefault, b.count, &b) == errSecSuccess && a != b && a.contains { $0 != 0 }, "SecRandomCopyBytes gives fresh random bytes")

        // delete
        check(SecItemDelete(big as CFDictionary) == errSecSuccess, "SecItemDelete removes an item")
        check(Self.read(big).0 == errSecItemNotFound, "and it is gone")
        check(SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "circuit.selftest.tokens"] as CFDictionary) == errSecSuccess, "deleting by service removes all its accounts")
        check(SecItemDelete(alice as CFDictionary) == errSecItemNotFound, "deleting again is errSecItemNotFound")

        if ProcessInfo.processInfo.environment["CIRCUIT_KIT_SELFTEST_MARKER"] == "1" {
            var marker = Self.item("marker", "visible")
            marker[kSecValueData as String] = Data("seen from outside".utf8)
            check(SecItemAdd(marker as CFDictionary, nil) == errSecSuccess, "left one item for an outside check: \(CircuitKeychain.namespace)/marker/visible")
        }
        print("\(passes) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}

CircuitKeychain.namespace = "circuit-kit-selftest"
if CommandLine.arguments.contains("--remove-marker") {
    let status = SecItemDelete(SelfTest.item("marker", "visible") as CFDictionary)
    print(status == errSecSuccess ? "PASS marker removed" : "FAIL marker not removed (\(status))")
    exit(status == errSecSuccess ? 0 : 1)
}
var test = SelfTest()
exit(test.run())
