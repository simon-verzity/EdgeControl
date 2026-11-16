import AppKit
import SwiftUI

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class EdgeHUDModel: ObservableObject {
    @Published var title = "Display"
    @Published var leftSymbol = "sun.min.fill"
    @Published var rightSymbol = "sun.max.fill"
    @Published var value: CGFloat = 0
    @Published var percentage = 0
    @Published var percentageText = "0%"
    @Published var accent: Color = .yellow
    @Published var hint = ""
    @Published var isCompactStatus = false
    @Published var statusTitle = "Muted"
    @Published var statusSubtitle = "Volume is off"
    @Published var statusSymbol = "speaker.slash.fill"
    @Published var statusTint: Color = .orange
}

final class EdgeHUD {
    static let shared = EdgeHUD()
    private let model = EdgeHUDModel()
    private var panel: HUDPanel?
    private var hideTask: DispatchWorkItem?
    private var presentationID = 0
    private var lockCountdownID: UUID?

    func show(title: String, leftSymbol: String, rightSymbol: String, level: Float, maximum: Int = 100, hint: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lockCountdownID = nil
            self.model.title = title
            self.model.hint = hint ?? ""
            self.model.leftSymbol = leftSymbol
            self.model.rightSymbol = rightSymbol
            let normalizedLevel = min(1, max(0, CGFloat(level)))
            self.model.value = normalizedLevel
            self.model.percentage = Int((normalizedLevel * CGFloat(max(1, maximum))).rounded())
            self.model.percentageText = "\(self.model.percentage)%"
            self.model.accent = title == "Volume" ? .green : .yellow
            self.model.isCompactStatus = false
            self.present()
        }
    }

    func showMuteStatus(muted: Bool, volumePercent: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lockCountdownID = nil
            let percent = min(100, max(0, volumePercent))
            self.model.title = muted ? "Mute" : "Unmute"
            self.model.leftSymbol = muted ? "speaker.slash.fill" : "speaker.fill"
            self.model.rightSymbol = muted ? "speaker.slash.fill" : "speaker.wave.3.fill"
            self.model.value = muted ? 0 : CGFloat(percent) / 100
            self.model.percentage = percent
            self.model.percentageText = muted ? "Muted" : "\(percent)%"
            self.model.accent = muted ? .orange : .green
            self.model.hint = ""
            self.model.isCompactStatus = false
            self.present()
        }
    }

    func showPlaybackStatus(willPause: Bool?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lockCountdownID = nil
            self.model.isCompactStatus = true
            self.model.statusSubtitle = ""
            if let willPause {
                self.model.statusTitle = willPause ? "Pause" : "Play"
                self.model.statusSymbol = willPause ? "pause.fill" : "play.fill"
                self.model.statusTint = willPause ? .orange : .green
            } else {
                self.model.statusTitle = "Play/Pause"
                self.model.statusSymbol = "playpause.fill"
                self.model.statusTint = .blue
            }
            self.present()
        }
    }

    func showPlaybackFailure(title: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lockCountdownID = nil
            self.model.isCompactStatus = true
            self.model.statusTitle = title
            self.model.statusSubtitle = ""
            self.model.statusSymbol = "exclamationmark.triangle.fill"
            self.model.statusTint = .orange
            self.present()
        }
    }

    func showLockCountdown(tenths: Int, id: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let value = max(0, tenths)
            let title = "Locking in \(value / 10).\(value % 10)s"
            guard self.lockCountdownID != id || self.model.statusTitle != title else { return }
            self.lockCountdownID = id
            self.model.isCompactStatus = true
            self.model.statusTitle = title
            self.model.statusSubtitle = ""
            self.model.statusSymbol = "lock.fill"
            self.model.statusTint = .orange
            self.present(autoHide: false)
        }
    }

    func hideLockCountdown(id: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lockCountdownID == id else { return }
            self.lockCountdownID = nil
            self.hideTask?.cancel()
            self.presentationID += 1
            self.panel?.orderOut(nil)
        }
    }

    private func present(autoHide: Bool = true) {
        if panel == nil {
            let size = NSSize(width: 420, height: 96)
            let window = HUDPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .statusBar
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.contentView = NSHostingView(rootView: EdgeHUDView(model: model))
            panel = window
        }
        guard let panel else { return }
        let isCompactStatus = model.isCompactStatus
        presentationID += 1
        let currentPresentationID = presentationID
        let size = isCompactStatus ? NSSize(width: 280, height: 100)
            : NSSize(width: 420, height: model.hint.isEmpty ? 112 : 140)
        panel.setContentSize(size)
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            let origin = NSPoint(x: frame.midX - panel.frame.width / 2,
                                 y: frame.midY - panel.frame.height / 2)
            panel.setFrameOrigin(origin)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTask?.cancel()
        guard autoHide else { hideTask = nil; return }
        let task = DispatchWorkItem { [weak self, weak panel] in
            guard let self, self.presentationID == currentPresentationID else { return }
            panel?.orderOut(nil)
        }
        hideTask = task
        let duration = isCompactStatus ? 1.0 : (model.hint.isEmpty ? 1.4 : 2.4)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }
}

