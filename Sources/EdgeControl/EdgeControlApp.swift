import AppKit
import SwiftUI
import CoreGraphics
import ServiceManagement
import ApplicationServices
import Darwin

@main
struct EdgeControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

private enum AppVersion {
    static var current: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var settingsWindow: NSWindow?
    private var gestures: EdgeGestureController!
    private var statusItem: NSStatusItem?
    private var statusItemVisibilityObservation: NSKeyValueObservation?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 372, height: 760)
        popover.contentViewController = NSHostingController(rootView: Dashboard())
        return popover
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // Preserve user settings when moving to the new application identity.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "migratedFromOriginalIdentity") {
            for domain in ["com.edgebar.menubar", "com.edgebar.app"] {
                if let previous = defaults.persistentDomain(forName: domain) {
                    for (key, value) in previous where !key.hasPrefix("NSStatusItem") {
                        defaults.set(value, forKey: key)
                    }
                }
            }
            defaults.set(true, forKey: "migratedFromOriginalIdentity")
        }
        Pref.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        // Recover once from a removed item or a position behind the notch.
        if !UserDefaults.standard.bool(forKey: "menuBarPositionRecovered43") {
            resetStatusItemPlacement()
            UserDefaults.standard.set(true, forKey: "menuBarPositionRecovered43")
        }
        createStatusItem()
        statusItem?.isVisible = Pref.bool("showInMenuBar", true)
        if !Pref.bool("hasLaunchedWithMenuBarIcon", false) {
            Pref.defaults.set(true, forKey: "hasLaunchedWithMenuBarIcon")
            if statusItem?.isVisible != true { showSettings() }
        }
        settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 372, height: 760),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow?.title = "EdgeControl"
        settingsWindow?.isReleasedWhenClosed = false
        settingsWindow?.contentViewController = NSHostingController(rootView: Dashboard())
        settingsWindow?.center()
        installSettingsDismissal()
        gestures = EdgeGestureController()
        gestures.start()
    }

    func showSettings() {
        guard let settingsWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        showSettings()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        gestures.stop()
        DisplayBrightness.restoreExtendedBrightness()
    }

    private func dismissSettingsOverview() {
        // Keep permission help sheets usable until the user dismisses them.
        if settingsWindow?.attachedSheet == nil { settingsWindow?.orderOut(nil) }
        if popover.isShown, popover.contentViewController?.view.window?.attachedSheet == nil {
            popover.performClose(nil)
        }
    }

    private func installSettingsDismissal() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            self?.dismissSettingsOverview()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self else { return event }
            // Leave the status button's toggle and picker menus to AppKit.
            if let window = event.window {
                if window === self.statusItem?.button?.window ||
                    window.level.rawValue >= NSWindow.Level.popUpMenu.rawValue {
                    return event
                }
                var ancestor: NSWindow? = window
                while let current = ancestor {
                    if current === self.settingsWindow ||
                        current === self.popover.contentViewController?.view.window {
                        return event
                    }
                    ancestor = current.parent
                }
            }
            self.dismissSettingsOverview()
            return event
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        dismissSettingsOverview()
    }

    func setMenuBarVisible(_ visible: Bool) {
        if visible, statusItem == nil { createStatusItem() }
        statusItem?.isVisible = visible
        if visible { showSettings() }
    }

    func restoreMenuBarItem() {
        if let statusItem {
            statusItemVisibilityObservation = nil
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        resetStatusItemPlacement()
        createStatusItem()
        statusItem?.isVisible = true
    }

    private func resetStatusItemPlacement() {
        let defaults = UserDefaults.standard
        let name = "EdgeBar.StatusItem.v43"
        // AppKit restores position as well as visibility using the autosave name.
        // A fresh item at the left end can still be clipped by a crowded menu bar.
        defaults.set(true, forKey: "NSStatusItem Visible \(name)")
        defaults.set(true, forKey: "NSStatusItem VisibleCC \(name)")
        defaults.set(0, forKey: "NSStatusItem Preferred Position \(name)")
        defaults.set(true, forKey: "showInMenuBar")
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "EdgeBar.StatusItem.v43"
        if let image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "EdgeControl") {
            image.isTemplate = true
            item.button?.image = image
        }
        if item.button?.image == nil { item.button?.title = "EB" }
        item.button?.toolTip = "EdgeControl"
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak item] in
            guard let item else { return }
            let diagnostic = "visible=\(item.isVisible) length=\(item.length) frame=\(String(describing: item.button?.window?.frame)) screen=\(String(describing: item.button?.window?.screen?.frame))"
            NSLog("EdgeControl status item: %@", diagnostic)
            UserDefaults.standard.set(diagnostic, forKey: "menuBarDiagnostic")
        }
        statusItemVisibilityObservation = item.observe(\.isVisible, options: [.new]) { [weak self, weak item] _, change in
            guard change.newValue == false, Pref.bool("showInMenuBar", true) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak item] in
                guard let self, let item, self.statusItem === item else { return }
                item.isVisible = true
            }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(sender) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            DispatchQueue.main.async { [weak self] in
                self?.popover.contentViewController?.view.window?.makeKey()
            }
        }
    }
}

