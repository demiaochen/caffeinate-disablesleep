import Foundation
import IOKit.pwr_mgt
import SwiftUI

/// The power-management core. Owns the IOKit assertions that keep the Mac awake
/// (the `caffeinate -disu` replacement), the optional session timer, and the
/// lid-closed lock (`pmset -a disablesleep`, which needs admin rights).
@MainActor
final class AwakeEngine: ObservableObject {
    static let shared = AwakeEngine()

    // MARK: - Published state

    /// True while awake assertions are held.
    @Published private(set) var isActive = false
    /// When the current session auto-ends; nil means "until turned off".
    @Published private(set) var endDate: Date?
    /// Mirrors the system's `pmset disablesleep` flag (sleep blocked even with the lid closed).
    @Published private(set) var lidLockEngaged = false
    /// True when the optional passwordless (NOPASSWD) rule is installed.
    @Published private(set) var passwordless = false
    /// Remaining time of a timed session, pre-formatted. Ticked at 1 Hz ONLY
    /// while the popover is visible — with it closed the app does zero periodic
    /// work. A plain string (not SwiftUI's live timer text) on purpose: a
    /// self-updating Text in the status item retriggers NSStatusItem relayout
    /// continuously and pegs the main thread.
    @Published private(set) var countdown: String?
    /// Mirrors panel visibility; gates the 1 Hz countdown ticking.
    @Published private(set) var popoverVisible = false

    /// Whether the display is kept on too (off = display may sleep, system stays awake).
    @Published var keepDisplayAwake: Bool {
        didSet {
            UserDefaults.standard.set(keepDisplayAwake, forKey: Keys.keepDisplayAwake)
            if isActive { createAssertions() }  // re-shape the held assertions live
        }
    }

    /// Begin a session automatically whenever the app launches.
    @Published var startOnLaunch: Bool {
        didSet { UserDefaults.standard.set(startOnLaunch, forKey: Keys.startOnLaunch) }
    }

    /// The last duration the user picked, restored across launches. nil = indefinite.
    @Published var defaultDuration: TimeInterval? {
        didSet { UserDefaults.standard.set(defaultDuration ?? -1, forKey: Keys.defaultDuration) }
    }

    // MARK: - Private

    private var assertionIDs: [IOPMAssertionID] = []
    private var endTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var pmPrefsSource: DispatchSourceFileSystemObject?
    /// Serializes privileged pmset calls; taps that arrive during a call
    /// coalesce into `pendingLidTarget` so the switch never drops a click.
    private var lidLockTask: Task<Void, Never>?
    private var pendingLidTarget: Bool?

