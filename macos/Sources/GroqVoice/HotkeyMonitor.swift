import Cocoa

/// Keys that can serve as the push-to-talk trigger. All are modifiers, so
/// holding one never types anything and the rest of the keyboard keeps working.
enum HotkeyKey: String, CaseIterable {
    case fn, rightCommand, rightOption, rightControl, leftControl

    var title: String {
        switch self {
        case .fn: return "Fn (🌐)"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .rightControl: return "Right ⌃"
        case .leftControl: return "Left ⌃"
        }
    }

    var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .rightCommand: return 54
        case .rightOption: return 61
        case .rightControl: return 62
        case .leftControl: return 59
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightCommand: return .maskCommand
        case .rightOption: return .maskAlternate
        case .rightControl, .leftControl: return .maskControl
        }
    }

    /// Extra setup the user has to do for this key to work as a plain hotkey.
    var caveat: String? {
        switch self {
        case .fn:
            return "Set System Settings → Keyboard → “Press 🌐 key to” → “Do Nothing”, otherwise a double-tap opens the emoji picker or dictation."
        case .rightOption:
            return "On layouts that use Right ⌥ for accented letters (e.g. Latvian ā, ē) holding it will interfere with typing them."
        default:
            return nil
        }
    }
}

/// Global hotkey monitor via a listen-only CGEventTap. Emits raw down/up
/// events on the main queue; the tap/hold/lock state machine lives in
/// AppController. Requires Accessibility permission.
final class HotkeyMonitor {
    var key: HotkeyKey {
        didSet { isDown = false }
    }

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onChordKey: (() -> Void)?      // another key pressed while the hotkey is held
    var onScreenToggle: (() -> Void)?  // ⌃⌥⌘R — start/stop screen recording

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

    init(key: HotkeyKey) {
        self.key = key
    }

    func start() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        switch type {
        case .flagsChanged:
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            let flagOn = event.flags.contains(key.flag)
            if key == .fn {
                // Fn has no sibling key sharing its flag, and its keycode differs
                // between keyboards (63, or 179 on Globe-key models) — so trust
                // the flag transition itself.
                if flagOn && !isDown {
                    isDown = true
                    DispatchQueue.main.async { self.onKeyDown?() }
                } else if !flagOn && isDown {
                    isDown = false
                    DispatchQueue.main.async { self.onKeyUp?() }
                }
                return
            }
            if keycode == key.keyCode {
                // Modifiers send exactly one flagsChanged on press and one on
                // release, so toggle on our own keycode. This stays correct
                // even when the sibling key (e.g. Left ⌘ while Right ⌘ is the
                // hotkey) keeps the shared flag bit set.
                if !isDown && flagOn {
                    isDown = true
                    DispatchQueue.main.async { self.onKeyDown?() }
                } else if isDown {
                    isDown = false
                    DispatchQueue.main.async { self.onKeyUp?() }
                }
            } else if isDown && !flagOn {
                // We missed the release (tap was disabled for a moment) — resync.
                isDown = false
                DispatchQueue.main.async { self.onKeyUp?() }
            }
        case .keyDown:
            // ⌃⌥⌘R (R = 0x0F) toggles screen recording — an uncommon combo,
            // checked independently of the hotkey.
            let mods: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if keycode == 0x0F,
               event.flags.contains(mods),
               !event.flags.contains(.maskShift) {
                DispatchQueue.main.async { self.onScreenToggle?() }
            } else if isDown {
                DispatchQueue.main.async { self.onChordKey?() }
            }
        default:
            break
        }
    }
}
