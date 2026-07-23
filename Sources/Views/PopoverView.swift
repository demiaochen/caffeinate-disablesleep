import SwiftUI

/// The menu bar popover: wordmark + status badge, the flat pulse toggle,
/// duration chips, options, footer. Fixed 300pt wide. No animation anywhere —
/// state changes are instant by design.
struct PopoverView: View {
    @EnvironmentObject private var engine: AwakeEngine

    var body: some View {
        VStack(spacing: 0) {
            header
            AwakeButton()
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 10)
            DurationPicker()
            Divider().padding(.horizontal, 16)
            options
            Divider().padding(.horizontal, 16)
            commands
            footer
        }
        .frame(width: 300)
        .background {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            } else if #available(macOS 26.0, *) {
                // Liquid Glass carries its own adaptive tint; no scrim on top.
                PopoverBackground().ignoresSafeArea()
            } else {
                PopoverBackground()
                    .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.45))
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("caffeinate & disablesleep")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(
                        engine.isActive
                            ? AnyShapeStyle(Palette.inkReverse) : AnyShapeStyle(Color(nsColor: .tertiaryLabelColor))
                    )
                    .frame(width: 5, height: 5)
                Text(badgeText)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(engine.isActive ? AnyShapeStyle(Palette.inkReverse) : AnyShapeStyle(.secondary))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                Capsule().fill(
                    engine.isActive
                        ? AnyShapeStyle(Palette.ink.opacity(0.85))
                        : AnyShapeStyle(Color(nsColor: .quaternarySystemFill)))
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// IDLE · AWAKE · or the remaining time of a timed session.
    private var badgeText: String {
        guard engine.isActive else { return "IDLE" }
        return engine.countdown ?? "AWAKE"
    }

    // MARK: - Options

    private var options: some View {
        VStack(spacing: 1) {
            OptionRow(
                icon: "sun.max",
                title: "Also keep screen on",
                caption: engine.keepDisplayAwake ? "Screen stays on" : "Screen sleeps, Mac runs",
                isOn: $engine.keepDisplayAwake
            )
            LidLockRow()
            OptionRow(
                icon: "play.circle",
                title: "Turn on when app opens",
                caption: nil,
                isOn: $engine.startOnLaunch
            )
            LaunchAtLoginRow()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    // MARK: - Commands

    /// The literal commands this app stands in for, shown like a shell script:
    /// commented out while inactive, live when running.
    private var commands: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(engine.isActive ? engine.caffeinateCommand : "# \(engine.caffeinateCommand)")
                .foregroundStyle(engine.isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            Text("sudo pmset -a disablesleep \(engine.lidLockEngaged ? 1 : 0)")
                .foregroundStyle(engine.lidLockEngaged ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .font(.system(size: 10, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: PanelMetrics.rowRadius).fill(Color(nsColor: .quaternarySystemFill))
        )
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("v\(Bundle.main.shortVersion)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
            QuitButton()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

extension Bundle {
    /// Marketing version (CFBundleShortVersionString), e.g. "1.0".
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

/// The panel surface. On macOS 26 this is real Liquid Glass; earlier systems
/// get the frosted popover material (a scrim above it keeps text contrast
/// stable on busy desktops). The glass API only exists in the macOS 26 SDK,
/// so that branch compiles only under the Swift 6.2+ toolchain; builds from
/// older SDKs keep the compat material everywhere by design.
struct PopoverBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.cornerRadius = PanelMetrics.cornerRadius
                return glass
            }
        #endif
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Quit with a visible shortcut hint and an instant hover state.
struct QuitButton: View {
    @State private var hovering = false

    var body: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            HStack(spacing: 5) {
                Text("Quit")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Text("⌘Q")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(InstantPressStyle(cornerRadius: 4))
        .onHover { hovering = $0 }
        .keyboardShortcut("q", modifiers: .command)
    }
}

/// One settings row: leading symbol, title (+ optional caption), trailing switch.
struct OptionRow: View {
    let icon: String
    let title: String
    let caption: String?
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5))
                if let caption {
                    Text(caption)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .toggleStyle(InkSwitchStyle())
                .labelsHidden()
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: PanelMetrics.rowRadius)
                .fill(hovering ? Color(nsColor: .quaternarySystemFill) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: PanelMetrics.rowRadius))
        .onTapGesture { isOn.toggle() }
        .onHover { hovering = $0 }
    }
}

/// The lid-closed row. The switch flips instantly like every other row; the
/// engine reverts it if the privileged pmset call fails or the password
/// prompt is cancelled.
struct LidLockRow: View {
    @EnvironmentObject private var engine: AwakeEngine

    var body: some View {
        OptionRow(
            icon: "laptopcomputer",
            title: "Stay awake with lid closed",
            caption: engine.passwordless ? "No password · frees on quit" : "Password once · frees on quit",
            isOn: Binding(
                get: { engine.lidLockEngaged },
                set: { engine.setLidLock($0) }
            )
        )
        .task { await engine.syncLidLockFromSystem() }
    }
}

/// Launch-at-login row backed by SMAppService. The switch only reflects a
/// registration that actually succeeded, and re-reads the real state on every
/// panel open (System Settings can change it behind our back).
struct LaunchAtLoginRow: View {
    @EnvironmentObject private var engine: AwakeEngine
    @State private var enabled = LoginItem.isEnabled

    var body: some View {
        OptionRow(
            icon: "arrow.right.circle",
            title: "Open app at login",
            caption: nil,
            isOn: Binding(
                get: { enabled },
                set: { wanted in
                    enabled = LoginItem.set(wanted) ? wanted : LoginItem.isEnabled
                }
            )
        )
        .onChange(of: engine.popoverVisible) { _, visible in
            if visible { enabled = LoginItem.isEnabled }
        }
        .onAppear { enabled = LoginItem.isEnabled }
    }
}
