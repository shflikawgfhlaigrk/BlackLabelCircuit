import Foundation

@main
struct UpdaterSwapChecks {
    @MainActor
    static func main() throws {
        for mode in ["success", "first-move", "second-move", "relaunch", "restore"] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("circuit-swap-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let installed = dir.appendingPathComponent("Circuit owner's app.app")
            let staged = dir.appendingPathComponent("ready.app")
            let backup = dir.appendingPathComponent("backup.app")
            for (url, text) in [(installed, "old"), (staged, "new")] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try text.write(to: url.appendingPathComponent("identity"), atomically: true, encoding: .utf8)
            }
            let bin = dir.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let mover = bin.appendingPathComponent("mv")
            let opener = bin.appendingPathComponent("open-fixture")
            try """
            #!/bin/sh
            if [ "$FIXTURE_MODE" = first-move ] && [ "$1" = "$FIXTURE_INSTALLED" ]; then exit 1; fi
            if { [ "$FIXTURE_MODE" = second-move ] || [ "$FIXTURE_MODE" = restore ]; } && [ "$1" = "$FIXTURE_STAGED" ]; then exit 1; fi
            if [ "$FIXTURE_MODE" = restore ] && [ "$1" = "$FIXTURE_BACKUP" ]; then exit 1; fi
            exec /bin/mv "$@"
            """.write(to: mover, atomically: true, encoding: .utf8)
            try """
            #!/bin/sh
            value=$(/bin/cat "$1/identity") || exit 1
            printf '%s\\n' "$value" >> "$FIXTURE_LOG"
            if [ "$FIXTURE_MODE" = relaunch ] && [ "$value" = new ]; then exit 1; fi
            """.write(to: opener, atomically: true, encoding: .utf8)
            for executable in [mover, opener] {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            }
            let script = dir.appendingPathComponent("swap.sh")
            try UpdaterUI.swapScript(waitForPID: Int32.max).write(to: script, atomically: true, encoding: .utf8)
            let log = dir.appendingPathComponent("opened.log")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, installed.path, staged.path, backup.path, opener.path]
            process.environment = ProcessInfo.processInfo.environment.merging([
                "PATH": bin.path + ":/usr/bin:/bin", "FIXTURE_MODE": mode,
                "FIXTURE_INSTALLED": installed.path, "FIXTURE_STAGED": staged.path,
                "FIXTURE_BACKUP": backup.path, "FIXTURE_LOG": log.path,
            ]) { _, value in value }
            try process.run()
            process.waitUntilExit()
            let opened = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
            if mode == "success" {
                precondition(process.terminationStatus == 0 && opened == ["new"])
                precondition(!FileManager.default.fileExists(atPath: backup.path))
            } else {
                precondition(process.terminationStatus != 0 && opened.last == "old")
                let surviving = mode == "restore" ? backup : installed
                let identity = try String(contentsOf: surviving.appendingPathComponent("identity"), encoding: .utf8)
                precondition(identity == "old")
            }
            print("PASS: \(mode) retains and reopens the expected fixture")
        }
    }
}