enum CornerTapZone {
    static func contains(_ point: CGPoint, corner: String, fraction: Double) -> Bool {
        guard point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y) else { return false }
        let inset = CGFloat(fraction.isFinite ? min(0.20, max(0.04, fraction)) : 0.12)
        let left = point.x <= inset
        let right = point.x >= 1 - inset
        let top = point.y >= 1 - inset
        let bottom = point.y <= inset
        switch corner {
        case "topLeft": return left && top
        case "bottomLeft": return left && bottom
        case "bottomRight": return right && bottom
        default: return right && top
        }
    }
}

// A single-touch hold; time is injected so cancellation and timing can be tested
// without invoking the system lock screen.
struct CornerHoldGesture {
    static let countdownDelay: TimeInterval = 0.3
    private(set) var beganAt: TimeInterval?
    private(set) var didFire = false
    private(set) var duration: TimeInterval = 1
    private var cancelled = false
    private var origin = CGPoint.zero
    private var corner = "topLeft"
    private var fraction = 0.12

    var isTracking: Bool { beganAt != nil && !cancelled && !didFire }

    mutating func begin(at point: CGPoint, now: TimeInterval, corner: String,
                        fraction: Double, duration: TimeInterval) {
        self = CornerHoldGesture()
        guard CornerTapZone.contains(point, corner: corner, fraction: fraction) else { return }
        origin = point
        self.corner = corner
        self.fraction = fraction
        self.duration = duration.isFinite ? min(3, max(0.5, duration)) : 1
        beganAt = now
    }

    mutating func cancel() {
        cancelled = true
        didFire = false
    }

    mutating func update(at point: CGPoint, now: TimeInterval) -> Bool {
        guard let beganAt, !cancelled else { return false }
        guard CornerTapZone.contains(point, corner: corner, fraction: fraction),
              hypot(point.x - origin.x, point.y - origin.y) <= 0.025 else {
            cancel()
            return false
        }
        guard !didFire, now - beganAt >= duration else { return false }
        didFire = true
        return true
    }

    func suppressesTap(now: TimeInterval) -> Bool {
        guard let beganAt else { return false }
        return didFire || now - beganAt >= 0.25
    }

    func countdownTenths(now: TimeInterval) -> Int? {
        guard let beganAt, !cancelled, now >= beganAt + Self.countdownDelay else { return nil }
        let remaining = max(0, duration - max(0, now - beganAt))
        // Avoid rounding an exact tenth up due to floating-point noise.
        return max(0, Int(ceil(remaining * 10 - 0.000001)))
    }
}

enum ScreenLock {
    private static let framework = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW | RTLD_LOCAL)
    private static let lockFunction: (@convention(c) () -> Void)? = {
        guard let framework, let symbol = dlsym(framework, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Void).self)
    }()
    static var isAvailable: Bool { lockFunction != nil }
    static func requestLock() { lockFunction?() }
}

enum Pref {
    static let defaults = UserDefaults.standard
    static func registerDefaults() {
        let needsVolumeEdgeMigration = defaults.object(forKey: "volumeEdge") == nil
        let needsBrightnessEdgeMigration = defaults.object(forKey: "brightnessEdge") == nil
        defaults.register(defaults: [
            "freezeCursor": true, "haptics": true, "quickMute": true, "showInMenuBar": true,
            "launchAtLogin": false, "hasLaunchedWithMenuBarIcon": false,
            "muteCorner": "topRight", "pauseCorner": "bottomRight",
            "cornerTapFraction": 0.12,
            "longPressLock": false, "lockCorner": "topLeft", "lockHoldDuration": 2.0,
            "tapPause": false, "sensitivity": 1.5, "edgeFraction": 0.05,
            "requireModifier": false, "fineControl": true, "edrBrightnessEnabled": false,
            "volumeEdge": "left", "brightnessEdge": "right"
        ])
        if needsVolumeEdgeMigration {
            defaults.set(defaults.bool(forKey: "swapSides") ? "right" : "left", forKey: "volumeEdge")
        }
        if needsBrightnessEdgeMigration {
            defaults.set(defaults.bool(forKey: "swapSides") ? "left" : "right", forKey: "brightnessEdge")
        }
    }
    static func bool(_ key: String, _ fallback: Bool = false) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
    static func number(_ key: String, _ fallback: Double) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }
}

final class EdgeGestureController {
    private var monitor: Any?
    private var trackpad = TrackpadMonitor()
    private var previous: CGPoint?
    private var lastStep = Date.distantPast
    private var pendingMotion = 0.0
    private var lastTrackpadPoint: CGPoint?
    private var gestureStart: CGPoint?
    private var gestureSlid = false
    private var activeEdgeMode: String?
    private var activeEdgeName: String?
    private var edgeStart: CGPoint?
    private var edgeArmed = false
    private var slideRejectedUntilLift = false
    private var contactBeganAt: Date?
    private var cursorFrozen = false
    private var cursorHidden = false
    private var cursorAnchor: CGPoint?
    private var muteTapCandidate = false
    private var muteTapStartPoint: CGPoint?
    private var muteTapStartTime: Date?
    private var muteCornerHeld = false
    private var fallbackGestureEndWorkItem: DispatchWorkItem?

