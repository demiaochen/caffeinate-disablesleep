import AppKit
import SwiftUI

/// The window behind the version label: the two launch settings and a link to
/// the source. They live here rather than in the panel because you set them once
/// and never look again, while the panel is for what you toggle daily.
@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if let existing = window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: AboutView().environmentObject(AwakeEngine.shared))
        let created = AboutPanel(contentViewController: hosting)
        // The wordmark inside the window is the title, the same way it is in the
        // panel, so the chrome carries only the close button.
        created.styleMask = [.titled, .closable]
        created.titleVisibility = .hidden
        created.titlebarAppearsTransparent = true
        created.isMovableByWindowBackground = true
        created.isReleasedWhenClosed = false
        created.center()
        window = created
        NSApp.activate(ignoringOtherApps: true)
        created.makeKeyAndOrderFront(nil)
    }
}

/// Escape closes it, like the panel.
final class AboutPanel: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

/// Wordmark and version, the two launch settings, the source link. Same header
/// shape, same row grammar and same 16pt margin as the panel, so this reads as
/// the second page of one surface rather than a settings sheet.
struct AboutView: View {
    @EnvironmentObject private var engine: AwakeEngine
    @State private var launchAtLogin = LoginItem.isEnabled

    private static let repo = "https://github.com/demiaochen/caffeinate-disablesleep"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 16)
            settings
            if LidLock.canInstallRule {
                Divider().padding(.horizontal, 16)
                permission
            }
            Divider().padding(.horizontal, 16)
            source
        }
        .frame(width: 300)
        .onAppear { launchAtLogin = LoginItem.refresh() }
    }

    /// Mirrors the panel header: wordmark left, small mono fact right.
    private var header: some View {
        HStack {
            Text("caffeinate & disablesleep")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            Spacer()
            Text("v\(Bundle.main.shortVersion)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var settings: some View {
        VStack(spacing: 1) {
            OptionRow(
                icon: "play.circle",
                title: "Turn on when app opens",
                caption: nil,
                isOn: $engine.startOnLaunch
            )
            OptionRow(
                icon: "arrow.right.circle",
                title: "Open app at login",
                caption: nil,
                isOn: Binding(
                    get: { launchAtLogin },
                    set: { wanted in
                        launchAtLogin = LoginItem.set(wanted) ? wanted : LoginItem.refresh()
                    }
                )
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    /// The sudoers rule as a switch: on installs it, off removes it and clears
    /// the lid setting with it. Hidden on accounts that can never hold the rule,
    /// where the switch would be a control that cannot move.
    private var permission: some View {
        OptionRow(
            icon: "key",
            title: "Lid permission",
            caption: engine.passwordless ? "Installed, no password needed" : "Not installed, asks every time",
            isOn: Binding(
                get: { engine.passwordless },
                set: { engine.setLidPermission($0) }
            )
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private var source: some View {
        LinkRow(icon: "chevron.left.forwardslash.chevron.right", title: "Source on GitHub", url: Self.repo)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
    }
}

/// A row that opens a URL instead of flipping a switch. Same skeleton as
/// `OptionRow` (18pt symbol, 12.5pt title, hover fill, whole row is the target)
/// so the two never look like different kinds of control; the trailing glyph is
/// what says "this leaves the app".
struct LinkRow: View {
    let icon: String
    let title: String
    let url: String
    @State private var hovering = false

    var body: some View {
        Button {
            if let link = URL(string: url) { NSWorkspace.shared.open(link) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: PanelMetrics.rowRadius)
                    .fill(hovering ? Color(nsColor: .quaternarySystemFill) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: PanelMetrics.rowRadius))
        }
        .buttonStyle(InstantPressStyle(cornerRadius: PanelMetrics.rowRadius))
        .onHover { hovering = $0 }
        .accessibilityLabel("\(title), opens in your browser")
    }
}
