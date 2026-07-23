import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Menu bar app entry point. The status item and its panel are hand-rolled
/// AppKit (no MenuBarExtra): left click opens the panel, right click (or
/// control click) toggles the session directly.
@main
struct MenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Panel geometry. macOS 26 glass panels are rounder, and the inner controls
/// round with them (concentric corners: inner radius tracks shell radius
/// minus inset). Older systems keep the original tight geometry. The 1 pt
/// menu bar gap is the same everywhere (a larger float was tried and
/// rejected).
enum PanelMetrics {
    static var cornerRadius: CGFloat {
        if #available(macOS 26.0, *) { return 26 }
        return 13
    }
    /// The moon field (inset 16 from the shell).
    static var fieldRadius: CGFloat {
        if #available(macOS 26.0, *) { return 10 }
        return 6
    }
    /// Duration chips.
    static var chipRadius: CGFloat {
        if #available(macOS 26.0, *) { return 7 }
        return 5
    }
    /// Option-row hover fill and the commands readout.
    static var rowRadius: CGFloat {
        if #available(macOS 26.0, *) { return 8 }
        return 6
    }
}

/// Borderless key-capable panel that dismisses like a system menu bar popover:
/// on losing key status or on Escape.
final class PopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: PopoverPanel?
    private var hosting: NSHostingController<AnyView>?
    private var sigusr2Source: DispatchSourceSignal?
    private var sigusr1Source: DispatchSourceSignal?
    private var engineSink: AnyCancellable?
    private var panelObservers: [any NSObjectProtocol] = []
    private var debugWindow: NSWindow?
    private var panelHiddenAt: Date = .distantPast
    private var lastAnchorMidX: CGFloat = .nan

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Status item: icon reflects engine state; both click kinds handled.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.currentIcon()
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "caffeinate & disablesleep"
        }
        statusItem = item

        // Re-render the status icon whenever engine state changes. The icon is
        // cached per state, so identity compares cheaply skip no-op assignments
        // (countdown ticks publish every second while the panel is open).
        engineSink = AwakeEngine.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let button = self?.statusItem?.button else { return }
                let icon = Self.currentIcon()
                if button.image !== icon { button.image = icon }
            }

        // Scripting/testing hooks: `kill -USR2 <pid>` toggles the session,
        // `kill -USR1 <pid>` toggles the panel (screenshots without AX access).
        signal(SIGUSR2, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        source.setEventHandler { Task { @MainActor in AwakeEngine.shared.toggle() } }
        source.resume()
        sigusr2Source = source
        signal(SIGUSR1, SIG_IGN)
        let panelSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        panelSource.setEventHandler { [weak self] in Task { @MainActor in self?.togglePanel() } }
        panelSource.resume()
        sigusr1Source = panelSource

        // UPTIME_DEBUG_DARK=1 forces the whole app dark (panel included) so
        // headless screenshot runs need not touch the system appearance.
        if ProcessInfo.processInfo.environment["UPTIME_DEBUG_DARK"] == "1" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        Task { @MainActor in
            await AwakeEngine.shared.syncLidLockFromSystem()
            if AwakeEngine.shared.startOnLaunch {
                AwakeEngine.shared.start(duration: AwakeEngine.shared.defaultDuration)
            }
        }

        if ProcessInfo.processInfo.environment["UPTIME_DEBUG_WINDOW"] == "1" {
            showDebugWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AwakeEngine.shared.prepareForTermination()
    }

    private static func currentIcon() -> NSImage {
        let engine = AwakeEngine.shared
        return StatusIcon.image(
            active: engine.isActive,
            displayOn: engine.keepDisplayAwake,
            timed: engine.endDate != nil,
            lid: engine.lidLockEngaged)
    }

    // MARK: - Clicks

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRight =
            event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRight {
            AwakeEngine.shared.toggle()
            return
        }
        togglePanel()
    }

    // MARK: - Panel

    private func togglePanel() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        // A click that dismissed the panel (via resignKey) also fires the button
        // action; suppress the instant reopen, but only when the click is at the
        // same item the panel was anchored to. A click on the other display's
        // copy should reopen there immediately.
        let nearPrevious = abs(NSEvent.mouseLocation.x - lastAnchorMidX) < 40
        guard !(nearPrevious && Date().timeIntervalSince(panelHiddenAt) < 0.3) else { return }
        showPanel()
    }

    private func showPanel() {
        // Anchor to the display actually clicked: the click event's window is the
        // status bar window on that display; the item's own window may still be
        // parked on the previously used display.
        let eventWindow = NSApp.currentEvent?.window
        guard let button = statusItem?.button,
            let anchorWindow = eventWindow ?? button.window,
            let screen = anchorWindow.screen
        else { return }

        if panel == nil { buildPanel() }
        guard let panel, let hosting else { return }

        hosting.view.layoutSubtreeIfNeeded()
        let size = hosting.view.fittingSize
        let itemFrame = anchorWindow.frame
        var x = itemFrame.midX - size.width / 2
        x = max(screen.visibleFrame.minX + 8, min(x, screen.visibleFrame.maxX - size.width - 8))
        let y = itemFrame.minY - size.height - 1
        lastAnchorMidX = itemFrame.midX
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func buildPanel() {
        let root = AnyView(
            PopoverView()
                .environmentObject(AwakeEngine.shared)
                .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        )
        let hostingController = NSHostingController(rootView: root)
        let newPanel = PopoverPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        newPanel.contentViewController = hostingController
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.level = .statusBar
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.isReleasedWhenClosed = false
        newPanel.hidesOnDeactivate = false

        // Tokens are retained for the app's lifetime; the panel is built once.
        panelObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: newPanel, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.statusItem?.button?.highlight(true)
                    AwakeEngine.shared.popoverAppeared()
                }
            })
        panelObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: newPanel, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.panelHiddenAt = Date()
                    self?.statusItem?.button?.highlight(false)
                    AwakeEngine.shared.popoverDisappeared()
                }
            })

        self.hosting = hostingController
        self.panel = newPanel
    }

    /// Screenshot/dev aid: shows the popover content in a plain window at a
    /// known position so build tooling can capture it without AX scripting.
    /// UPTIME_DEBUG_DARK=1 forces the dark appearance.
    private func showDebugWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 120, width: 300, height: 560),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        if ProcessInfo.processInfo.environment["UPTIME_DEBUG_DARK"] == "1" {
            window.appearance = NSAppearance(named: .darkAqua)
        }
        window.contentView = NSHostingView(
            rootView: PopoverView().environmentObject(AwakeEngine.shared))
        window.makeKeyAndOrderFront(nil)
        debugWindow = window
    }
}

