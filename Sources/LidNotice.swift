import AppKit

/// The one-time explainer shown before the first admin prompt for the lid lock:
/// what gets installed, and what a closed lid costs. An NSAlert on purpose. The
/// popover measures its frame once when it opens, so panel content that grows
/// would clip, and this is a rare modal moment rather than a permanent surface.
enum LidNotice {
    private static let key = "lidExplainerAcknowledged"

    static var needsExplainer: Bool { !UserDefaults.standard.bool(forKey: key) }

    /// Returns true when the user chose to continue. Marks itself acknowledged
    /// only then, so a cancel still explains itself the next time.
    @MainActor
    static func showExplainer() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stay awake with lid closed"
        alert.informativeText = body
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: key)
        return true
    }

    /// Two sentences and a caution. What the rule is, and how to undo it, live in
    /// the README and SECURITY.md: the people who want that read files, and this
    /// dialog is read by someone who just clicked a switch.
    private static var body: String {
        let password =
            LidLock.canInstallRule
            ? "This changes a protected system setting. macOS asks for your password and installs permission "
                + "for your account to change this setting without asking again. You can remove it later in "
                + "settings."
            : "This changes a protected system setting, so macOS asks for your password every time."
        return password + "\n\nA closed lid traps heat, so your Mac can get hot while it keeps working."
    }
}
