import Foundation
import CoreGraphics

@main
struct TrackpadPalmChecks {
    static func main() {
        func contact(_ x: CGFloat = 0.03, _ y: CGFloat = 0.5,
                     major: Float = 8, minor: Float = 5,
                     identifier: Int32? = nil) -> TrackpadContact {
            TrackpadContact(point: CGPoint(x: x, y: y), major: major, minor: minor, identifier: identifier)
        }
        var filter = TrackpadContactFilter()
        let finger = contact()
        let blocked = TrackpadContactFilter.rejectedFrame
        assert(filter.frame([finger]) == [finger.point])
        assert(filter.frame([contact(major: 13, minor: 9)]).count == 1, "Accept a wider finger")
        assert(filter.frame([contact(major: 14, minor: 8)]).count == 1)
        assert(filter.frame([contact(major: 16, minor: 10)]) == blocked)
        assert(filter.rejectionReason == "Contact area > 130")
        assert(filter.frame([finger]) == blocked, "A shrinking palm must stay rejected")
        assert(filter.frame([], lifted: true).isEmpty)
        assert(filter.frame([finger]) == [finger.point])

        // Side edges and centre retain the stricter palm filter.
        for point in [CGPoint(x: 0.03, y: 0.5), CGPoint(x: 0.97, y: 0.5),
                      CGPoint(x: 0.5, y: 0.5)] {
            var firstFrame = TrackpadContactFilter()
            assert(firstFrame.frame([TrackpadContact(point: point, major: 16, minor: 10)]) == blocked)
        }
        for y: CGFloat in [0.987, 0.013] {
            var topBottom = TrackpadContactFilter()
            let largeFinger = contact(0.3, y, major: 24, minor: 18)
            assert(topBottom.frame([largeFinger]).count == 1, "Horizontal edges must accept a broader finger")
            assert(topBottom.frame([contact(0.5, 0.5, major: 24, minor: 18)]).count == 1,
                   "Keep the original size policy when the swipe continues into the centre")
            assert(topBottom.frame([contact(0.5, 0.5, major: 35, minor: 25)]) == blocked,
                   "Still reject very large contacts")
            assert(topBottom.frame([largeFinger]) == blocked)
            _ = topBottom.frame([], lifted: true)
            assert(topBottom.frame([contact(0.5, 0.5, major: 24, minor: 18)]) == blocked,
                   "Lift must reset the horizontal allowance")
        }
        var sideToTop = TrackpadContactFilter()
        assert(sideToTop.frame([finger]).count == 1)
        assert(sideToTop.frame([contact(0.3, 0.987, major: 24, minor: 18)]) == blocked,
               "Moving a side-started contact to the top must not relax its palm filter")
        _ = filter.frame([], lifted: true)
        assert(filter.frame([contact(major: 0, minor: 0)]).count == 1, "Allow devices without size metadata")
        assert(filter.frame([finger, finger]) == blocked)
        assert(filter.frame([finger]) == blocked, "Multi-touch rejection lasts until full lift")
        _ = filter.frame([], lifted: true)
        assert(filter.frame([], uncertain: true) == blocked)
        assert(filter.frame([finger]) == blocked)
        _ = filter.frame([], lifted: true)
        assert(filter.frame([contact(major: .nan)]) == blocked)
        assert(filter.frame([finger]) == blocked)

        var startup = SideVolumeStartupGuard()
        var history = TrackpadRejectionHistory()
        let historyTouch = UUID()
        let origin = CGPoint(x: 0.3, y: 0.94)
        let rejectedAt = CGPoint(x: 0.3, y: 0.987)
        func rejection(_ id: UUID, _ timestamp: TimeInterval) -> TrackpadRejection {
            TrackpadRejection(touchID: id, timestamp: Date(timeIntervalSince1970: timestamp),
                              source: "Gesture", reason: "top: Start outside edge",
                              start: origin, current: rejectedAt, edgeWidth: 0.0516, major: nil, minor: nil)
        }
        assert(history.append(rejection(historyTouch, 1)))
        assert(!history.append(rejection(historyTouch, 2)), "Do not fill the log with frames from one rejected touch")
        assert(history.entries[0].timestamp == Date(timeIntervalSince1970: 1))
        assert(history.entries[0].report.contains("Start: X=0.3000 Y=0.9400"))
        assert(history.entries[0].report.contains("Current: X=0.3000 Y=0.9870"))
        for timestamp in 2...30 { assert(history.append(rejection(UUID(), Double(timestamp)))) }
        assert(history.entries.count == 25)
        assert(history.entries.first?.timestamp == Date(timeIntervalSince1970: 30))
        assert(history.entries.last?.timestamp == Date(timeIntervalSince1970: 6))
        history.clear()
        assert(history.entries.isEmpty)
        startup.begin(now: 10, enabled: true)
        assert(startup.allows(now: 10.9), "Give side-volume swipes a full second")
        startup.recordVolumeChange(false)
        assert(!startup.allows(now: 11), "No real volume change within one second must reject the touch")
        startup.recordVolumeChange(true)
        assert(!startup.allows(now: 12), "Late motion cannot reactivate the same resting touch")
        startup.begin(now: 20, enabled: true)
        assert(startup.allows(now: 20.9))
        startup.recordVolumeChange(true)
        assert(startup.allows(now: 30), "An established volume swipe may continue without a deadline")
        startup.begin(now: 40, enabled: true)
        assert(!startup.allows(now: 41), "Lifting resets the previous successful swipe")
        startup.begin(now: 50, enabled: false)
        assert(startup.allows(now: 60), "Other edges and controls must not get this deadline")

        var side = EdgeSwipeIntentGuard()
        let start = CGPoint(x: 0.03, y: 0.5)
        assert(side.allows(start: start, current: .init(x: 0.032, y: 0.54), horizontal: false,
                           startedOnEdge: true, elapsed: 0.15, armed: false))
        assert(side.allows(start: start, current: .init(x: 0.032, y: 0.65), horizontal: false,
                           startedOnEdge: true, elapsed: 2, armed: true), "Long deliberate swipes keep working")
        assert(side.allows(start: start, current: .init(x: 0.5, y: 0.7), horizontal: false,
                           startedOnEdge: true, elapsed: 3, armed: true), "Armed side swipe must continue into the centre")
        assert(side.allows(start: start, current: .init(x: 0.97, y: 0.8), horizontal: false,
                           startedOnEdge: true, elapsed: 4, armed: true), "Crossing another edge must not reject the original swipe")
        var slowerVolume = EdgeSwipeIntentGuard()
        assert(slowerVolume.allows(start: start, current: .init(x: 0.032, y: 0.54), horizontal: false,
                                   startedOnEdge: true, elapsed: 0.9, armed: false, activationTimeout: 1))
        assert(filter.frame([contact(0.5, 0.5)]).count == 2, "Previously rejected contact remains blocked")
        _ = filter.frame([], lifted: true)
        assert(filter.frame([finger]).count == 1)
        assert(filter.frame([contact(0.5, 0.5)]).count == 1, "A valid finger remains accepted away from the edge")
        var resting = EdgeSwipeIntentGuard()
        assert(!resting.allows(start: start, current: start, horizontal: false,
                               startedOnEdge: true, elapsed: 0.7, armed: false))
        assert(!resting.allows(start: start, current: .init(x: 0.03, y: 0.6), horizontal: false,
                               startedOnEdge: true, elapsed: 0.8, armed: false))
        var inward = EdgeSwipeIntentGuard()
        assert(!inward.allows(start: start, current: .init(x: 0.05, y: 0.51), horizontal: false,
                              startedOnEdge: true, elapsed: 0.15, armed: false))
        assert(!inward.allows(start: start, current: .init(x: 0.03, y: 0.6), horizontal: false,
                              startedOnEdge: true, elapsed: 0.25, armed: false))
        assert(!inward.allows(start: start, current: .init(x: 0.5, y: 0.6), horizontal: false,
                              startedOnEdge: true, elapsed: 1, armed: true), "An invalid start cannot be rescued by claiming it is armed")
        var horizontal = EdgeSwipeIntentGuard()
        let reportedTopStart = CGPoint(x: 0.3, y: 0.987)
        assert(horizontal.allows(start: reportedTopStart, current: .init(x: 0.4, y: 0.98), horizontal: true,
                                  startedOnEdge: HorizontalEdgeSwipePolicy.contains(reportedTopStart, edge: "top", width: 0.0516),
                                  elapsed: 1, armed: false), "The reported coordinate is a valid top-edge start")
        var outsideTop = EdgeSwipeIntentGuard()
        assert(!outsideTop.allows(start: .init(x: 0.3, y: 0.94), current: reportedTopStart, horizontal: true,
                                   startedOnEdge: false, elapsed: 0.1, armed: false))
        assert(outsideTop.rejectionReason == "Start outside edge")
        assert(horizontal.allows(start: .init(x: 0.5, y: 0.03), current: .init(x: 0.54, y: 0.032),
                                 horizontal: true, startedOnEdge: true, elapsed: 0.1, armed: false))
        var restingHorizontal = EdgeSwipeIntentGuard()
        assert(restingHorizontal.allows(start: .init(x: 0.5, y: 0.03), current: .init(x: 0.55, y: 0.03),
                                         horizontal: true, startedOnEdge: true, elapsed: 0.7, armed: false))
        for (edge, y, driftY) in [("top", 0.97, 0.935), ("bottom", 0.03, 0.065)] {
            let corner = CGPoint(x: 0.02, y: y)
            let drift = CGPoint(x: 0.06, y: driftY)
            var forgiving = EdgeSwipeIntentGuard()
            assert(forgiving.allows(start: corner, current: drift, horizontal: true,
                                    startedOnEdge: true, elapsed: 1, armed: false))
            assert(HorizontalEdgeSwipePolicy.contains(corner, edge: edge, width: 0.05))
            assert(!HorizontalEdgeSwipePolicy.contains(drift, edge: edge, width: 0.05))
            assert(HorizontalEdgeSwipePolicy.contains(drift, edge: edge, width: 0.05, allowDrift: true))
            assert(!HorizontalEdgeSwipePolicy.contains(.init(x: 0.5, y: 0.5), edge: edge, width: 0.05, allowDrift: true))
            assert(forgiving.allows(start: corner, current: .init(x: 0.5, y: 0.5), horizontal: true,
                                    startedOnEdge: true, elapsed: 3, armed: true), "Armed horizontal swipe must continue into the centre")
        }
        // An earlier side-edge rejection at a corner must not poison a later
        // horizontal swipe along the top/bottom edge.
        assert(inward.allows(start: .init(x: 0.02, y: 0.97), current: .init(x: 0.06, y: 0.96),
                              horizontal: true, startedOnEdge: true, elapsed: 0.2, armed: false))
        var entered = EdgeSwipeIntentGuard()
        assert(!entered.allows(start: .init(x: 0.2, y: 0.5), current: start, horizontal: false,
                               startedOnEdge: false, elapsed: 0.2, armed: false))

        // Replay raw frames through the real parser, without starting hardware
        // monitoring or changing the system volume.
        let monitor = TrackpadMonitor()
        monitor.debugFramesEnabled = { true }
        var debugFrame: TrackpadDebugFrame?
        monitor.onDebugFrame = { debugFrame = $0 }
        var frames: [[CGPoint]] = []
        monitor.onFrame = { frames.append($0) }
        let deviceA = UnsafeRawPointer(bitPattern: 1)!
        let deviceB = UnsafeRawPointer(bitPattern: 2)!
        func feed(_ contacts: [TrackpadContact], state: Int32 = 4,
                  device: UnsafeRawPointer = deviceA) {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(96, contacts.count * 96), alignment: 8)
            defer { buffer.deallocate() }
            buffer.initializeMemory(as: UInt8.self, repeating: 0, count: max(96, contacts.count * 96))
            for (index, contact) in contacts.enumerated() {
                let record = buffer.advanced(by: index * 96)
                record.storeBytes(of: state, toByteOffset: 20, as: Int32.self)
                record.storeBytes(of: contact.identifier ?? 0, toByteOffset: 24, as: Int32.self)
                record.storeBytes(of: Float(contact.point.x), toByteOffset: 32, as: Float.self)
                record.storeBytes(of: Float(contact.point.y), toByteOffset: 36, as: Float.self)
                record.storeBytes(of: contact.major, toByteOffset: 60, as: Float.self)
                record.storeBytes(of: contact.minor, toByteOffset: 64, as: Float.self)
            }
            monitor.consume(buffer, count: contacts.count, device: device)
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        // Normal fingers arrive through hover/pre-touch states before making
        // contact. Those frames must neither claim a device nor reject a touch.
        feed([finger], state: 1)
        assert(debugFrame?.received == 1 && debugFrame?.passed == 0,
               "Debug must count raw hover frames even when no gesture frame is emitted")
        feed([finger], state: 2)
        guard frames.isEmpty else {
            print("FAIL: Normal pre-touch/hover frames blocked the next finger gesture")
            exit(1)
        }
        feed([finger], state: 3)
        assert(frames.count == 1 && frames[0].count == 1)
        feed([finger], state: 2)
        assert(frames.last?.isEmpty == true, "Returning to hover must finish a normal tap")
        feed([finger], state: 3)
        assert(frames.last?.count == 1, "Hover must not block the next normal touch")
        let activeFrameCount = frames.count
        feed([], device: deviceB)
        feed([finger], state: 2, device: deviceB)
        assert(frames.count == activeFrameCount, "Idle or hovering second device must not end the active gesture")
        feed([contact(major: 16, minor: 10)])
        assert(frames.last == blocked)
        assert(debugFrame?.state == "Rejected: Contact area > 130", "A new rejection must be captured without waiting for the periodic sample")
        feed([], device: deviceB)
        feed([finger])
        assert(frames.last == blocked, "Second device must not reset palm rejection")
        feed([finger], state: 2)
        feed([finger])
        assert(frames.last == blocked, "Uncertain contact state must not rearm a palm")
        feed([finger], state: 5)
        assert(frames.last?.isEmpty == true)
        feed([finger])
        assert(frames.last?.count == 1)
        monitor.consume(nil, count: 16, device: deviceA)
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        assert(frames.last == blocked)
        feed([finger])
        assert(frames.last == blocked)
        feed([])
        feed([finger])
        assert(frames.last?.count == 1)
        // Keep the original finger when a distant palm contact appears later,
        // even when the raw contact order puts the palm first.
        let trackedFinger = contact(0.22, 0.976, major: 19, minor: 8, identifier: 1)
        let distantPalm = contact(0.987, 0.402, major: 19.16, minor: 8.10, identifier: 2)
        feed([trackedFinger], state: 5)
        feed([trackedFinger])
        feed([distantPalm, trackedFinger])
        assert(frames.last?.count == 1 && abs((frames.last?.first?.x ?? -1) - trackedFinger.point.x) < 0.00001,
               "A distant palm must not replace the tracked finger")
        RunLoop.main.run(until: Date().addingTimeInterval(0.11))
        feed([distantPalm, trackedFinger])
        assert(abs((debugFrame?.point?.x ?? -1) - trackedFinger.point.x) < 0.00001,
               "Debug current coordinate must follow the tracked finger")
        feed([contact(0.5, 0.97, major: 8, minor: 5, identifier: 2),
              contact(0.55, 0.97, major: 8, minor: 5, identifier: 1)])
        assert(frames.last == TrackpadContactFilter.rejectedFrame,
               "A normal second finger must still reject the frame")
        feed([], state: 5)
        feed([contact(0.2, 0.98, identifier: 3)])
        feed([contact(0.7, 0.5, identifier: 4)])
        assert(frames.last == TrackpadContactFilter.rejectedFrame,
               "A distant changed contact ID must not transfer the gesture")
        feed([], state: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.11))
        feed([finger])
        assert((debugFrame?.received ?? 0) > 1 && (debugFrame?.passed ?? 0) > 0)
        assert(abs((debugFrame?.point?.x ?? -1) - finger.point.x) < 0.00001)
        RunLoop.main.run(until: Date().addingTimeInterval(0.11))
        feed([contact(0.96, 0.97, major: 16, minor: 10)])
        assert(frames.last == blocked)
        assert(abs((debugFrame?.point?.x ?? -1) - 0.96) < 0.00001,
               "Debug coordinates must survive contact rejection")
        RunLoop.main.run(until: Date().addingTimeInterval(0.11))
        feed([])
        assert(debugFrame?.point == nil, "Lift clears the current touch coordinates")
        print("Palm checks passed: touchdown size, all edges, rejection latch, swipe intent, raw states and multiple devices")
    }
}
