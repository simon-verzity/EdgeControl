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

struct TrackpadContact {
    let point: CGPoint
    let major: Float
    let minor: Float
    let identifier: Int32?

    init(point: CGPoint, major: Float, minor: Float, identifier: Int32? = nil) {
        self.point = point
        self.major = major
        self.minor = minor
        self.identifier = identifier
    }
}

struct TrackpadContactFilter {
    private var rejectedUntilLift = false
    private(set) var rejectionReason: String?
    private(set) var startPoint: CGPoint?
    private(set) var touchID = UUID()
    private(set) var currentPoint: CGPoint?
    private(set) var currentMajor: Float?
    private(set) var currentMinor: Float?
    private var horizontalContact = false
    private var trackedContactIdentifier: Int32?
    private var lastAcceptedContact: TrackpadContact?
    static let rejectedFrame = [CGPoint(x: -1, y: -1), CGPoint(x: 2, y: 2)]

    private mutating func reject(_ reason: String) -> [CGPoint] {
        if !rejectedUntilLift { rejectionReason = reason }
        rejectedUntilLift = true
        return Self.rejectedFrame
    }

    private static func isDistantPalm(_ contact: TrackpadContact, from primary: TrackpadContact) -> Bool {
        let distance = hypot(contact.point.x - primary.point.x, contact.point.y - primary.point.y)
        let area = contact.major * contact.minor
        let looksLarge = area > 130 || contact.major > 13 || contact.minor > 8
        // A second small contact is a real multi-finger gesture. Only tolerate
        // a single, clearly larger contact when it is far from the tracked
        // finger. The original finger remains the only gesture input.
        return distance >= 0.18 && looksLarge
    }

    private static func isPlausibleContinuation(_ contact: TrackpadContact,
                                                after previous: TrackpadContact) -> Bool {
        let distance = hypot(contact.point.x - previous.point.x, contact.point.y - previous.point.y)
        guard distance <= 0.12 else { return false }
        // A changed ID may still be the same finger. Do not use this recovery
        // path for a clearly larger contact, which is more likely a palm.
        if previous.major == 0 && previous.minor == 0 { return true }
        let majorRatio = contact.major / max(previous.major, 1)
        let minorRatio = contact.minor / max(previous.minor, 1)
        let area = contact.major * contact.minor
        let previousArea = previous.major * previous.minor
        return majorRatio <= 1.6 && minorRatio <= 1.6 && area <= max(130, previousArea * 2)
    }