/// Draws the composable status glyph (18 pt template, cached per state).
/// Geometry lives in a 36-unit box matching the brand mark, scaled by 0.5.
///   strike = awake · solid fill = screen held on · hollow = screen not held
///   dot = timed session · underline = lid-closed lock engaged
enum StatusIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(active: Bool, displayOn: Bool, timed: Bool, lid: Bool) -> NSImage {
        let hollow = !active || !displayOn
        let key = "\(active)-\(hollow)-\(active && timed)-\(lid)"
        if let cached = cache[key] { return cached }

        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let s: CGFloat = 0.5
            let outer = NSBezierPath(ovalIn: NSRect(x: 5.93 * s, y: 4.69 * s, width: 23.62 * s, height: 23.62 * s))
            let inner = NSBezierPath(ovalIn: NSRect(x: 19.11 * s, y: 1.59 * s, width: 29.82 * s, height: 29.82 * s))
            NSColor.black.setFill()
            NSColor.black.setStroke()

            if hollow {
                NSGraphicsContext.current?.saveGraphicsState()
                outer.addClip()
                outer.lineWidth = 4.2 * s
                outer.stroke()
                inner.lineWidth = 4.2 * s
                inner.stroke()
                NSGraphicsContext.current?.restoreGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(
                    ovalIn: NSRect(
                        x: (19.11 + 2.1) * s, y: (1.59 + 2.1) * s,
                        width: (29.82 - 4.2) * s, height: (29.82 - 4.2) * s)
                ).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            } else {
                outer.fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                inner.fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }

            if active {
                let strike = NSBezierPath()
                strike.move(to: NSPoint(x: 7 * s, y: 27.5 * s))
                strike.line(to: NSPoint(x: 29 * s, y: 5.5 * s))
                strike.lineWidth = 3 * s
                strike.lineCapStyle = .round
                strike.stroke()
            }
            if active && timed {
                NSBezierPath(
                    ovalIn: NSRect(
                        x: (30.5 - 2.6) * s, y: (27 - 2.6) * s,
                        width: 5.2 * s, height: 5.2 * s)
                ).fill()
            }
            if lid {
                let bar = NSBezierPath()
                bar.move(to: NSPoint(x: 8 * s, y: 33 * s))
                bar.line(to: NSPoint(x: 28 * s, y: 33 * s))
                bar.lineWidth = 2.8 * s
                bar.lineCapStyle = .round
                bar.stroke()
            }
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }
}

/// Login-item registration via SMAppService (macOS 13+).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            NSLog("login item change failed: \(error.localizedDescription)")
            return false
        }
    }
}
