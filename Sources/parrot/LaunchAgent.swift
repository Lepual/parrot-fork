import Foundation

/// Manages the `~/Library/LaunchAgents/com.digimata.parrot.plist` agent that
/// makes parrot start automatically at login.
///
/// This is plain `launchctl` + a hand-written plist, not `SMAppService` —
/// that API is built for agents embedded in a proper `.app` bundle
/// (`Contents/Library/LaunchAgents`) and expects the app to be code-signed
/// with a stable Team ID. parrot ships as a bare binary in `/usr/local/bin`,
/// so a plist we manage directly is actually the better fit here, not a
/// shortcut — it's the same mechanism we've been driving by hand.
enum LaunchAgent {
    static let label = "com.digimata.parrot"
    static let plistPath = ("~/Library/LaunchAgents/\(label).plist" as NSString).expandingTildeInPath

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// Best-effort check for whether the agent is currently loaded (not just
    /// installed) — used to decide whether `restart()` will have anything to
    /// act on.
    static var isLoaded: Bool {
        run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).status == 0
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if !isInstalled {
                try writeDefaultPlist()
            }
            _ = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistPath])
        } else {
            _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
            try? FileManager.default.removeItem(atPath: plistPath)
        }
    }

    /// Force-restarts the running daemon so a freshly-saved config.toml takes
    /// effect. No-ops (rather than erroring) if the agent isn't loaded —
    /// the caller just saved config for next time it's turned on.
    static func restart() {
        guard isLoaded else { return }
        _ = run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
    }

    private static func writeDefaultPlist() throws {
        let home = NSHomeDirectory()
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>KeepAlive</key>
        \t<dict>
        \t\t<key>SuccessfulExit</key>
        \t\t<false/>
        \t</dict>
        \t<key>EnvironmentVariables</key>
        \t<dict>
        \t\t<key>HOME</key>
        \t\t<string>\(home)</string>
        \t</dict>
        \t<key>Label</key>
        \t<string>\(label)</string>
        \t<key>ProcessType</key>
        \t<string>Interactive</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>/usr/local/bin/parrot</string>
        \t\t<string>run</string>
        \t\t<string>--skip-doctor</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>StandardErrorPath</key>
        \t<string>/tmp/parrot.err.log</string>
        \t<key>StandardOutPath</key>
        \t<string>/tmp/parrot.out.log</string>
        </dict>
        </plist>
        """
        let directory = (plistPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return (-1, "\(error)")
        }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