    mutating func frame(_ contacts: [TrackpadContact], uncertain: Bool = false,
                        lifted: Bool = false, hovering: Bool = false,
                        edgeWidth: Double = 0.05) -> [CGPoint] {
        if lifted {
            rejectedUntilLift = false
            rejectionReason = nil
            startPoint = nil
            horizontalContact = false
            touchID = UUID()
            currentPoint = nil
            currentMajor = nil
            currentMinor = nil
            trackedContactIdentifier = nil
            lastAcceptedContact = nil
            return []
        }
        // Hover isn't a malformed contact. End any active gesture without
        // clearing a real palm rejection latch or claiming this device.
        if hovering {
            if !rejectedUntilLift {
                startPoint = nil
                touchID = UUID()
                trackedContactIdentifier = nil
                lastAcceptedContact = nil
            }
            currentPoint = nil
            currentMajor = nil
            currentMinor = nil
            return []
        }
        if uncertain {
            currentPoint = nil
            currentMajor = nil
            currentMinor = nil
            return reject("Invalid frame")
        }
        guard !rejectedUntilLift else { return Self.rejectedFrame }

        guard !contacts.isEmpty else {
            currentPoint = nil
            currentMajor = nil
            currentMinor = nil
            return reject("Missing contact")
        }

        let contact: TrackpadContact
        if let currentIdentifier = trackedContactIdentifier {
            if let tracked = contacts.first(where: { $0.identifier == currentIdentifier }) {
                let extras = contacts.filter { $0.identifier != currentIdentifier }
                guard extras.isEmpty || (extras.count == 1 && Self.isDistantPalm(extras[0], from: tracked)) else {
                    currentPoint = tracked.point
                    currentMajor = tracked.major
                    currentMinor = tracked.minor
                    return reject("Multiple / missing contacts")
                }
                contact = tracked
            } else if contacts.count == 1, let candidate = contacts.first,
                      let previous = lastAcceptedContact,
                      Self.isPlausibleContinuation(candidate, after: previous) {
                // Some trackpad frames briefly expose a new path ID for the
                // same nearby finger. Rebind only to one nearby, size-compatible
                // contact so the side volume gesture is not lost.
                trackedContactIdentifier = candidate.identifier
                contact = candidate
            } else {
                currentPoint = nil
                currentMajor = nil
                currentMinor = nil
                return reject("Tracked finger missing")
            }
        } else {
            guard contacts.count == 1, let first = contacts.first else {
                currentPoint = nil
                currentMajor = nil
                currentMinor = nil
                return reject("Multiple / missing contacts")
            }
            contact = first
            trackedContactIdentifier = first.identifier
        }

        let point = contact.point
        let major = contact.major
        let minor = contact.minor
        currentPoint = point
        currentMajor = major
        currentMinor = minor
        if startPoint == nil {
            startPoint = point
            let band = CGFloat(edgeWidth.isFinite ? min(0.18, max(0.02, edgeWidth)) : 0.05)
            // Side strips retain priority at corners. Choose once, from the
            // original touchdown, so drifting cannot bypass side palm checks.
            horizontalContact = point.x > band && point.x < 1 - band &&
                (point.y <= band || point.y >= 1 - band)
        }
        guard point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y),
              major.isFinite, minor.isFinite, major >= 0, minor >= 0 else {
            return reject("Invalid contact data")
        }
        let majorLimit: Float = horizontalContact ? 32 : 21
        let minorLimit: Float = horizontalContact ? 24 : 16
        let areaLimit: Float = horizontalContact ? 500 : 130
        if major > majorLimit || minor > minorLimit {
            return reject("Contact axes > \(Int(majorLimit))/\(Int(minorLimit))")
        } else if major * minor > areaLimit {
            return reject("Contact area > \(Int(areaLimit))")
        } else if !horizontalContact && major > 13 && minor > 8 {
            return reject("Contact too wide")
        }
        lastAcceptedContact = contact
        // Devices that omit contact axes report zeros; motion qualification
        // still applies to those devices.
        return [point]
    }
}

enum HorizontalEdgeSwipePolicy {
    static let minimumTravel: CGFloat = 0.015
    static let directionRatio: CGFloat = 1.25

    static func contains(_ point: CGPoint, edge: String, width: Double, allowDrift: Bool = false) -> Bool {
        let band = CGFloat(width) + (allowDrift ? 0.03 : 0)
        switch edge {
        case "top": return point.y >= 1 - band
        case "bottom": return point.y <= band
        default: return false
        }
    }
}

struct SideVolumeStartupGuard {
    private var beganAt: TimeInterval?
    private var hasChangedVolume = false
    private var rejected = false

    mutating func begin(now: TimeInterval, enabled: Bool) {
        self = SideVolumeStartupGuard()
        if enabled { beganAt = now }
    }

    mutating func allows(now: TimeInterval) -> Bool {
        if let beganAt, !hasChangedVolume, now >= beganAt + 1 {
            rejected = true
        }
        return !rejected
    }

    mutating func recordVolumeChange(_ didChange: Bool) {
        guard beganAt != nil, !rejected, didChange else { return }
        hasChangedVolume = true
    }
}

struct EdgeSwipeIntentGuard {
    private var rejected = false
    private(set) var rejectionReason: String?

    mutating func allows(start: CGPoint, current: CGPoint, horizontal: Bool,
                         startedOnEdge: Bool, elapsed: TimeInterval, armed: Bool,
                         activationTimeout: TimeInterval = 0.6) -> Bool {
        // Top/bottom swipes only need to originate on that edge. Direction is
        // qualified separately, without permanently rejecting natural drift,
        // corner starts, or a short pause before moving.
        if horizontal {
            rejectionReason = startedOnEdge ? nil : "Start outside edge"
            return startedOnEdge
        }
        // Direction and palm checks qualify the beginning, not the rest of a
        // valid continuous swipe. Earlier rejection still cannot be bypassed.
        if armed { return startedOnEdge && !rejected }
        let along = abs(horizontal ? current.x - start.x : current.y - start.y)
        let across = abs(horizontal ? current.y - start.y : current.x - start.x)
        let startedInCorner = (start.x < 0.08 || start.x > 0.92) && (start.y < 0.08 || start.y > 0.92)
        let crossLimit: CGFloat = horizontal ? 0.015 : 0.012
        let ratio: CGFloat = horizontal ? 2 : 3
        // Resting contacts must not become edge gestures after a later shift.
        if !startedOnEdge || startedInCorner || across > crossLimit ||
            (across > 0.006 && across * ratio > along) || (!armed && elapsed > activationTimeout) {
            if !rejected {
                if !startedOnEdge { rejectionReason = "Start outside edge" }
                else if startedInCorner { rejectionReason = "Corner start" }
                else if across > crossLimit { rejectionReason = "Cross-edge drift" }
                else if across > 0.006 && across * ratio > along { rejectionReason = "Direction mismatch" }
                else { rejectionReason = "Start timed out" }
            }
            rejected = true
        }
        return !rejected
    }
}

