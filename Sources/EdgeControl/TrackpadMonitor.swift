import CoreFoundation
import Darwin
import Foundation

// macOS does not publish a background API for raw trackpad contacts. This
// adapter loads Apple's MultitouchSupport private framework at runtime so the
// app can observe a finger independently of the on-screen pointer.
private typealias MTFrameCallback = @convention(c) (
    UnsafeRawPointer?, UnsafeMutableRawPointer?, Int, Double, Int, UnsafeMutableRawPointer?
) -> Void
private typealias MTCreateList = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTRegisterCallback = @convention(c) (UnsafeRawPointer?, MTFrameCallback?, UnsafeMutableRawPointer?) -> Void
private typealias MTDeviceStart = @convention(c) (UnsafeRawPointer?, Int32) -> Int32
private typealias MTDeviceStop = @convention(c) (UnsafeRawPointer?) -> Int32

final class TrackpadMonitor {
    private var framework: UnsafeMutableRawPointer?
    private var deviceList: CFArray?
    private var devices: [UnsafeRawPointer] = []
    private var rejectedUntilLift = false
    private var contactStart: CGPoint?
    private var contactStartMajor: Float = 0
    private var contactStartMinor: Float = 0
    var onFrame: (([CGPoint]) -> Void)?

    @discardableResult
    func start() -> Bool {
        guard framework == nil,
              let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let createSymbol = dlsym(handle, "MTDeviceCreateList"),
              let registerSymbol = dlsym(handle, "MTRegisterContactFrameCallbackWithRefcon"),
              let startSymbol = dlsym(handle, "MTDeviceStart") else { return false }

        framework = handle
        let create = unsafeBitCast(createSymbol, to: MTCreateList.self)
        let register = unsafeBitCast(registerSymbol, to: MTRegisterCallback.self)
        let startDevice = unsafeBitCast(startSymbol, to: MTDeviceStart.self)
        guard let list = create()?.takeRetainedValue() else { return false }
        deviceList = list

        let count = CFArrayGetCount(list)
        for index in 0..<count {
            guard let value = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeRawPointer(value)
            register(device, edgeBarContactCallback, Unmanaged.passUnretained(self).toOpaque())
            if startDevice(device, 0) == 0 { devices.append(device) }
        }
        return !devices.isEmpty
    }

    func stop() {
        if let framework, let symbol = dlsym(framework, "MTDeviceStop") {
            let stopDevice = unsafeBitCast(symbol, to: MTDeviceStop.self)
            devices.forEach { _ = stopDevice($0) }
        }
        devices.removeAll()
        deviceList = nil
        if let framework { dlclose(framework) }
        framework = nil
    }

    fileprivate func consume(_ touches: UnsafeMutableRawPointer?, count: Int) {
        guard count >= 0, count < 16 else { return }
        guard count > 0 else {
            resetContactFilter()
            DispatchQueue.main.async { [weak self] in self?.onFrame?([]) }
            return
        }
        guard let touches else {
            rejectedUntilLift = true
            emitRejectedFrame()
            return
        }
        let raw = UnsafeRawPointer(touches)
        var contacts: [(point: CGPoint, major: Float, minor: Float)] = []
        var rejectContact = false
        var sawActiveContact = false
        for index in 0..<count {
            // Current MTTouch records are 96 bytes. These offsets are the
            // state, normalized x/y, and contact-axis fields in Apple's
            // private structure. Axis values are reported in millimetres.
            let touch = raw.advanced(by: index * 96)
            let state = touch.load(fromByteOffset: 20, as: Int32.self)
            if state == 3 || state == 4 {
                sawActiveContact = true
                let x = touch.load(fromByteOffset: 32, as: Float.self)
                let y = touch.load(fromByteOffset: 36, as: Float.self)
                let major = touch.load(fromByteOffset: 60, as: Float.self)
                let minor = touch.load(fromByteOffset: 64, as: Float.self)

                guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
                      major.isFinite, minor.isFinite, major >= 0, minor >= 0 else {
                    rejectContact = true
                    continue
                }

                // A finger normally produces a compact oval. Reject contacts
                // with a broad axis or large footprint before they can enter
                // the gesture recognizer; latch the rejection until lift so
                // the same palm cannot resume as a valid one-finger gesture.
                // Zero-sized axes are accepted because some devices omit them.
                if (x <= 0.08 || x >= 0.92) && (major > 21 || minor > 16 || major * minor > 280) {
                    rejectContact = true
                    continue
                }
                contacts.append((CGPoint(x: CGFloat(x), y: CGFloat(y)), major, minor))
            }
        }

        if rejectContact || contacts.count > 1 {
            rejectedUntilLift = true
        }
        guard !contacts.isEmpty else {
            if sawActiveContact && rejectContact {
                rejectedUntilLift = true
                emitRejectedFrame()
                return
            }
            // State 5 (lift) is not an active contact. Treat it as the end of
            // this physical touch so the next touch starts with a clean filter.
            resetContactFilter()
            DispatchQueue.main.async { [weak self] in self?.onFrame?([]) }
            return
        }
        guard !rejectedUntilLift, contacts.count == 1, let contact = contacts.first else {
            emitRejectedFrame()
            return
        }

        if contactStart == nil {
            contactStart = contact.point
            contactStartMajor = contact.major
            contactStartMinor = contact.minor
        } else if let contactStart,
                  (enteredFromEdge(start: contactStart, current: contact.point) || isNearEdge(contact.point)),
                  isPalmSized(major: max(contactStartMajor, contact.major),
                              minor: max(contactStartMinor, contact.minor)) {
            rejectedUntilLift = true
            emitRejectedFrame()
            return
        }
        let position = contact.point
        DispatchQueue.main.async { [weak self] in self?.onFrame?([position]) }
    }

    private func enteredFromEdge(start: CGPoint, current: CGPoint) -> Bool {
        let travel: CGFloat = 0.045
        let edgeBand: CGFloat = 0.08
        return (start.x >= 1 - edgeBand && current.x <= start.x - travel) ||
            (start.x <= edgeBand && current.x >= start.x + travel)
    }

    private func isPalmSized(major: Float, minor: Float) -> Bool {
        major * minor > 130 || (major > 13 && minor > 8)
    }

    private func isNearEdge(_ point: CGPoint) -> Bool {
        let configuredWidth = UserDefaults.standard.object(forKey: "edgeFraction") == nil
            ? 0.05
            : UserDefaults.standard.double(forKey: "edgeFraction")
        let band = CGFloat(max(0.08, min(0.18, configuredWidth * 1.5)))
        return point.x <= band || point.x >= 1 - band
    }

    private func emitRejectedFrame() {
        let blocked = [CGPoint(x: -1, y: -1), CGPoint(x: 2, y: 2)]
        DispatchQueue.main.async { [weak self] in self?.onFrame?(blocked) }
    }

    private func resetContactFilter() {
        rejectedUntilLift = false
        contactStart = nil
        contactStartMajor = 0
        contactStartMinor = 0
    }

    deinit { stop() }
}

private let edgeBarContactCallback: MTFrameCallback = { _, touches, count, _, _, context in
    guard let context else { return }
    Unmanaged<TrackpadMonitor>.fromOpaque(context).takeUnretainedValue().consume(touches, count: count)
}
