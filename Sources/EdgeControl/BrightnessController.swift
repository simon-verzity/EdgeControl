import AppKit
import CoreGraphics
import Darwin
import Metal
import QuartzCore

/// Controls the built-in brightness range and, on EDR displays, unlocks
/// additional brightness for SDR content using the display's HDR headroom.
enum DisplayBrightness {
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32

    private static let framework: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_NOW | RTLD_LOCAL
    )

    private static let getBrightness: GetBrightness? = {
        guard let framework, let symbol = dlsym(framework, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetBrightness.self)
    }()

    private static let setBrightness: SetBrightness? = {
        guard let framework, let symbol = dlsym(framework, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: SetBrightness.self)
    }()

    private static var extendedPercent: Int?
    private static var gestureCeiling = 100

    /// Returns the normal macOS brightness value, from 0.0 to 1.0.
    static func read() -> Float? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        guard getBrightness(CGMainDisplayID(), &value) == 0,
              value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    static var supportsEDR: Bool {
        guard let screen = mainScreen else { return false }
        return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
    }

    static var maximumPercent: Int {
        guard UserDefaults.standard.bool(forKey: "edrBrightnessEnabled"), supportsEDR,
              let screen = mainScreen else {
            return 100
        }
        // Keep the first version's boost ceiling conservative, matching the
        // 2x maximum used by similar EDR brightness utilities.
        return Int(min(2, screen.maximumPotentialExtendedDynamicRangeColorComponentValue) * 100)
    }

    static func beginGesture() {
        gestureCeiling = UserDefaults.standard.bool(forKey: "edrBrightnessEnabled") &&
            (currentPercent ?? 0) >= 100 ? maximumPercent : 100
    }

    static func endGesture() {
        gestureCeiling = 100
    }

    static func setEDREnabled(_ enabled: Bool) {
        guard !enabled else { return }
        EDRBrightnessBoost.disable()
        if let extendedPercent, extendedPercent > 100,
           let setBrightness {
            _ = setBrightness(CGMainDisplayID(), 1)
        }
        extendedPercent = nil
        gestureCeiling = 100
    }

    static var currentPercent: Int? {
        if let extendedPercent { return extendedPercent }
        return read().map { Int(($0 * 100).rounded()) }
    }

    /// Applies a relative brightness step. The logical scale is 0–100% SDR,
    /// then extends into EDR headroom up to the display's supported ceiling.
    @discardableResult
    static func setStep(_ delta: Int) -> Int? {
        guard delta != 0, let current = currentPercent else { return currentPercent }
        let target = min(min(maximumPercent, gestureCeiling), max(0, current + delta))
        // Once a swipe comes back into SDR range, that swipe cannot re-enter
        // EDR. Lifting and starting a fresh gesture at 100% is required.
        if current > 100, target <= 100 {
            gestureCeiling = 100
        }
        if target > 100 {
            guard let setBrightness else { return current }
            let priorLevel = read() ?? Float(min(current, 100)) / 100
            guard setBrightness(CGMainDisplayID(), 1) == 0 else { return current }
            guard EDRBrightnessBoost.set(multiplier: Float(target) / 100) else {
                EDRBrightnessBoost.disable()
                _ = setBrightness(CGMainDisplayID(), priorLevel)
                extendedPercent = nil
                return currentPercent
            }
            extendedPercent = target
            return target
        }

        EDRBrightnessBoost.disable()
        guard let setBrightness, setBrightness(CGMainDisplayID(), Float(target) / 100) == 0 else {
            extendedPercent = nil
            return currentPercent
        }
        extendedPercent = nil
        return target
    }

    static func restoreExtendedBrightness() {
        EDRBrightnessBoost.disable()
        extendedPercent = nil
        gestureCeiling = 100
    }

    private static var mainScreen: NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }
    }
}

/// Enables EDR composition with a tiny Metal surface, then applies an EDR
/// transfer ramp so ordinary SDR pixels can use some of that display range.
private enum EDRBrightnessBoost {
    private struct GammaTable {
        let red: [CGGammaValue]
        let green: [CGGammaValue]
        let blue: [CGGammaValue]
        let sampleCount: UInt32
    }

    private static var primerWindow: NSWindow?
    private static var displayID: CGDirectDisplayID?
    private static var originalGamma: GammaTable?