private final class TrackpadDebugModel: ObservableObject {
    @Published var backend = "Waiting for input"
    @Published var received = 0
    @Published var passed = 0
    @Published var fps = 0
    @Published var lagMS = 0
    @Published var contact = "No frames yet"
    @Published var gesture = "Idle"
    @Published var age = "—"
    @Published var coordinates = "X: —  Y: — (no active contact)"
    @Published var startCoordinates = "Start: —"
    @Published var contactSize = "Contact axes / area: —"
    @Published var lastRejection = "Last rejection: —"
    @Published var rejections: [TrackpadRejection] = []
}

final class TrackpadDebugOverlay {
    static let shared = TrackpadDebugOverlay()
    fileprivate static let frameName = "EdgeControl.TrackpadDebug"
    private let model = TrackpadDebugModel()
    private var panel: HUDPanel?
    private var timer: Timer?
    private var enabled = false
    private var latestFrame: TrackpadDebugFrame?
    private var latestLagMS = 0
    private var gestureStatus = "Idle"
    private var previousCount: Int?
    private var previousTick: TimeInterval = 0
    private var history = TrackpadRejectionHistory()
    private var historyWindow: NSWindow?

    func setBackend(_ value: String) { model.backend = value }
    func setGestureStatus(_ value: String) {
        if enabled {
            gestureStatus = value
        }
    }

    func record(_ frame: TrackpadDebugFrame) {
        guard enabled else { return }
        latestFrame = frame
        latestLagMS = Int(max(0, ProcessInfo.processInfo.systemUptime - frame.capturedAt) * 1000)
        if let point = frame.point {
            model.coordinates = String(format: "X: %.3f  Y: %.3f (0–1)", Double(point.x), Double(point.y))
        } else {
            model.coordinates = "X: —  Y: — (no active contact)"
        }
        if let point = frame.startPoint {
            model.startCoordinates = String(format: "Touch start X: %.3f  Y: %.3f", Double(point.x), Double(point.y))
        }
        if let major = frame.major, let minor = frame.minor {
            model.contactSize = String(format: "Axes: %.1f × %.1f  Area: %.1f", Double(major), Double(minor), Double(major) * Double(minor))
        } else { model.contactSize = "Contact axes / area: —" }
        if frame.state.hasPrefix("Rejected:") {
            recordRejection(reason: frame.state, source: "Contact", touchID: frame.touchID,
                            start: frame.startPoint, current: frame.point,
                            timestamp: Date(timeIntervalSinceNow: -max(0, ProcessInfo.processInfo.systemUptime - frame.capturedAt)),
                            major: frame.major, minor: frame.minor)
        }
    }

    func recordRejection(reason: String, source: String, touchID: UUID, start: CGPoint?, current: CGPoint?,
                         edgeWidth: Double? = nil, timestamp: Date = Date(), major: Float? = nil, minor: Float? = nil) {
        guard enabled else { return }
        let entry = TrackpadRejection(touchID: touchID, timestamp: timestamp, source: source, reason: reason,
                                      start: start, current: current, edgeWidth: edgeWidth, major: major, minor: minor)
        guard history.append(entry) else { return }
        model.rejections = history.entries
        model.lastRejection = entry.summary
    }

    func showRejectionHistory() {
        if historyWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "EdgeControl — Last 25 Rejections"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TrackpadRejectionHistoryView(model: model, clear: { [weak self] in
                self?.history.clear()
                self?.model.rejections = []
                self?.model.lastRejection = "Last rejection: —"
            }))
            window.center()
            historyWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        timer?.invalidate()
        timer = nil
        guard value else {
            panel?.saveFrame(usingName: Self.frameName)
            panel?.orderOut(nil)
            return
        }
        latestFrame = nil
        previousCount = nil
        previousTick = ProcessInfo.processInfo.systemUptime
        model.received = 0
        model.passed = 0
        model.fps = 0
        latestLagMS = 0
        model.lagMS = 0
        gestureStatus = "Waiting for touch"
        model.gesture = gestureStatus
        model.age = "—"
        model.contact = "Waiting for frames"
        model.coordinates = "X: —  Y: — (no active contact)"
        model.startCoordinates = "Start: —"
        model.contactSize = "Contact axes / area: —"
        model.lastRejection = history.entries.first?.summary ?? "Last rejection: —"
        if panel == nil {
            let window = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .statusBar
            window.ignoresMouseEvents = false
            window.isMovableByWindowBackground = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.contentView = DraggableDebugHostingView(rootView: TrackpadDebugView(model: model))
            if let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: frame.minX + 12, y: frame.maxY - 492))
            }
            window.setFrameAutosaveName(Self.frameName)
            _ = window.setFrameUsingName(Self.frameName)
            window.setContentSize(NSSize(width: 520, height: 480))
            panel = window
        }
        // Recover if the saved position belonged to a disconnected display.
        let visible = panel.map { window in
            NSScreen.screens.contains { screen in
                let overlap = screen.visibleFrame.intersection(window.frame)
                return overlap.width >= 100 && overlap.height >= 40
            }
        } ?? false
        if !visible, let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel?.setFrameOrigin(NSPoint(x: frame.minX + 12, y: frame.maxY - 492))
        }
        panel?.orderFrontRegardless()
        let tick = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        timer = tick
        RunLoop.main.add(tick, forMode: .common)
    }

    private func refresh() {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let frame = latestFrame {
            let elapsed = max(0.001, now - previousTick)
            model.fps = previousCount.map { Int(Double(max(0, frame.received - $0)) / elapsed) } ?? 0
            previousCount = frame.received
            model.received = frame.received
            model.passed = frame.passed
            model.lagMS = latestLagMS
            model.contact = "\(frame.contacts) contacts · \(frame.state)"
            model.age = String(format: "%.1fs", max(0, now - frame.capturedAt))
        }
        model.gesture = gestureStatus
        previousTick = now
    }
}

