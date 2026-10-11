import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Which physical key acts as the push-to-talk hotkey.
///
/// `CGEventFlags` alone can't tell left from right for Shift/Option/Control/
/// Command — both sides of a pair set the same flag bit. Fn is the exception
/// (`.maskSecondaryFn` has no left/right counterpart), which is why the
/// original implementation only ever needed a flag. Keys that share a flag
/// with their other side also carry a `keyCode` here so `HotkeyMonitor` can
/// disambiguate using the physical key code the event reports.
enum Hotkey: String, Equatable, Hashable, CaseIterable {
    case fn
    case rightShift = "right-shift"

    static let `default`: Hotkey = .fn

    /// Parses a config/CLI value, falling back to `.default` (loudly, not
    /// silently — an unrecognized value here should never look like success).
    static func parse(_ raw: String?) -> Hotkey {
        guard let raw, !raw.isEmpty else { return .default }
        guard let value = Hotkey(rawValue: raw) else {
            FileHandle.standardError.write(Data(
                "unknown hotkey '\(raw)' (expected: fn, right-shift) — falling back to \(Hotkey.default.rawValue)\n".utf8
            ))
            return .default
        }
        return value
    }

    /// CGEventFlags bit that must be set while the key is held.
    var flag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightShift: return .maskShift
        }
    }

    /// Physical keycode used to disambiguate keys whose flag is shared with
    /// another key (e.g. left/right Shift). `nil` when the flag alone is
    /// unambiguous.
    var keyCode: Int64? {
        switch self {
        case .fn: return nil
        case .rightShift: return 60 // kVK_RightShift
        }
    }

    /// Human-readable label for logs (`parrot doctor`, the startup banner).
    var label: String {
        switch self {
        case .fn: return "fn"
        case .rightShift: return "right shift"
        }
    }
}

/// Watches a single modifier key (default: Fn) and emits press/release edges.
/// Requires Accessibility permission. If the tap fails to register, callers
/// will see an error from `start()`.
final class HotkeyMonitor {
    enum Event { case pressed, released }
    enum HotkeyError: Error { case tapCreateFailed }

    private let mask: CGEventFlags
    private let requiredKeyCode: Int64?
    private let debug: Bool
    private var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    init(hotkey: Hotkey = .default, debug: Bool = false) {
        self.mask = hotkey.flag
        self.requiredKeyCode = hotkey.keyCode
        self.debug = debug
    }

    func start(onEvent: @escaping (Event) -> Void) throws {
        self.onEvent = onEvent

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if !trusted {
            FileHandle.standardError.write(Data(
                "accessibility not granted — system prompt opened. Grant access, then quit and relaunch parrot.\n".utf8
            ))
            throw HotkeyError.tapCreateFailed
        }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        // .cgSessionEventTap is the right level for an accessibility-granted
        // user process (.cghidEventTap requires root).
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: hotkeyCallback,
                userInfo: userInfo
            )
        else {
            throw HotkeyError.tapCreateFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        onEvent = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if debug {
            let flags = event.flags
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            FileHandle.standardError.write(
                Data(
                    "  [debug] type=\(type.rawValue) keycode=\(keycode) flags=\(String(flags.rawValue, radix: 16))\n"
                        .utf8
                ))
        }
        guard type == .flagsChanged else { return }
        if let requiredKeyCode, event.getIntegerValueField(.keyboardEventKeycode) != requiredKeyCode {
            // Some other key changed the same flag (e.g. the *other* Shift) — ignore it.
            return
        }
        let pressed = event.flags.contains(mask)
        guard pressed != isPressed else { return }
        isPressed = pressed
        onEvent?(pressed ? .pressed : .released)
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // System disabled our tap; we'll need to re-enable. For now just no-op
        // and let the user restart parrot.
        return Unmanaged.passUnretained(event)
    }

    let copy = event.copy()
    DispatchQueue.main.async {
        if let copy {
            monitor.handle(type: type, event: copy)
        }
    }
    return Unmanaged.passUnretained(event)
}