    private enum Keys {
        static let keepDisplayAwake = "keepDisplayAwake"
        static let defaultDuration = "defaultDuration"
        static let startOnLaunch = "startOnLaunch"
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.keepDisplayAwake: true, Keys.defaultDuration: -1.0])
        keepDisplayAwake = defaults.bool(forKey: Keys.keepDisplayAwake)
        startOnLaunch = defaults.bool(forKey: Keys.startOnLaunch)
        let stored = defaults.double(forKey: Keys.defaultDuration)
        defaultDuration = stored < 0 ? nil : stored
        watchPMPreferences()
    }

    // MARK: - Session control

    /// Starts (or restarts) an awake session. nil duration = until turned off.
    func start(duration: TimeInterval?) {
        endTask?.cancel()
        defaultDuration = duration
        createAssertions()
        isActive = true
        if let duration {
            let end = Date().addingTimeInterval(duration)
            endDate = end
            if popoverVisible { startTicking(end: end) }
            endTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } else {
            endDate = nil
            stopTicking()
        }
    }

    /// Ends the session. The lid-closed lock is deliberately left alone — it is
    /// an explicit, admin-authorized flag released only by its own toggle or on
    /// quit; auto-releasing here would pop a password dialog at surprising times
    /// (e.g. when a timer expires unattended).
    func stop() {
        endTask?.cancel()
        endTask = nil
        releaseAssertions()
        isActive = false
        endDate = nil
        stopTicking()
    }

    // MARK: - Countdown ticking (1 Hz, popover-open only)

    /// Called from the popover's onAppear/onDisappear so the timer exists only
    /// while someone is actually looking at the countdown.
    func popoverAppeared() {
        popoverVisible = true
        // Re-read the real pmset flag on every open so a lock engaged or
        // released in a terminal shows up immediately.
        Task { await syncLidLockFromSystem() }
        if let end = endDate { startTicking(end: end) }
    }

    func popoverDisappeared() {
        popoverVisible = false
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func startTicking(end: Date) {
        tickTimer?.invalidate()
        updateCountdown(end: end)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let end = self.endDate else { return }
                self.updateCountdown(end: end)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
        countdown = nil
    }

    private func updateCountdown(end: Date) {
        let remaining = Int(max(0, end.timeIntervalSinceNow).rounded())
        let h = remaining / 3600
        let m = remaining % 3600 / 60
        let s = remaining % 60
        countdown =
            h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    func toggle() {
        isActive ? stop() : start(duration: defaultDuration)
    }

    // MARK: - IOKit assertions

    /// Holds the same set of assertions `caffeinate -disu` takes:
    /// idle-system sleep, system sleep (on AC), and — when enabled — display sleep.
    private func createAssertions() {
        releaseAssertions()
        var types = ["PreventUserIdleSystemSleep", "PreventSystemSleep"]
        if keepDisplayAwake { types.append("PreventUserIdleDisplaySleep") }
        for type in types {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "caffeinate & disablesleep is keeping your Mac awake" as CFString,
                &id
            )
            if result == kIOReturnSuccess { assertionIDs.append(id) }
        }
        if keepDisplayAwake {
            // The `-u` in caffeinate -disu: declare the user active so a dimmed display wakes.
            var id: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity(
                "caffeinate & disablesleep session started" as CFString, kIOPMUserActiveLocal, &id)
        }
    }

    private func releaseAssertions() {
        for id in assertionIDs { IOPMAssertionRelease(id) }
        assertionIDs = []
    }

    // MARK: - Lid-closed lock (pmset disablesleep)

    /// Engages/releases `pmset -a disablesleep`. The switch flips instantly and
    /// every tap lands: targets coalesce and a single worker applies them in
    /// order, so rapid toggling never drops a click. If a call fails (e.g. the
    /// user cancels the password prompt) the state is re-read from the system
    /// and the switch snaps back.
    func setLidLock(_ on: Bool) {
        guard lidLockEngaged != on else { return }
        lidLockEngaged = on
        pendingLidTarget = on
        runLidWorkerIfIdle()
    }

    private func runLidWorkerIfIdle() {
        guard lidLockTask == nil else { return }
        lidLockTask = Task {
            while let target = pendingLidTarget {
                pendingLidTarget = nil
                let ok = await LidLock.set(target)
                if !ok, pendingLidTarget == nil {
                    lidLockEngaged = await LidLock.isEngaged()
                }
            }
            // First engage may have installed the passwordless rule; refresh so
            // the caption stops advertising a password prompt.
            passwordless = await LidLock.isPasswordless()
            lidLockTask = nil
            if pendingLidTarget != nil { runLidWorkerIfIdle() }
        }
    }

    /// Reads the real `pmset` flag so the UI reflects a lock engaged outside the app
    /// (e.g. a leftover `sudo pmset -a disablesleep 1` from the terminal). The
    /// engaged flag is left alone while a toggle is in flight so a stale read
    /// cannot fight the optimistic flip.
    func syncLidLockFromSystem() async {
        let engaged = await LidLock.isEngaged()
        if lidLockTask == nil, pendingLidTarget == nil {
            lidLockEngaged = engaged
        }
        passwordless = await LidLock.isPasswordless()
    }

    /// Live external-change detection at zero idle cost: the kernel signals us
    /// when pmset's preferences file changes; no polling, no timers. pmset
    /// replaces the plist atomically, so on delete/rename we re-arm on the new
    /// file after a short beat.
    private func watchPMPreferences() {
        let path = "/Library/Preferences/com.apple.PowerManagement.plist"
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // Plist transiently absent (restoredefaults, manual removal):
            // retry until it reappears so live mirroring never dies silently.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.watchPMPreferences()
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            let events = source.data
            if !events.isDisjoint(with: [.delete, .rename]) {
                // Cancel synchronously so a second event cannot double re-arm
                // and orphan a watcher (fd leak).
                source.cancel()
                Task { @MainActor in
                    await self?.syncLidLockFromSystem()
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.watchPMPreferences()
                }
            } else {
                Task { @MainActor in await self?.syncLidLockFromSystem() }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        pmPrefsSource = source
    }

    // MARK: - Termination

    /// Called from applicationWillTerminate: releases everything synchronously so
    /// quitting never leaves the Mac unable to sleep.
    func prepareForTermination() {
        endTask?.cancel()
        releaseAssertions()
        // Silent-only: quitting must never block on a password dialog. With the
        // NOPASSWD rule installed (the default after first use) this releases
        // the lock; without it the flag is deliberately left as the user set it.
        if lidLockEngaged { LidLock.setBlocking(false, interactive: false) }
    }

    // MARK: - Command mirror

    /// The `caffeinate` invocation equivalent to the current session shape,
    /// shown verbatim in the popover's command readout.
    var caffeinateCommand: String {
        var cmd = "caffeinate " + (keepDisplayAwake ? "-disu" : "-isu")
        if let duration = defaultDuration { cmd += " -t \(Int(duration))" }
        return cmd
    }

}