struct TrackpadRejection: Identifiable {
    let id = UUID()
    let touchID: UUID
    let timestamp: Date
    let source: String
    let reason: String
    let start: CGPoint?
    let current: CGPoint?
    let edgeWidth: Double?
    let major: Float?
    let minor: Float?

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    static func coordinates(_ point: CGPoint?) -> String {
        guard let point else { return "unavailable" }
        return String(format: "X=%.4f Y=%.4f", Double(point.x), Double(point.y))
    }
    var report: String {
        var lines = ["\(Self.formatter.string(from: timestamp)) [\(source)] \(reason)",
                     "Start: \(Self.coordinates(start)) | Current: \(Self.coordinates(current))"]
        if let edgeWidth { lines.append(String(format: "Edge width: %.4f", edgeWidth)) }
        if let major, let minor {
            lines.append(String(format: "Axes: %.2f × %.2f | Area: %.2f", Double(major), Double(minor), Double(major) * Double(minor)))
        }
        return lines.joined(separator: "\n")
    }
    var summary: String {
        "\(Self.formatter.string(from: timestamp)) \(reason)\nStart: \(Self.coordinates(start))"
    }
}

struct TrackpadRejectionHistory {
    private(set) var entries: [TrackpadRejection] = []
    mutating func append(_ entry: TrackpadRejection) -> Bool {
        guard !entries.contains(where: {
            $0.touchID == entry.touchID && $0.source == entry.source && $0.reason == entry.reason
        }) else { return false }
        entries.insert(entry, at: 0)
        if entries.count > 25 { entries.removeLast(entries.count - 25) }
        return true
    }
    mutating func clear() { entries.removeAll() }
}

struct TrackpadDebugFrame {
    let received: Int
    let passed: Int
    let contacts: Int
    let state: String
    let capturedAt: TimeInterval
    let point: CGPoint?
    let startPoint: CGPoint?
    let major: Float?
    let minor: Float?
    let touchID: UUID
}

