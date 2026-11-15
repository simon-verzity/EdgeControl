import AppKit
import AudioToolbox
import CoreAudio
import CoreGraphics
import Darwin
import ObjectiveC.runtime

/// Reads and changes the default output's master volume without launching a
/// script process for every trackpad frame.
enum AudioVolumeController {
    static func readPercent() -> Int {
        if let value = readScalar() { return Int((value * 100).rounded()) }
        return scriptValue("output volume of (get volume settings)") ?? 0
    }

    @discardableResult
    static func change(by delta: Int) -> Int {
        // A muted output can retain its old level, making a volume swipe seem
        // ineffective. Unmute first, then apply the requested level change.
        if readMute() ?? scriptMuted() ?? false, !writeMute(false) {
            runScript("set volume with output muted false")
        }
        let next = min(100, max(0, readPercent() + delta))
        let scalar = Float(next) / 100
        if !writeScalar(scalar) {
            runScript("set volume output volume \(next)")
        }
        let actual = readPercent()
        EdgeHUD.shared.show(title: "Volume",
                            leftSymbol: "speaker.fill",
                            rightSymbol: "speaker.wave.3.fill",
                            level: Float(actual) / 100)
        return actual
    }

    @discardableResult
    static func toggleMute() -> Bool {
        let currentlyMuted = readMute() ?? scriptMuted() ?? false
        let target = !currentlyMuted
        if !writeMute(target) {
            runScript("set volume with output muted \(target ? "true" : "false")")
        }
        let actual = readMute() ?? scriptMuted() ?? target
        EdgeHUD.shared.showMuteStatus(muted: actual)
        return actual
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func readMute() -> Bool? {
        guard let device = defaultOutput() else { return nil }
        var address = muteAddress()
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    @discardableResult
    private static func writeMute(_ muted: Bool) -> Bool {
        guard let device = defaultOutput() else { return false }
        var address = muteAddress()
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectHasProperty(device, &address) &&
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private static func readScalar() -> Float? {
        guard let device = defaultOutput() else { return nil }
        var address = volumeAddress()
        var size = UInt32(MemoryLayout<Float>.size)
        var value: Float = 0
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              value.isFinite else { return nil }
        return min(1, max(0, value))
    }

    @discardableResult
    private static func writeScalar(_ value: Float) -> Bool {
        guard let device = defaultOutput() else { return false }
        var address = volumeAddress()
        var volume = min(1, max(0, value))
        return AudioObjectHasProperty(device, &address) &&
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &volume) == noErr
    }

    private static func scriptValue(_ source: String) -> Int? {
        let command = NSAppleScript(source: "return \(source)")
        var error: NSDictionary?
        guard let result = command?.executeAndReturnError(&error), error == nil else { return nil }
        return Int(result.int32Value)
    }

    private static func runScript(_ source: String) {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        _ = script?.executeAndReturnError(&error)
    }

    private static func scriptMuted() -> Bool? {
        let script = NSAppleScript(source: "return output muted of (get volume settings)")
        var error: NSDictionary?
        guard let result = script?.executeAndReturnError(&error), error == nil else { return nil }
        return result.booleanValue
    }
}

/// Uses the same private macOS OSD manager that is activated by the media keys.
/// The API is undocumented, so the volume change itself remains independent of it.
enum NativeSystemHUD {
    enum Image: Int64 {
        case brightness = 1
        case volume = 3
        case muted = 4
    }

    private static let osdFramework = dlopen(
        "/System/Library/PrivateFrameworks/OSD.framework/OSD",
        RTLD_NOW | RTLD_LOCAL
    )
    private static let manager: AnyObject? = {
        guard osdFramework != nil,
              let managerClass = NSClassFromString("OSDManager"),
              let method = class_getClassMethod(managerClass, NSSelectorFromString("sharedManager")) else {
            return nil
        }
        typealias SharedManager = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let sharedManager = unsafeBitCast(method_getImplementation(method), to: SharedManager.self)
        return sharedManager(managerClass, NSSelectorFromString("sharedManager"))?.takeUnretainedValue()
    }()

    static func show(image: Image, level: Int) {
        guard let manager,
              let method = class_getInstanceMethod(type(of: manager),
                  NSSelectorFromString("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:")) else {
            return
        }
        typealias ShowImage = @convention(c) (
            AnyObject, Selector, Int64, UInt32, UInt32, UInt32, UInt32, UInt32, Bool
        ) -> Void
        let showImage = unsafeBitCast(method_getImplementation(method), to: ShowImage.self)
        showImage(manager,
                  NSSelectorFromString("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:"),
                  image.rawValue, CGMainDisplayID(), 0x1F4, 1200,
                  UInt32(min(100, max(0, level))), 100, false)
    }
}
