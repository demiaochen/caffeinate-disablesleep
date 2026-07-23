import Foundation

/// Wraps `pmset -a disablesleep`, the flag that blocks sleep even when the lid
/// closes. Writing it needs root, so changes go through an osascript
/// `do shell script … with administrator privileges` call (system auth dialog).
enum LidLock {
    private static let sudoersPath = "/etc/sudoers.d/caffeinate-disablesleep"

    /// Reads the current flag from `pmset -g` ("SleepDisabled 1"). No privileges needed.
    static func isEngaged() async -> Bool {
        await Task.detached {
            let out = output("/usr/bin/pmset", ["-g"]) ?? ""
            for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
                return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
            }
            return false
        }.value
    }

    /// True when the scoped NOPASSWD rule is active (probes the read-only
    /// `pmset -g`, which the rule also permits). No dialog. Drives the caption
    /// that tells the user whether the next toggle will ask for a password.
    static func isPasswordless() async -> Bool {
        await Task.detached {
            exitStatus("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-g"]) == 0
        }.value
    }

    /// Sets the flag via an admin prompt. Returns true on success, false if the
    /// user cancelled the auth dialog or pmset failed.
    static func set(_ on: Bool) async -> Bool {
        await Task.detached { setBlocking(on) }.value
    }

    /// Synchronous variant. Interactive first use shows one admin dialog that
    /// also installs a scoped NOPASSWD rule (visudo-validated), so every later
    /// toggle is silent via `sudo -n`. With `interactive: false` (app
    /// termination) only the silent path is attempted: quitting must never
    /// block on a modal password dialog.
    @discardableResult
    static func setBlocking(_ on: Bool, interactive: Bool = true) -> Bool {
        if sudoNoPrompt(on) { return true }
        guard interactive else { return false }

        // The username is embedded in a root shell command and a sudoers rule;
        // only install the rule for names that cannot break either syntax.
        // Unusual names still get the plain prompt-per-use path.
        let user = NSUserName()
        let userIsSafe = user.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil

        let flag = "/usr/bin/pmset -a disablesleep \(on ? "1" : "0")"
        let shell: String
        if userIsSafe {
            let rule =
                "\(user) ALL=(ALL) NOPASSWD: /usr/bin/pmset -g,"
                + " /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
            let install =
                "t=$(/usr/bin/mktemp); /bin/echo '\(rule)' > \"$t\"; "
                + "if /usr/sbin/visudo -cf \"$t\"; then "
                + "/bin/mv \"$t\" \(sudoersPath); /usr/sbin/chown root:wheel \(sudoersPath); "
                + "/bin/chmod 440 \(sudoersPath); "
                + "else /bin/rm -f \"$t\"; fi"
            // The `;` before pmset keeps the flag change running even when the
            // rule install branch was skipped or failed.
            shell = "\(install); \(flag)"
        } else {
            shell = flag
        }
        let prompt =
            userIsSafe
            ? "caffeinate & disablesleep needs your password once. After this it won't ask again."
            : "caffeinate & disablesleep needs your password to change the lid setting."
        let escaped =
            shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
        return exitStatus("/usr/bin/osascript", ["-e", script]) == 0
    }

    /// Attempts `sudo -n pmset` (non-interactive). Succeeds only when the
    /// NOPASSWD rule is installed; otherwise fails instantly and silently.
    private static func sudoNoPrompt(_ on: Bool) -> Bool {
        exitStatus("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]) == 0
    }

    // MARK: - Process plumbing

    /// Runs a tool to completion, discarding its output. Returns the exit
    /// status, or -1 when the tool could not launch.
    private static func exitStatus(_ path: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    /// Runs a tool to completion and returns its stdout, or nil when it could not launch.
    private static func output(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
