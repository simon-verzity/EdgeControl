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
    @Published var accent: Color = .yellow
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

    func show(title: String, leftSymbol: String, rightSymbol: String, level: Float, maximum: Int = 100) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lockCountdownID = nil
            self.model.title = title
            self.model.leftSymbol = leftSymbol
            self.model.rightSymbol = rightSymbol
            let normalizedLevel = min(1, max(0, CGFloat(level)))
            self.model.value = normalizedLevel
            self.model.percentage = Int((normalizedLevel * CGFloat(max(1, maximum))).rounded())
            self.model.accent = title == "Volume" ? .green : .yellow
            self.model.isCompactStatus = false
            self.present()
        }
    }

    func showMuteStatus(muted: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lockCountdownID = nil
            self.model.isCompactStatus = true
            self.model.statusTitle = muted ? "Mute" : "Unmute"
            self.model.statusSubtitle = muted ? "Volume is now muted" : "Volume is now unmuted"
            self.model.statusSymbol = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            self.model.statusTint = muted ? .orange : .green
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

    func showLockCountdown(seconds: Int, id: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let title = "Locking in \(max(0, seconds))s"
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
        let size = isCompactStatus ? NSSize(width: 280, height: 100) : NSSize(width: 420, height: 112)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + (isCompactStatus ? 1.0 : 1.4), execute: task)
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
                        Text("\(model.percentage)%")
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
                }
                .padding(.horizontal, 22).padding(.vertical, 17)
                .frame(width: 420, height: 112, alignment: .leading)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(model.isCompactStatus ? Color.white.opacity(0.22) : model.accent.opacity(0.45), lineWidth: 1))
    }
}
