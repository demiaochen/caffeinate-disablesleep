import SwiftUI

/// Brand palette. Monochrome: ink is the only accent; state is carried by
/// filled-vs-outline marks and inverted fills, never by hue.
enum Palette {
    static let ink = Color.primary
    /// Text/dot color on top of an ink-filled surface.
    static let inkReverse = Color(nsColor: .windowBackgroundColor)
}

/// The brand mark as a shape: a crescent moon, optionally struck through.
/// Same geometry as the menu bar glyphs and the app icon.
struct MoonGlyph: Shape {
    var struck: Bool
    var filled: Bool = true

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 36
        let outer = Path(ellipseIn: CGRect(x: 5.94 * s, y: 6.19 * s, width: 23.62 * s, height: 23.62 * s))
        let inner = Path(ellipseIn: CGRect(x: 19.11 * s, y: 3.09 * s, width: 29.82 * s, height: 29.82 * s))
        var moon = outer.subtracting(inner)
        if !filled {
            // rim only: subtract an inset crescent, leaving a ~2.1 outline
            let outerInset = Path(
                ellipseIn: CGRect(
                    x: (5.94 + 2.1) * s, y: (6.19 + 2.1) * s,
                    width: (23.62 - 4.2) * s, height: (23.62 - 4.2) * s))
            let innerGrown = Path(
                ellipseIn: CGRect(
                    x: (19.11 - 2.1) * s, y: (3.09 - 2.1) * s,
                    width: (29.82 + 4.2) * s, height: (29.82 + 4.2) * s))
            moon = moon.subtracting(outerInset.subtracting(innerGrown))
        }
        if struck {
            var line = Path()
            line.move(to: CGPoint(x: 7 * s, y: 29 * s))
            line.addLine(to: CGPoint(x: 29 * s, y: 7 * s))
            moon = moon.union(line.strokedPath(StrokeStyle(lineWidth: 3 * s, lineCap: .round)))
        }
        return moon
    }
}

/// The toggle: a flat bordered field holding the moon mark — plain moon when
/// the Mac may sleep, struck moon while kept awake. No motion; instant.
struct AwakeButton: View {
    @EnvironmentObject private var engine: AwakeEngine
    @State private var hovering = false

    var body: some View {
        Button {
            engine.toggle()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: PanelMetrics.fieldRadius)
                    .fill(Color(nsColor: hovering ? .tertiarySystemFill : .quaternarySystemFill))
                RoundedRectangle(cornerRadius: PanelMetrics.fieldRadius)
                    .strokeBorder(
                        Color.primary.opacity(
                            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                                ? 0.7 : (engine.isActive ? 0.5 : 0.08)),
                        lineWidth: 1)
                MoonGlyph(
                    struck: engine.isActive,
                    filled: engine.isActive && engine.keepDisplayAwake
                )
                .fill(engine.isActive ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(Color.secondary.opacity(0.65)))
                .frame(width: 22, height: 22)
            }
            .frame(height: 46)
            .contentShape(RoundedRectangle(cornerRadius: PanelMetrics.fieldRadius))
        }
        .buttonStyle(InstantPressStyle(cornerRadius: PanelMetrics.fieldRadius))
        .onHover { hovering = $0 }
        .help(engine.isActive ? "Stop keeping the Mac awake" : "Keep the Mac awake")
        .accessibilityLabel(engine.isActive ? "Stop keeping the Mac awake" : "Keep the Mac awake")
    }
}

/// Zero-animation switch: ink capsule, knob jumps instantly between ends.
/// Replaces the system switch, whose knob animation got noticeably slower on
/// macOS 26; also keeps the on state monochrome instead of the accent color.
struct InkSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(
                configuration.isOn
                    ? AnyShapeStyle(Palette.ink.opacity(0.85))
                    : AnyShapeStyle(Color(nsColor: .tertiarySystemFill))
            )
            .frame(width: 26, height: 15)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle()
                    .fill(configuration.isOn ? AnyShapeStyle(Palette.inkReverse) : AnyShapeStyle(Color.white))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .padding(2)
            }
    }
}

/// Instant pressed-state tint (no animation): one shade darker while held.
struct InstantPressStyle: ButtonStyle {
    var cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
            )
    }
}

/// Session length model + the chip row.
struct DurationPreset: Identifiable, Equatable {
    let label: String
    let seconds: TimeInterval?
    var id: String { label }

    static let all: [DurationPreset] = [
        .init(label: "15m", seconds: 15 * 60),
        .init(label: "30m", seconds: 30 * 60),
        .init(label: "1h", seconds: 3600),
        .init(label: "2h", seconds: 2 * 3600),
        .init(label: "4h", seconds: 4 * 3600),
        .init(label: "8h", seconds: 8 * 3600),
        .init(label: "∞", seconds: nil),
    ]

    var accessibilityName: String {
        seconds == nil ? "indefinitely" : "for \(label)"
    }
}

/// Row of duration chips. Picking one starts (or retimes) a session. The chip
/// matching the stored duration reads "armed" while idle, ink-filled while running.
struct DurationPicker: View {
    @EnvironmentObject private var engine: AwakeEngine

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DurationPreset.all) { preset in
                DurationChip(
                    preset: preset,
                    selected: engine.defaultDuration == preset.seconds,
                    running: engine.isActive
                ) {
                    // Clicking the chip of the running session cancels it;
                    // any other chip starts (or retimes to) that duration.
                    if engine.isActive && engine.defaultDuration == preset.seconds {
                        engine.stop()
                    } else {
                        engine.start(duration: preset.seconds)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

struct DurationChip: View {
    let preset: DurationPreset
    let selected: Bool
    let running: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(preset.label)
                .font(
                    .system(
                        size: preset.seconds == nil ? 15 : 10.5,
                        weight: selected ? .semibold : .regular, design: .monospaced)
                )
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: PanelMetrics.chipRadius).fill(background))
                .contentShape(RoundedRectangle(cornerRadius: PanelMetrics.chipRadius))
        }
        .buttonStyle(InstantPressStyle(cornerRadius: PanelMetrics.chipRadius))
        .onHover { hovering = $0 }
        .help(selected && running ? "Stop the session" : "Stay awake \(preset.accessibilityName)")
        .accessibilityLabel(selected && running ? "Stop the session" : "Stay awake \(preset.accessibilityName)")
    }

    private var foreground: AnyShapeStyle {
        if selected && running { return AnyShapeStyle(Palette.inkReverse) }
        if selected { return AnyShapeStyle(.primary) }
        return AnyShapeStyle(.secondary)
    }

    private var background: AnyShapeStyle {
        if selected && running { return AnyShapeStyle(Palette.ink.opacity(0.85)) }
        if selected { return AnyShapeStyle(Color(nsColor: .tertiarySystemFill)) }
        return AnyShapeStyle(Color(nsColor: hovering ? .tertiarySystemFill : .quaternarySystemFill))
    }
}