    private var playbackQueryPending = false
    private var lockHold = CornerHoldGesture()
    private var lockHoldWorkItem: DispatchWorkItem?
    private var lockHoldID = UUID()
    private var lockCommitWorkItem: DispatchWorkItem?

    func start() {
        trackpad.onFrame = { [weak self] in self?.handleTrackpad($0) }
        if trackpad.start() { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            guard let self, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else { return }
            self.handle(NSEvent.mouseLocation, in: screen.frame)
        }
    }

    func stop() {
        resetLockHold()
        trackpad.stop()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        unfreezeCursor()
    }

    private func handleTrackpad(_ contacts: [CGPoint]) {
        guard contacts.count == 1, let point = contacts.first else {
            DisplayBrightness.endGesture()
            let heldForLock = lockHold.suppressesTap(now: ProcessInfo.processInfo.systemUptime)
            resetLockHold()
            let didMute = contacts.isEmpty && !heldForLock ? completeQuickMuteTap() : false
            cancelQuickMuteTap()
            if contacts.isEmpty, let lastTrackpadPoint {
                let reservedForMute = Pref.bool("quickMute", true) &&
                    gestureStart.map { isMuteCorner($0) } == true
                if !heldForLock, !didMute, !reservedForMute, Pref.bool("tapPause"), !gestureSlid,
                   let gestureStart, isPlayPauseCorner(gestureStart), isPlayPauseCorner(lastTrackpadPoint) {
                    media(0)
                }
            }
            lastTrackpadPoint = nil
            gestureStart = nil
            gestureSlid = false
            activeEdgeMode = nil
            edgeStart = nil
            edgeArmed = false
            activeEdgeName = nil
            slideRejectedUntilLift = false
            contactBeganAt = nil
            previous = nil
            pendingMotion = 0
            unfreezeCursor()
            return
        }
        if gestureStart == nil {
            gestureStart = point
            contactBeganAt = Date()
            DisplayBrightness.beginGesture()
            beginLockHold(at: point)
        }
        if let gestureStart, hypot(point.x - gestureStart.x, point.y - gestureStart.y) > 0.012 { gestureSlid = true }
        lastTrackpadPoint = point
        updateQuickMuteTap(at: point)
        updateLockHold(at: point)
        if lockHold.isTracking || lockHold.didFire || muteTapCandidate || muteCornerHeld {
            // Keep a click candidate out of edge gestures so it cannot adjust
            // volume or freeze/hide the pointer while awaiting release.
            previous = point
            pendingMotion = 0
            unfreezeCursor()
            return
        }
        if Pref.bool("requireModifier"), !NSEvent.modifierFlags.contains(.function), !NSEvent.modifierFlags.contains(.control) { previous = nil; unfreezeCursor(); return }
        let edgeWidth = Pref.number("edgeFraction", 0.05)
        let configured = assignedControl(at: point, edgeWidth: edgeWidth)
        let horizontalEdge = point.y <= edgeWidth || point.y >= 1 - edgeWidth
        let edgeName = configured?.edge ?? (point.y <= edgeWidth ? "bottom" : "top")
        let mode = configured?.mode
        guard let mode else {
            previous = nil; pendingMotion = 0; activeEdgeMode = nil; activeEdgeName = nil; edgeStart = nil; edgeArmed = false
            unfreezeCursor(); return
        }
        if mode != "media", edgeName == "left" || edgeName == "right" {
            // Keep the original touchdown as the reference: a palm must not
            // re-arm after drifting into another edge or changing direction.
            if let start = gestureStart {
                let horizontal = edgeName == "top" || edgeName == "bottom"
                let along = abs(horizontal ? point.x - start.x : point.y - start.y)
                let across = abs(horizontal ? point.y - start.y : point.x - start.x)
                let startedOnEdge = assignedControl(at: start, edgeWidth: edgeWidth)?.edge == edgeName
                let startedInCorner = (start.x < 0.08 || start.x > 0.92) && (start.y < 0.08 || start.y > 0.92)
                if !startedOnEdge || startedInCorner || across > 0.012 || (across > 0.006 && across * 3 > along) {
                    slideRejectedUntilLift = true
                }
            }
            if slideRejectedUntilLift {
                previous = nil; pendingMotion = 0
                unfreezeCursor()
                return
            }
        }
        if mode != "media", Pref.bool("freezeCursor") { freezeCursor() }
        if mode != activeEdgeMode || edgeName != activeEdgeName {
            activeEdgeMode = mode
            activeEdgeName = edgeName
            edgeStart = point
            edgeArmed = mode == "media"
            pendingMotion = 0
            previous = point
            if mode != "media" { return }
        }
        if mode != "media", !edgeArmed {
            guard let edgeStart else { previous = point; return }
            let horizontalGesture = edgeName == "top" || edgeName == "bottom"
            let primaryTravel = horizontalGesture ? point.x - edgeStart.x : point.y - edgeStart.y
            let crossTravel = horizontalGesture ? point.y - edgeStart.y : point.x - edgeStart.x
            // Require a deliberate, mostly vertical swipe before arming an
            // edge gesture. Tiny palm shifts while typing should not activate it.
            // Horizontal edges use the original responsive activation rule.
            // Only side edges need the additional palm qualification delay.
            let minimumTravel: CGFloat = horizontalGesture ? 0.022 : 0.03
            let directionRatio: CGFloat = horizontalGesture ? 2.0 : 3.0
            let settled = horizontalGesture || Date().timeIntervalSince(contactBeganAt ?? Date()) >= 0.12
            guard settled,
                  abs(primaryTravel) >= minimumTravel,
                  abs(primaryTravel) >= abs(crossTravel) * directionRatio else {
                if horizontalGesture && abs(crossTravel) > 0.015 { self.edgeStart = point }
                previous = point
                return
            }
            edgeArmed = true
            // Qualification motion never changes the level.
            pendingMotion = horizontalGesture ? primaryTravel : 0
            previous = point
        }
        if mode != "media" {
            if Pref.bool("freezeCursor") { freezeCursor() }
            else { unfreezeCursor() }
        }
        if let previous {
            let dx = point.x - previous.x
            let dy = point.y - previous.y // The trackpad reports the opposite vertical sign from screen coordinates.
            let horizontalGesture = edgeName == "top" || edgeName == "bottom"
            if mode == "media", abs(dx) > 0.018 {
                media(dx < 0 ? -1 : 1); lastStep = Date()
            } else {
                pendingMotion += horizontalGesture ? dx : dy
                let modeSensitivity = 0.25
                var scale = 650 * Pref.number("sensitivity", 1.5) * modeSensitivity
                if Pref.bool("fineControl"), NSEvent.modifierFlags.contains(.option), NSEvent.modifierFlags.contains(.command) { scale /= 4 }
                // Batch movement into one level update so haptics stay in step
                // with a fast swipe instead of trailing one pulse per percent.
                let amount = Int(abs(pendingMotion) * scale)
                if amount > 0, Date().timeIntervalSince(lastStep) > 0.035 {
                    let direction = pendingMotion > 0 ? 1 : -1
                    if mode == "volume" { adjustVolume(direction * amount) }
                    else { adjustBrightness(direction * amount) }
                    pendingMotion -= Double(direction * amount) / scale
                    lastStep = Date()
                    performHaptic()
                }
            }
        }
        if cursorFrozen, let cursorAnchor { CGWarpMouseCursorPosition(cursorAnchor) }
        previous = point
    }

