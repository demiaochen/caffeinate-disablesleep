import Foundation

/// Wraps `pmset -a disablesleep`, the flag that blocks sleep even when the lid
/// closes. Writing it needs root, so changes go through an osascript
/// `do shell script … with administrator privileges` call (system auth dialog).
enum LidLock {
    private static let sudoersPath = "/etc/sudoers.d/caffeinate-disablesleep"
    /// Where the rule is staged before it is published. Inside the destination
    /// directory on purpose: that directory is root-only, it is the same
    /// filesystem so the rename is atomic, and sudo skips include-directory
    /// entries containing a dot, so a half written file is never parsed. A temp
    /// file under `TMPDIR` would instead rest on mktemp continuing to ignore an
    /// environment variable that the calling user controls.
    private static let stagingPath = "/etc/sudoers.d/.caffeinate-disablesleep.tmp"

    /// Serializes privileged calls. The quit path releases the flag from the main
    /// thread while a toggle may still be running on another one, and the release
    /// has to land last rather than race it.
    private static let callLock = NSLock()
    /// The privileged call in flight, so quitting can kill its dialog.
    private static let inFlightLock = NSLock()
    private nonisolated(unsafe) static var inFlight: Process?

    /// Whether this account may be handed the scoped NOPASSWD rule.
    ///
    /// Three gates, all about who ends up holding the rule. The username is
    /// embedded in a root shell command and in the sudoers line, so only names
    /// that cannot break either syntax qualify, and `ALL` is excluded because
    /// sudoers reads it as "every user". And the auth dialog accepts ANY admin's
    /// credentials, so without the group check an admin standing over a standard
    /// account could leave it holding a passwordless root command. Accounts
    /// failing any gate keep working, on the plain prompt-per-use path.
    static let canInstallRule: Bool = {
        let user = NSUserName()
        guard user != "ALL" else { return false }
        guard user.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else { return false }
        guard let groups = output("/usr/bin/id", ["-Gn", user]) else { return false }
        return groups.split(whereSeparator: { $0 == " " || $0 == "\n" }).contains("admin")
    }()

    /// Whether the rule file is on disk. `/etc/sudoers.d` is world readable, so
    /// this costs no privileges and no process, which makes it cheap enough to
    /// run on every panel open. It answers "could the rule be there", not "does
    /// sudo honour it", so it is used to notice a change and trigger the real
    /// probe, never as the answer itself.
    static var ruleFileExists: Bool {
        FileManager.default.fileExists(atPath: sudoersPath)
    }

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

    /// True when our scoped NOPASSWD rule is installed, read from sudo's own
    /// listing. Asking instead "does a pmset command run without a prompt?"
    /// answers yes for an unrelated NOPASSWD entry, or merely for a warm sudo
    /// timestamp left by a terminal, and the caption would then promise silence
    /// the app cannot deliver. No dialog. Drives that caption.
    static func isPasswordless() async -> Bool {
        await Task.detached {
            guard let listing = output("/usr/bin/sudo", ["-n", "-l"]) else { return false }
            // sudo wraps long entries at the terminal width (it honours COLUMNS,
            // which survives env_reset), so fold continuations back onto their
            // own line before matching.
            let folded = listing.replacingOccurrences(of: "\n[ \t]+", with: " ", options: .regularExpression)
            return folded.split(separator: "\n").contains {
                $0.contains("NOPASSWD") && $0.contains("disablesleep")
            }
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
        callLock.lock()
        defer { callLock.unlock() }

        if sudoNoPrompt(on) { return true }
        guard interactive else { return false }

        let flag = "/usr/bin/pmset -a disablesleep \(on ? "1" : "0")"
        // The `;` before pmset keeps the flag change running even when the rule
        // install branch was skipped or failed.
        let shell = canInstallRule ? "\(installShell); \(flag)" : flag
        let prompt =
            canInstallRule
            ? "caffeinate & disablesleep needs your password once. After this it won't ask again."
            : "caffeinate & disablesleep needs your password to change the lid setting."
        return runPrivileged(shell, prompt: prompt)
    }

    /// Installs the rule on its own, without touching the flag: the settings
    /// switch, for someone who wants the silent path before they first use the
    /// lid setting. One admin dialog.
    static func installRule() async -> Bool {
        guard canInstallRule else { return false }
        return await Task.detached { installRuleBlocking() }.value
    }

    private static func installRuleBlocking() -> Bool {
        callLock.lock()
        defer { callLock.unlock() }
        return runPrivileged(
            installShell,
            prompt: "caffeinate & disablesleep needs your password to install the lid permission.")
    }

    /// Removes the rule, clearing the lid setting in the same privileged call.
    /// Order matters and the two cannot be split: once the rule is gone nothing
    /// can clear that setting silently, so a Mac left with it on would stay
    /// awake with no quiet way back.
    static func removeRule() async -> Bool {
        await Task.detached { removeRuleBlocking() }.value
    }

    private static func removeRuleBlocking() -> Bool {
        callLock.lock()
        defer { callLock.unlock() }
        return runPrivileged(
            "/usr/bin/pmset -a disablesleep 0 && /bin/rm -f \(sudoersPath)",
            prompt: "caffeinate & disablesleep needs your password to remove the lid permission.")
    }

    /// Writes the rule and publishes it by rename. Two commands, both writes:
    /// reading the power settings needs no privileges, so `pmset -g` is not in
    /// here. Chained with && so a failed step never publishes a rule, and the
    /// staging file is cleaned up either way (the rename consumes it on the
    /// success path, so the removal is a no-op there).
    private static var installShell: String {
        let rule =
            "\(NSUserName()) ALL=(root) NOPASSWD:"
            + " /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        return "/bin/echo '\(rule)' > \(stagingPath) && /usr/sbin/visudo -cf \(stagingPath) && "
            + "/usr/sbin/chown root:wheel \(stagingPath) && /bin/chmod 440 \(stagingPath) && "
            + "/bin/mv \(stagingPath) \(sudoersPath); /bin/rm -f \(stagingPath)"
    }

    /// Attempts `sudo -n pmset` (non-interactive). Succeeds only when the
    /// NOPASSWD rule is installed; otherwise fails instantly and silently.
    private static func sudoNoPrompt(_ on: Bool) -> Bool {
        exitStatus("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]) == 0
    }

    // MARK: - Process plumbing

    /// Runs a shell command as root behind the system auth dialog. Returns false
    /// when the user cancels or the command fails.
    private static func runPrivileged(_ shell: String, prompt: String) -> Bool {
        let script =
            "do shell script \"\(escapedForAppleScript(shell))\" "
            + "with prompt \"\(escapedForAppleScript(prompt))\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        inFlightLock.lock()
        inFlight = process
        inFlightLock.unlock()
        defer {
            inFlightLock.lock()
            inFlight = nil
            inFlightLock.unlock()
        }
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Kills a privileged call that is still waiting on its password dialog.
    /// That dialog belongs to a child process which outlives the app, so a user
    /// who quits while it is up could otherwise authenticate a change with no
    /// app left to undo it. Best effort, and a no-op when nothing is pending.
    static func cancelPendingPrompt() {
        inFlightLock.lock()
        inFlight?.terminate()
        inFlight = nil
        inFlightLock.unlock()
    }

    private static func escapedForAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

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
