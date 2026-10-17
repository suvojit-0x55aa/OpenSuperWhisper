import AppKit
import Carbon
import Foundation

enum MouseButton: String, CaseIterable, Identifiable, Codable {
    case none = "none"
    case middle = "middle"
    case button4 = "button4"
    case button5 = "button5"
    case button6 = "button6"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .middle: return "Button 3 (Middle)"
        case .button4: return "Button 4 (Back)"
        case .button5: return "Button 5 (Forward)"
        case .button6: return "Button 6"
        }
    }

    var shortSymbol: String {
        switch self {
        case .none: return ""
        case .middle: return "🖱3"
        case .button4: return "🖱4"
        case .button5: return "🖱5"
        case .button6: return "🖱6"
        }
    }

    /// The `buttonNumber` reported by CGEvent's `.mouseEventButtonNumber` field.
    /// macOS numbers buttons from zero: 0 = left, 1 = right, 2 = middle, 3+ = extra
    /// (thumb / side) buttons. The user-facing names above use the common one-based
    /// convention (left = Button 1), so each case maps to `buttonNumber - 1`.
    var buttonNumber: Int64 {
        switch self {
        case .none: return -1
        case .middle: return 2
        case .button4: return 3
        case .button5: return 4
        case .button6: return 5
        }
    }
}

class MouseButtonMonitor {
    static let shared = MouseButtonMonitor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var selectedMouseButton: MouseButton = .none
    private var isButtonPressed = false

    var onButtonDown: (() -> Void)?
    var onButtonUp: (() -> Void)?
    var onFailure: (() -> Void)?

    init() {}

    @discardableResult
    func start(mouseButton: MouseButton) -> Bool {
        guard mouseButton != .none else {
            stop()
            return false
        }

        stop()

        selectedMouseButton = mouseButton
        isButtonPressed = false

        let eventMask = CGEventMask(
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)
        )

        // A default (not listen-only) tap so the bound button can be consumed and
        // used purely as a recording trigger, without also firing its normal action
        // (e.g. browser back/forward) in the focused app.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<MouseButtonMonitor>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.handleTapDisabled(reenable: monitor.reenableTap)
                    return Unmanaged.passUnretained(event)
                }

                if monitor.handleMouseEvent(type: type, event: event) {
                    // Matched the bound button — consume the event.
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("MouseButtonMonitor: Failed to create event tap. Check accessibility permissions.")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        guard let source = runLoopSource else {
            stop()
            print("MouseButtonMonitor: Failed to create event tap run loop source.")
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            stop()
            print("MouseButtonMonitor: Event tap could not be enabled.")
            return false
        }

        print("MouseButtonMonitor: Started monitoring for \(mouseButton.displayName)")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        isButtonPressed = false
        onFailure = nil
        print("MouseButtonMonitor: Stopped")
    }

    func handleTapDisabled(reenable: () -> Bool) {
        if !reenable() {
            reportFailure()
        }
    }

    fileprivate func reenableTap() -> Bool {
        guard let tap = eventTap else { return false }
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else { return false }
        print("MouseButtonMonitor: Re-enabled tap after timeout")
        return true
    }

    private func reportFailure() {
        let failure = onFailure
        stop()
        DispatchQueue.main.async {
            failure?()
        }
    }

    /// Returns `true` when the event belongs to the bound button and should be consumed.
    private func handleMouseEvent(type: CGEventType, event: CGEvent) -> Bool {
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        guard buttonNumber == selectedMouseButton.buttonNumber else { return false }

        switch type {
        case .otherMouseDown:
            if !isButtonPressed {
                isButtonPressed = true
                DispatchQueue.main.async {
                    self.onButtonDown?()
                }
            }
        case .otherMouseUp:
            if isButtonPressed {
                isButtonPressed = false
                DispatchQueue.main.async {
                    self.onButtonUp?()
                }
            }
        default:
            return false
        }
        return true
    }

    deinit {
        stop()
    }
}