    private func handle(_ point: CGPoint, in frame: CGRect) {
        if previous == nil { DisplayBrightness.beginGesture() }
        fallbackGestureEndWorkItem?.cancel()
        let endGesture = DispatchWorkItem { [weak self] in
            self?.previous = nil
            DisplayBrightness.endGesture()
        }
        fallbackGestureEndWorkItem = endGesture
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: endGesture)
        let normalized = CGPoint(x: (point.x - frame.minX) / frame.width,
                                 y: (point.y - frame.minY) / frame.height)
        let edgeWidth = Pref.number("edgeFraction", 0.05)
        let configured = assignedControl(at: normalized, edgeWidth: edgeWidth)
        let horizontalEdge = normalized.y <= edgeWidth || normalized.y >= 1 - edgeWidth
        let edgeName = configured?.edge ?? (normalized.y <= edgeWidth ? "bottom" : "top")
        let mode = configured?.mode
        guard let mode else { previous = nil; return }
        if let previous {
            let dy = point.y - previous.y
            let dx = point.x - previous.x
            if mode == "media" {
                if abs(dx) >= 24 { media(dx > 0 ? -1 : 1); lastStep = Date() }
            } else if abs(edgeName == "top" || edgeName == "bottom" ? dx : dy) >= 3 {
                let travel = edgeName == "top" || edgeName == "bottom" ? dx : dy
                let delta = (travel > 0 ? 1 : -1)
                if mode == "volume" { adjustVolume(delta) } else { adjustBrightness(delta) }
                lastStep = Date()
                performHaptic()
            }
        }
        previous = point
    }

    private func resetLockHold() {
        EdgeHUD.shared.hideLockCountdown(id: lockHoldID)
        lockCommitWorkItem?.cancel()
        lockCommitWorkItem = nil
        lockHoldWorkItem?.cancel()
        lockHoldWorkItem = nil
        lockHoldID = UUID()
        lockHold = CornerHoldGesture()
    }

    private func beginLockHold(at point: CGPoint) {
        resetLockHold()
        guard Pref.bool("longPressLock"), ScreenLock.isAvailable else { return }
        lockHold.begin(at: point, now: ProcessInfo.processInfo.systemUptime,
                       corner: Pref.defaults.string(forKey: "lockCorner") ?? "topLeft",
                       fraction: Pref.number("cornerTapFraction", 0.12),
                       duration: Pref.number("lockHoldDuration", 2))
        guard lockHold.isTracking else { return }
        scheduleLockCountdownTick()
    }

    private func scheduleLockCountdownTick() {
        lockHoldWorkItem?.cancel()
        guard lockHold.isTracking else { return }
        let id = lockHoldID
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.lockHoldID == id, let point = self.lastTrackpadPoint else { return }
            self.updateLockHold(at: point)
            if self.lockHoldID == id, self.lockHold.isTracking { self.scheduleLockCountdownTick() }
        }
        lockHoldWorkItem = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: task)
    }

    private func updateLockHold(at point: CGPoint) {
        guard Pref.bool("longPressLock") else {
            lockHold.cancel()
            lockHoldWorkItem?.cancel()
            lockCommitWorkItem?.cancel()
            EdgeHUD.shared.hideLockCountdown(id: lockHoldID)
            return
        }
        if lockHold.update(at: point, now: ProcessInfo.processInfo.systemUptime) {
            lockHoldWorkItem?.cancel()
            cancelQuickMuteTap()
            unfreezeCursor()
            performHaptic()
            EdgeHUD.shared.showLockCountdown(tenths: 0, id: lockHoldID)
            // Allow the final 0 to render before macOS covers the screen.
            // Lift, cancellation, or stop invalidates this pending request.
            let id = lockHoldID
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.lockHoldID == id, self.lockHold.didFire,
                      Pref.bool("longPressLock") else { return }
                ScreenLock.requestLock()
                EdgeHUD.shared.hideLockCountdown(id: id)
            }
            lockCommitWorkItem = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: task)
        } else if !lockHold.isTracking {
            lockHoldWorkItem?.cancel()
            if !lockHold.didFire {
                lockCommitWorkItem?.cancel()
                EdgeHUD.shared.hideLockCountdown(id: lockHoldID)
            }
        } else if let tenths = lockHold.countdownTenths(now: ProcessInfo.processInfo.systemUptime) {
            EdgeHUD.shared.showLockCountdown(tenths: tenths, id: lockHoldID)
        }
    }

    private func assignedControl(at point: CGPoint, edgeWidth: Double) -> (mode: String, edge: String)? {
        let edgeName: String?
        if point.x <= edgeWidth { edgeName = "left" }
        else if point.x >= 1 - edgeWidth { edgeName = "right" }
        else if point.y <= edgeWidth { edgeName = "bottom" }
        else if point.y >= 1 - edgeWidth { edgeName = "top" }
        else { edgeName = nil }
        guard let edgeName else { return nil }
        if edgeName == Pref.defaults.string(forKey: "volumeEdge") { return ("volume", edgeName) }
        if edgeName == Pref.defaults.string(forKey: "brightnessEdge") { return ("brightness", edgeName) }
        return nil
    }

    private func isMuteCorner(_ point: CGPoint) -> Bool {
        isInCorner(point, name: Pref.defaults.string(forKey: "muteCorner") ?? "topRight")
    }

    private func updateQuickMuteTap(at point: CGPoint) {
        guard Pref.bool("quickMute", true), let gestureStart,
              isMuteCorner(gestureStart), isMuteCorner(point) else {
            cancelQuickMuteTap()
            return
        }
        if muteTapCandidate, let start = muteTapStartPoint {
            guard hypot(point.x - start.x, point.y - start.y) <= 0.012 else {
                cancelQuickMuteTap()
                return
            }
            if let startTime = muteTapStartTime,
               Date().timeIntervalSince(startTime) >= 0.25 {
                muteTapCandidate = false
                muteCornerHeld = true
            }
            return
        }
        guard !muteCornerHeld else { return }
        muteTapCandidate = true
        muteTapStartPoint = point
        muteTapStartTime = Date()
    }

    private func isPlayPauseCorner(_ point: CGPoint) -> Bool {
        isInCorner(point, name: Pref.defaults.string(forKey: "pauseCorner") ?? "bottomRight")
    }

    private func isInCorner(_ point: CGPoint, name: String) -> Bool {
        CornerTapZone.contains(point, corner: name, fraction: Pref.number("cornerTapFraction", 0.12))
    }

    private func completeQuickMuteTap() -> Bool {
        guard muteTapCandidate,
              !gestureSlid,
              let start = muteTapStartPoint,
              let startTime = muteTapStartTime,
              Date().timeIntervalSince(startTime) < 0.25,
              let lastPoint = lastTrackpadPoint,
              isMuteCorner(lastPoint),
              hypot(lastPoint.x - start.x, lastPoint.y - start.y) <= 0.012 else { return false }
        toggleMute()
        return true
    }

    private func cancelQuickMuteTap() {
        muteTapCandidate = false
        muteTapStartPoint = nil
        muteTapStartTime = nil
        muteCornerHeld = false
    }

    private func adjustVolume(_ delta: Int) {
        _ = AudioVolumeController.change(by: delta)
    }

    private func adjustBrightness(_ delta: Int) {
        if let percent = DisplayBrightness.setStep(delta) {
            let maximum = DisplayBrightness.maximumPercent
            EdgeHUD.shared.show(title: percent > 100 ? "EDR Headroom" : "Brightness",
                                leftSymbol: "sun.min.fill",
                                rightSymbol: "sun.max.fill",
                                level: Float(percent) / Float(maximum),
                                maximum: maximum)
        }
    }

    private func performHaptic() {
        guard Pref.bool("haptics", true) else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    private func media(_ direction: Int) {
        guard direction == 0 else {
            sendMediaKey(direction)
            return
        }
        guard !playbackQueryPending else { return }
        playbackQueryPending = true
        querySystemPlaybackState { [weak self] isPlaying in
            guard let self else { return }
            self.playbackQueryPending = false
            self.sendMediaKey(0)
            EdgeHUD.shared.showPlaybackStatus(willPause: isPlaying)
        }
    }

    private func sendMediaKey(_ direction: Int) {
        // NX_KEYTYPE_PREVIOUS=18, NX_KEYTYPE_NEXT=17, system-defined event subtype 8.
        let keyCode = direction == 0 ? 16 : (direction < 0 ? 18 : 17)
        for state in [0xA, 0xB] {
            let data = (keyCode << 16) | (state << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 8, data1: data, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MPNowPlayingInfoCenter describes this app, not the system's active player.
    // Query MediaRemote through the system script host, which can read the
    // active session on recent macOS versions. No app-specific Automation needed.
    private func querySystemPlaybackState(completion: @escaping (Bool?) -> Void) {
        let script = """
        function run() {
            const framework = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework');
            if (!framework.load) return 'unknown';
            const request = $.NSClassFromString('MRNowPlayingRequest');
            const client = request.localNowPlayingPlayerPath.client;
            if (!client || !client.bundleIdentifier.js) return 'unknown';
            return request.localIsPlaying ? 'playing' : 'paused';
        }
        """
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var finished = false
        let finish: (Bool?) -> Void = { state in
            guard !finished else { return }
            finished = true
            completion(state)
        }
        process.terminationHandler = { process in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let state: Bool? = process.terminationStatus == 0
                ? (value == "playing" ? true : value == "paused" ? false : nil) : nil
            DispatchQueue.main.async { finish(state) }
        }
        do { try process.run() }
        catch { finish(nil); return }
        // Keep gestures responsive if the private API stops responding.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard !finished else { return }
            if process.isRunning { process.terminate() }
            finish(nil)
        }
    }

    private func toggleMute() {
        _ = AudioVolumeController.toggleMute()
    }

    private func freezeCursor() {
        guard !cursorFrozen else { return }
        cursorAnchor = CGEvent(source: nil)?.location
        CGAssociateMouseAndMouseCursorPosition(0)
        if !cursorHidden { NSCursor.hide(); cursorHidden = true }
        cursorFrozen = true
    }

    private func unfreezeCursor() {
        if cursorFrozen {
            CGAssociateMouseAndMouseCursorPosition(1)
            if let cursorAnchor { CGWarpMouseCursorPosition(cursorAnchor) }
            cursorAnchor = nil
            cursorFrozen = false
        }
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
    }
}

@discardableResult private func shell(_ command: String, _ args: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/\(command)")
    process.arguments = args
    let output = Pipe(); process.standardOutput = output
    try process.run(); process.waitUntilExit()
    return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

struct Dashboard: View {
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("volumeEdge") private var volumeEdge = "left"
    @AppStorage("brightnessEdge") private var brightnessEdge = "right"
    @AppStorage("requireModifier") private var requireModifier = false
    @AppStorage("freezeCursor") private var freezeCursor = true
    @AppStorage("fineControl") private var fineControl = true
    @AppStorage("haptics") private var haptics = true
    @AppStorage("quickMute") private var quickMute = true
    @AppStorage("tapPause") private var tapPause = false
    @AppStorage("muteCorner") private var muteCorner = "topRight"
    @AppStorage("pauseCorner") private var pauseCorner = "bottomRight"
    @AppStorage("cornerTapFraction") private var cornerTapFraction = 0.12
    @AppStorage("longPressLock") private var longPressLock = false
    @AppStorage("lockCorner") private var lockCorner = "topLeft"
    @AppStorage("lockHoldDuration") private var lockHoldDuration = 2.0
    @AppStorage("sensitivity") private var sensitivity = 1.5
    @AppStorage("edgeFraction") private var edgeFraction = 0.05
    @AppStorage("edrBrightnessEnabled") private var edrBrightnessEnabled = false
    @AppStorage("showPausePermissionHelp") private var showPausePermissionHelp = false

    var body: some View {
        ScrollView(.vertical) {
        VStack(spacing: 12) {
            HStack { Image(systemName: "slider.horizontal.3").foregroundStyle(.orange); Text("EdgeControl").font(.headline); Text("v\(AppVersion.current)").font(.caption2).foregroundStyle(.secondary); Spacer(); Label("Ready", systemImage: "circle.fill").font(.caption).foregroundStyle(.green) }
            TimelineView(.periodic(from: .now, by: 0.35)) { _ in
                VStack(spacing: 7) {
                    HStack(spacing: 0) {
                        Meter(title: brightnessPercent.map { $0 > 100 ? "EDR BRIGHTNESS" : "BRIGHTNESS" } ?? "BRIGHTNESS", symbol: "sun.max.fill", value: brightnessPercent.map { "\($0)%" } ?? "—", tint: .orange)
                        Divider().frame(height: 58)
                        Meter(title: "VOLUME", symbol: "speaker.wave.2.fill", value: "\(volumePercent)%", tint: .blue)
                    }
                    Text(edrSummary)
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
            }
            ToggleRow(symbol: "sun.max.trianglebadge.exclamationmark", title: "EDR Headroom", subtitle: "Enable extra brightness for SDR content", subtitleColor: .yellow) {
                Toggle("EDR Headroom", isOn: $edrBrightnessEnabled)
                    .labelsHidden()
                    .disabled(!DisplayBrightness.supportsEDR)
                    .onChange(of: edrBrightnessEnabled) { enabled in
                        DisplayBrightness.setEDREnabled(enabled)
                    }
            }
            ToggleRow(symbol: "hand.tap.fill", title: "Haptic Feedback", subtitle: "One click per adjustment") {
                Toggle("Haptic Feedback", isOn: $haptics).labelsHidden()
            }
            ToggleRow(symbol: "speaker.slash.fill", title: "Quick Mute", subtitle: "Tap the selected corner") { Toggle("Quick Mute", isOn: $quickMute).labelsHidden() }
            Picker("Mute corner", selection: $muteCorner) { cornerOptions }
                .labelsHidden()
                .disabled(!quickMute)
            ToggleRow(symbol: "playpause.fill", title: "Tap to Play or Pause", subtitle: "Tap the selected corner") {
                Toggle("Tap to Play or Pause", isOn: $tapPause).labelsHidden()
                    .onChange(of: tapPause) { enabled in
                        guard enabled, !AXIsProcessTrusted() else { return }
                        tapPause = false
                        showPausePermissionHelp = true
                    }
            }
            Picker("Play/Pause corner", selection: $pauseCorner) { cornerOptions }
                .labelsHidden()
                .disabled(!tapPause)
            ToggleRow(symbol: "lock.fill", title: "Hold to Lock", subtitle: "Hold a finger still in the selected corner") {
                Toggle("Hold to Lock", isOn: $longPressLock).labelsHidden()
                    .disabled(!ScreenLock.isAvailable)
            }
            Picker("Lock corner", selection: $lockCorner) { cornerOptions }
                .labelsHidden()
                .disabled(!longPressLock)
            VStack(alignment: .leading, spacing: 6) {
                SliderRow(title: "Lock Hold Duration", value: $lockHoldDuration, range: 0.5...3,
                          display: String(format: "%.1f s", lockHoldDuration))
                Text("Keep holding through the countdown to lock. Lift or move away to cancel. Short taps keep their usual action.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!longPressLock)
            if !ScreenLock.isAvailable {
                Text("Screen locking is unavailable on this macOS version.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                SliderRow(title: "Corner Tap Size", value: $cornerTapFraction, range: 0.04...0.20,
                          display: "\(Int((cornerTapFraction * 100).rounded()))%")
                Text("Width and height of all corner gesture areas. Larger areas are easier to tap.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if quickMute && tapPause && muteCorner == pauseCorner {
                    Text("Quick Mute takes priority when both actions use the same corner.")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!quickMute && !tapPause && !longPressLock)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "rectangle.dashed").foregroundStyle(.purple)
                    Text("Slide Zones").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("TRACKPAD EDGE").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                }
                EdgeAssignmentPicker(title: "Volume", symbol: "speaker.wave.2.fill", selected: volumeEdge, reserved: brightnessEdge) { volumeEdge = $0 }
                EdgeAssignmentPicker(title: "Brightness", symbol: "sun.max.fill", selected: brightnessEdge, reserved: volumeEdge) { brightnessEdge = $0 }
                Text("Swipe up/down on the sides, or left/right on the top and bottom edges.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
            VStack(spacing: 10) {
                SliderRow(title: "Sensitivity", value: $sensitivity, range: 0.5...3.0, display: String(format: "%.1fx", sensitivity))
                SliderRow(title: "Edge Width", value: $edgeFraction, range: 0.02...0.18, display: "\(Int(edgeFraction * 100))%")
            }.padding(.top, 2)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                    Text("Gesture Options").font(.system(size: 13, weight: .semibold))
                }
                ToggleRow(symbol: "cursorarrow.motionlines", title: "Freeze Cursor", subtitle: "Keep pointer still during edge slides") {
                    Toggle("Freeze Cursor", isOn: $freezeCursor).labelsHidden()
                }
                ToggleRow(symbol: "command", title: "Require Fn / Control", subtitle: "Hold either key while sliding") {
                    Toggle("Require Fn / Control", isOn: $requireModifier).labelsHidden()
                }
                ToggleRow(symbol: "scope", title: "Fine Control", subtitle: "Hold ⌘⌥ while sliding for finer steps") {
                    Toggle("Fine Control", isOn: $fineControl).labelsHidden()
                }
            }
            Divider()
            ToggleRow(symbol: "menubar.rectangle", title: "In menubar", subtitle: "Show EdgeControl in the menu bar") {
                Toggle("In menubar", isOn: $showInMenuBar).labelsHidden()
                    .onChange(of: showInMenuBar) { AppDelegate.shared?.setMenuBarVisible($0) }
            }
            ToggleRow(symbol: "power", title: "Start at login", subtitle: "Open EdgeControl when you log in") {
                Toggle("Start at login", isOn: $launchAtLogin).labelsHidden()
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
            Divider()
            HStack {
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Quit EdgeControl")
            }
        }.padding(16).frame(width: 340)
        }
        .frame(width: 340, height: 700)
        .onAppear(perform: validatePlaybackPermission)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            validatePlaybackPermission()
        }
        .sheet(isPresented: $showPausePermissionHelp) {
            PausePermissionHelp(
                checkAccess: {
                    if AXIsProcessTrusted() { showPausePermissionHelp = false }
                },
                dismiss: { showPausePermissionHelp = false }
            )
        }
    }

    private var brightnessPercent: Int? { DisplayBrightness.currentPercent }
    private func validatePlaybackPermission() {
        if AXIsProcessTrusted() {
            showPausePermissionHelp = false
            return
        }
        guard tapPause else { return }
        tapPause = false
        showPausePermissionHelp = true
    }

    private var cornerOptions: some View {
        Group {
            Text("Top left").tag("topLeft")
            Text("Top right").tag("topRight")
            Text("Bottom left").tag("bottomLeft")
            Text("Bottom right").tag("bottomRight")
        }
    }
    private var volumePercent: Int { AudioVolumeController.readPercent() }
    private var edrSummary: String {
        guard DisplayBrightness.supportsEDR else { return "HDR brightness boost unavailable on this display" }
        if let brightnessPercent, brightnessPercent > 100 {
            return "EDR active · \(brightnessPercent)% brightness (up to \(DisplayBrightness.maximumPercent)%)"
        }
        return edrBrightnessEnabled
            ? "SDR brightness with HDR headroom up to \(DisplayBrightness.maximumPercent)%"
            : "Enable EDR Headroom to go beyond 100% brightness"
    }
}

private struct PausePermissionHelp: View {
    let checkAccess: () -> Void
    let dismiss: () -> Void
    private var runningAppName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.bundleURL.lastPathComponent
    }
    private var installFolderName: String { Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow EdgeControl in Accessibility").font(.title3.bold())
            Text("EdgeControl isn’t signed, so macOS may not add it to the list automatically. In System Settings, open Privacy & Security → Accessibility, click +, and select \(runningAppName) from \(installFolderName).")
                .font(.callout).foregroundStyle(.secondary)
            Text("After you turn on \(runningAppName) in the list, choose Check Again.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("System Settings").font(.headline)
                Label("Privacy & Security", systemImage: "hand.raised.fill").foregroundStyle(.secondary)
                Label("Accessibility", systemImage: "accessibility")
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                HStack { Image(systemName: "plus.circle.fill").foregroundStyle(.secondary); Text("Add \(runningAppName)"); Spacer(); Image(systemName: "togglepower").foregroundStyle(.green) }
                    .padding(8).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                Text("\(installFolderName)  ›  \(runningAppName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Button("Open Accessibility Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Check Again", action: checkAccess)
                Spacer()
                Button("Got it", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 430)
    }
}

private struct EdgeAssignmentPicker: View {
    private struct EdgeChoice: Identifiable {
        let id: String
        let symbol: String
        let title: String
    }

    let title: String
    let symbol: String
    let selected: String
    let reserved: String
    let choose: (String) -> Void
    private let edges = [
        EdgeChoice(id: "left", symbol: "arrow.left", title: "Left"),
        EdgeChoice(id: "right", symbol: "arrow.right", title: "Right"),
        EdgeChoice(id: "top", symbol: "arrow.up", title: "Top"),
        EdgeChoice(id: "bottom", symbol: "arrow.down", title: "Bottom")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                ForEach(edges) { edge in
                    let isSelected = selected == edge.id
                    let isReserved = reserved == edge.id
                    Button { choose(edge.id) } label: {
                        VStack(spacing: 3) {
                            Image(systemName: edge.symbol).font(.system(size: 12, weight: .semibold))
                            Text(edge.title).font(.system(size: 9, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(isReserved ? 0.28 : 0.72))
                        .background(isSelected ? Color.purple : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(isReserved)
                    .help(isReserved ? "Already assigned to the other control" : "Use the \(edge.title.lowercased()) edge")
                }
            }
        }
    }
}

struct Meter: View {
    let title: String; let symbol: String; let value: String; let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .light, design: .rounded))
        }.frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 3).fill(tint).frame(width: 3).padding(.leading, -11) }
    }
}

struct ToggleRow<Control: View>: View {
    let symbol: String; let title: String; let subtitle: String; var subtitleColor: Color = .secondary; @ViewBuilder let control: Control
    var body: some View { HStack(spacing: 10) {
        Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).frame(width: 30, height: 30).background(.purple, in: Circle())
        VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 13, weight: .semibold)); Text(subtitle).font(.system(size: 10)).foregroundStyle(subtitleColor) }
        Spacer(minLength: 4); control
    } }
}

struct SliderRow: View {
    let title: String; @Binding var value: Double; let range: ClosedRange<Double>; let display: String
    var body: some View { VStack(spacing: 3) { HStack { Image(systemName: title == "Sensitivity" ? "scope" : "arrow.left.and.right").foregroundStyle(.secondary); Text(title).font(.caption.weight(.medium)); Spacer(); Text(display).font(.caption).foregroundStyle(.secondary) }; Slider(value: $value, in: range).tint(.purple) } }
}