private struct TrackpadRejectionHistoryView: View {
    @ObservedObject var model: TrackpadDebugModel
    let clear: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Last 25 Rejections").font(.headline)
                Spacer()
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.rejections.map(\.report).joined(separator: "\n\n"), forType: .string)
                }.disabled(model.rejections.isEmpty)
                Button("Clear", action: clear).disabled(model.rejections.isEmpty)
            }
            Text("Newest first · local time · current app session. Enable Trackpad Debug to record. Repeated frames from the same rejected touch are grouped.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.rejections.isEmpty { Text("No rejections recorded yet.").foregroundStyle(.secondary) }
                    ForEach(model.rejections) { entry in
                        Text(entry.report).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(16).frame(minWidth: 640, minHeight: 320)
    }
}

private final class DraggableDebugHostingView: NSHostingView<TrackpadDebugView> {
    override var mouseDownCanMoveWindow: Bool { false }

    private func isDragHeader(_ point: NSPoint) -> Bool {
        isFlipped ? point.y <= bounds.minY + 36 : point.y >= bounds.maxY - 36
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return isDragHeader(convert(point, from: superview)) ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        guard isDragHeader(convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        guard let window else { return }
        NSCursor.closedHand.set()
        window.performDrag(with: event)
        window.saveFrame(usingName: TrackpadDebugOverlay.frameName)
        NSCursor.openHand.set()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(NSRect(x: bounds.minX, y: isFlipped ? bounds.minY : bounds.maxY - 36,
                             width: bounds.width, height: 36), cursor: .openHand)
    }
}

private struct TrackpadDebugView: View {
    @ObservedObject var model: TrackpadDebugModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EdgeControl · Trackpad Debug").fontWeight(.semibold)
            Text(model.backend).foregroundStyle(.secondary)
            Text("Raw: \(model.received)   Passed: \(model.passed)")
            Text("\(model.fps) frames/s · Main queue: \(model.lagMS) ms")
            Text("Last frame: \(model.age) ago")
            Text(model.contact)
            Text(model.coordinates)
            Text(model.startCoordinates)
            Text(model.contactSize)
            Text("Gesture: \(model.gesture)")
            Text(model.lastRejection).foregroundStyle(.orange).lineLimit(2)
            Divider()
            HStack {
                Text("Last 25 Rejections (\(model.rejections.count))").fontWeight(.semibold)
                Spacer()
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.rejections.map(\.report).joined(separator: "\n\n"), forType: .string)
                }.disabled(model.rejections.isEmpty)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.rejections.isEmpty { Text("No rejections yet.").foregroundStyle(.secondary) }
                    ForEach(model.rejections) { entry in
                        Text(entry.report).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
        .padding(12)
        .frame(width: 520, height: 480, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EdgeHUDView: View {
    @ObservedObject var model: EdgeHUDModel

    var body: some View {
        Group {
            if model.isCompactStatus {
                HStack(spacing: 14) {
                    Image(systemName: model.statusSymbol)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(model.statusTint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.statusTitle)
                            .font(.system(size: 22, weight: .semibold))
                            .monospacedDigit()
                        if !model.statusSubtitle.isEmpty {
                            Text(model.statusSubtitle)
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 24).frame(width: 280, height: 100, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(model.title).font(.system(size: 18, weight: .semibold))
                        Spacer()
                        Text(model.percentageText)
                            .font(.system(size: 24, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(model.accent)
                    }
                    HStack(spacing: 12) {
                        Image(systemName: model.leftSymbol).font(.system(size: 16))
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.14))
                                Capsule().fill(model.accent).frame(width: geometry.size.width * model.value)
                            }
                        }.frame(height: 5)
                        Image(systemName: model.rightSymbol).font(.system(size: 18))
                    }.foregroundStyle(model.accent)
                    if !model.hint.isEmpty {
                        Text(model.hint)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 17)
                .frame(width: 420, height: model.hint.isEmpty ? 112 : 140, alignment: .leading)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(model.isCompactStatus ? Color.white.opacity(0.22) : model.accent.opacity(0.45), lineWidth: 1))
    }
}