final class TrackpadMonitor {
    private var framework: UnsafeMutableRawPointer?
    private var deviceList: CFArray?
    private var devices: [UnsafeRawPointer] = []
    private let filterLock = NSLock()
    private var contactFilters: [UInt: TrackpadContactFilter] = [:]
    private var activeDeviceID: UInt?
    var onFrame: (([CGPoint]) -> Void)?
    var onDebugFrame: ((TrackpadDebugFrame) -> Void)?
    var debugFramesEnabled: () -> Bool = { UserDefaults.standard.bool(forKey: "debugTrackpadFrames") }
    private var receivedFrames = 0
    private var passedFrames = 0
    private var lastDebugDelivery: TimeInterval = 0

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
        filterLock.lock()
        contactFilters.removeAll()
        activeDeviceID = nil
        filterLock.unlock()
        if let framework { dlclose(framework) }
        framework = nil
    }

    func consume(_ touches: UnsafeMutableRawPointer?, count: Int, device: UnsafeRawPointer?) {
        filterLock.lock()
        defer { filterLock.unlock() }
        let deviceID = device.map { UInt(bitPattern: $0) } ?? 0
        receivedFrames += 1
        let capturedAt = ProcessInfo.processInfo.systemUptime
        var frameState = count == 0 ? "No contact" : "Hover / pre-touch"
        var debugPoint: CGPoint?
        var debugMajor: Float?
        var debugMinor: Float?
        var debugStart: CGPoint?
        var debugTouchID = UUID()
        var captureRejection = false
        let previousRejection = contactFilters[deviceID]?.rejectionReason
        defer {
            if debugFramesEnabled(), captureRejection || capturedAt - lastDebugDelivery >= 0.1 {
                lastDebugDelivery = capturedAt
                let frame = TrackpadDebugFrame(received: receivedFrames, passed: passedFrames,
                                               contacts: count, state: frameState, capturedAt: capturedAt, point: debugPoint,
                                               startPoint: debugStart, major: debugMajor, minor: debugMinor, touchID: debugTouchID)
                DispatchQueue.main.async { [weak self] in self?.onDebugFrame?(frame) }
            }
        }
        var filter = contactFilters[deviceID] ?? TrackpadContactFilter()
        func publish(_ points: [CGPoint]) {
            contactFilters[deviceID] = filter
            debugStart = filter.startPoint
            debugTouchID = filter.touchID
            if let point = filter.currentPoint {
                debugPoint = point
                debugMajor = filter.currentMajor
                debugMinor = filter.currentMinor
            }
            // An idle second device must not end the first device's touch or
            // reset its palm rejection latch.
            guard activeDeviceID == nil || activeDeviceID == deviceID else {
                frameState = "Other device (ignored)"
                return
            }
            if points.count == 1 {
                passedFrames += 1
                frameState = "Single contact passed"
            } else if !points.isEmpty {
                frameState = "Rejected: \(filter.rejectionReason ?? "Unknown")"
                captureRejection = filter.rejectionReason != previousRejection
            }
            if points.isEmpty {
                guard activeDeviceID == deviceID else { return }
                activeDeviceID = nil
            } else {
                activeDeviceID = deviceID
            }
            DispatchQueue.main.async { [weak self] in self?.onFrame?(points) }
        }
        guard count >= 0, count < 16 else {
            publish(filter.frame([], uncertain: true))
            return
        }
        guard count > 0 else {
            publish(filter.frame([], lifted: true))
            return
        }
        guard let touches else {
            publish(filter.frame([], uncertain: true))
            return
        }
        let raw = UnsafeRawPointer(touches)
        var contacts: [TrackpadContact] = []
        var rejectContact = false
        var allContactsLifted = true
        for index in 0..<count {
            // Current MTTouch records are 96 bytes. These offsets are the
            // state, normalized x/y, and contact-axis fields in Apple's
            // private structure. Axes are treated as device-reported size hints.
            let touch = raw.advanced(by: index * 96)
            let state = touch.load(fromByteOffset: 20, as: Int32.self)
            switch state {
            case 0, 5, 6, 7: break
            case 1, 2, 3, 4: allContactsLifted = false
            default:
                allContactsLifted = false
                rejectContact = true
            }
            if state == 3 || state == 4 {
                let identifier = touch.load(fromByteOffset: 24, as: Int32.self)
                let x = touch.load(fromByteOffset: 32, as: Float.self)
                let y = touch.load(fromByteOffset: 36, as: Float.self)
                let major = touch.load(fromByteOffset: 60, as: Float.self)
                let minor = touch.load(fromByteOffset: 64, as: Float.self)

                if debugPoint == nil, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) {
                    debugPoint = CGPoint(x: CGFloat(x), y: CGFloat(y))
                    debugMajor = major.isFinite ? major : nil
                    debugMinor = minor.isFinite ? minor : nil
                }

                guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
                      major.isFinite, minor.isFinite, major >= 0, minor >= 0 else {
                    rejectContact = true
                    continue
                }

                contacts.append(TrackpadContact(point: CGPoint(x: CGFloat(x), y: CGFloat(y)), major: major, minor: minor,
                                                identifier: identifier))
            }
        }

        let hovering = contacts.isEmpty && !rejectContact && !allContactsLifted
        let width = UserDefaults.standard.object(forKey: "edgeFraction") == nil
            ? 0.05 : UserDefaults.standard.double(forKey: "edgeFraction")
        publish(filter.frame(contacts, uncertain: rejectContact, lifted: allContactsLifted, hovering: hovering, edgeWidth: width))
    }

    deinit { stop() }
}

private let edgeBarContactCallback: MTFrameCallback = { device, touches, count, _, _, context in
    guard let context else { return }
    Unmanaged<TrackpadMonitor>.fromOpaque(context).takeUnretainedValue().consume(touches, count: count, device: device)
}