    static func set(multiplier: Float) -> Bool {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }), screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1,
              let displayID = displayIDForMainScreen(),
              ensurePrimer(on: screen),
              (originalGamma != nil || saveOriginalGamma(on: displayID)) else {
            return false
        }
        self.displayID = displayID
        return applyRamp(on: displayID, ceiling: multiplier)
    }

    static func disable() {
        if let displayID, let originalGamma {
            originalGamma.red.withUnsafeBufferPointer { red in
                originalGamma.green.withUnsafeBufferPointer { green in
                    originalGamma.blue.withUnsafeBufferPointer { blue in
                        _ = CGSetDisplayTransferByTable(displayID, originalGamma.sampleCount,
                                                        red.baseAddress, green.baseAddress, blue.baseAddress)
                    }
                }
            }
        }
        displayID = nil
        originalGamma = nil
        primerWindow?.orderOut(nil)
        primerWindow = nil
    }

    private static func displayIDForMainScreen() -> CGDirectDisplayID? {
        CGMainDisplayID()
    }

    private static func ensurePrimer(on screen: NSScreen) -> Bool {
        if primerWindow != nil { return true }
        guard let device = MTLCreateSystemDefaultDevice() else { return false }

        let view = EDRPrimerView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.wantsLayer = true
        guard let layer = view.layer as? CAMetalLayer else { return false }
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.wantsExtendedDynamicRangeContent = true
        layer.frame = view.bounds
        layer.drawableSize = CGSize(width: screen.backingScaleFactor, height: screen.backingScaleFactor)

        let window = NSWindow(contentRect: NSRect(x: screen.frame.maxX - 1,
                                                   y: screen.frame.minY,
                                                   width: 1,
                                                   height: 1),
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = view

        guard renderPrimer(layer: layer, device: device,
                           intensity: min(2, Float(screen.maximumPotentialExtendedDynamicRangeColorComponentValue))) else {
            return false
        }
        window.orderFrontRegardless()
        primerWindow = window
        return true
    }

    private static func renderPrimer(layer: CAMetalLayer, device: MTLDevice, intensity: Float) -> Bool {
        guard let queue = device.makeCommandQueue(),
              let drawable = layer.nextDrawable(),
              let buffer = queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(intensity),
                                                             green: Double(intensity),
                                                             blue: Double(intensity),
                                                             alpha: 1)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
        return true
    }

    private static func applyRamp(on displayID: CGDirectDisplayID, ceiling: Float) -> Bool {
        let count = Int(CGDisplayGammaTableCapacity(displayID))
        guard count > 1 else { return false }
        let ramp: [CGGammaValue] = (0..<count).map {
            CGGammaValue(Float($0) / Float(count - 1) * ceiling)
        }
        let result = ramp.withUnsafeBufferPointer { buffer in
            CGSetDisplayTransferByTable(displayID, UInt32(count), buffer.baseAddress,
                                        buffer.baseAddress, buffer.baseAddress)
        }
        return result == .success
    }

    private static func saveOriginalGamma(on displayID: CGDirectDisplayID) -> Bool {
        let capacity = CGDisplayGammaTableCapacity(displayID)
        guard capacity > 1 else { return false }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = [CGGammaValue](repeating: 0, count: Int(capacity))
        var blue = [CGGammaValue](repeating: 0, count: Int(capacity))
        var sampleCount: UInt32 = 0
        let result = red.withUnsafeMutableBufferPointer { redBuffer in
            green.withUnsafeMutableBufferPointer { greenBuffer in
                blue.withUnsafeMutableBufferPointer { blueBuffer in
                    CGGetDisplayTransferByTable(displayID, capacity,
                                                redBuffer.baseAddress, greenBuffer.baseAddress,
                                                blueBuffer.baseAddress, &sampleCount)
                }
            }
        }
        guard result == .success, sampleCount > 1 else { return false }
        originalGamma = GammaTable(red: Array(red.prefix(Int(sampleCount))),
                                   green: Array(green.prefix(Int(sampleCount))),
                                   blue: Array(blue.prefix(Int(sampleCount))),
                                   sampleCount: sampleCount)
        return true
    }
}

private final class EDRPrimerView: NSView {
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
}
