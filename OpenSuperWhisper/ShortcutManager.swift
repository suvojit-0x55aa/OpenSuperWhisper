import AppKit
import Combine
import ApplicationServices
import Carbon
import Cocoa
import Foundation
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", initial: .init(.backtick, modifiers: .option))
    static let escape = Self("escape", initial: .init(.escape))
}

enum RecordingTrigger: Equatable {
    case keyCombination
    case modifier(ModifierKey)
    case mouseButton(MouseButton)
}

@MainActor
class ShortcutManager {
    static let shared = ShortcutManager()

    private var triggerPermissions: PermissionsManager?
    private var permissionSubscription: AnyCancellable?
    private var activeVm: IndicatorViewModel?
    private var holdWorkItem: DispatchWorkItem?
    private let holdThreshold: TimeInterval = 0.3
    private var holdMode = false

    init(registerShortcuts: Bool = true) {
        guard registerShortcuts else { return }
        print("ShortcutManager init")

        let permissions = PermissionsManager.shared
        triggerPermissions = permissions
        setupKeyboardShortcuts()
        setupRecordingTrigger()
        observeTriggerPermissions(permissions.$isAccessibilityPermissionGranted
            .combineLatest(permissions.$inputMonitoringPermissionState)
            .map { ($0 ? 1 : 0) | ($1 == .granted ? 2 : 0) }
            .eraseToAnyPublisher()) { [weak self] in self?.setupRecordingTrigger() }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeySettingsChanged),
            name: .hotkeySettingsChanged,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(indicatorWindowDidHide),
            name: .indicatorWindowDidHide,
            object: nil
        )
    }
    
    func observeTriggerPermissions(_ publisher: AnyPublisher<Int, Never>, reconfigure: @escaping () -> Void) {
        permissionSubscription = publisher
            .removeDuplicates()
            .dropFirst()
            .sink { _ in reconfigure() }
    }

    @objc private func indicatorWindowDidHide() {
        activeVm = nil
        holdMode = false
    }
    
    @objc private func hotkeySettingsChanged() {
        setupRecordingTrigger()
    }
    
    private func setupKeyboardShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecord) { [weak self] in
            self?.handleKeyDown()
        }

        KeyboardShortcuts.onKeyUp(for: .toggleRecord) { [weak self] in
            self?.handleKeyUp()
        }

        KeyboardShortcuts.onKeyUp(for: .escape) { [weak self] in
            Task { @MainActor in
                self?.handleEscape()
            }
        }
        KeyboardShortcuts.disable(.escape)
    }
    
    func handleEscape() {
        if IndicatorWindowManager.shared.requestCancel() {
            activeVm = nil
        }
    }

    private func setupRecordingTrigger() {
        let modifierKey = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .none
        let mouseButton = MouseButton(rawValue: AppPreferences.shared.mouseButtonHotkey) ?? .none
        let permissions = triggerPermissions ?? PermissionsManager.shared
        let trigger = Self.resolveRecordingTrigger(
            modifierKey: modifierKey,
            mouseButton: mouseButton,
            accessibilityGranted: permissions.isAccessibilityPermissionGranted,
            inputMonitoringState: permissions.inputMonitoringPermissionState
        )

        ModifierKeyMonitor.shared.stop()
        MouseButtonMonitor.shared.stop()

        switch trigger {
        case .mouseButton(let button):
            KeyboardShortcuts.disable(.toggleRecord)

            MouseButtonMonitor.shared.onButtonDown = { [weak self] in
                self?.handleKeyDown()
            }

            MouseButtonMonitor.shared.onButtonUp = { [weak self] in
                self?.handleKeyUp()
            }

            MouseButtonMonitor.shared.start(mouseButton: button)
            print("ShortcutManager: Using mouse-button hotkey: \(button.displayName)")
        case .modifier(let modifier):
            KeyboardShortcuts.disable(.toggleRecord)

            ModifierKeyMonitor.shared.onKeyDown = { [weak self] in
                self?.handleKeyDown()
            }

            ModifierKeyMonitor.shared.onKeyUp = { [weak self] in
                self?.handleKeyUp()
            }

            ModifierKeyMonitor.shared.start(modifierKey: modifier)
            print("ShortcutManager: Using modifier-only hotkey: \(modifier.displayName)")
        case .keyCombination:
            KeyboardShortcuts.enable(.toggleRecord)
            print("ShortcutManager: Using regular keyboard shortcut")
        }
    }

    static func resolveRecordingTrigger(
        modifierKey: ModifierKey,
        mouseButton: MouseButton,
        accessibilityGranted: Bool,
        inputMonitoringState: InputMonitoringPermissionState
    ) -> RecordingTrigger {
        if mouseButton != .none, accessibilityGranted {
            return .mouseButton(mouseButton)
        }
        if mouseButton == .none,
           modifierKey != .none,
           inputMonitoringState == .granted {
            return .modifier(modifierKey)
        }
        return .keyCombination
    }
    
    private func handleKeyDown() {
        holdWorkItem?.cancel()
        holdMode = false
        
        let session = RecordingSessionController.shared
        if session.hasSession {
            session.requestStop()
            return
        }
        guard activeVm == nil else { return }
        let vm = IndicatorWindowManager.shared.prepare()
        activeVm = vm
        vm.startRecording()
        let cursorPosition = FocusUtils.getCurrentCursorPosition()
        Task { @MainActor in
            let anchorPoint = await Self.resolveAnchorPoint(timeoutNanoseconds: 150_000_000)
            let point = FocusUtils.chooseIndicatorPoint(resolvedInputAnchor: anchorPoint, cursorPosition: cursorPosition)
            IndicatorWindowManager.shared.presentWindow(for: vm, nearPoint: point)
        }
        if AppPreferences.shared.holdToRecord && session.isCapturing {
            let workItem = DispatchWorkItem { [weak self] in self?.holdMode = true }
            holdWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: workItem)
        }
    }

    /// Resolves the input anchor without letting a slow focused app delay the
    /// indicator: whichever finishes first wins — the AX resolution or the
    /// deadline. On timeout the caller falls back to the mouse position; the
    /// late AX result is simply discarded.
    private static func resolveAnchorPoint(timeoutNanoseconds: UInt64) async -> NSPoint? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSPoint?, Never>) in
            let gate = AnchorGate(continuation)
            Task.detached {
                let point = FocusUtils.getInputAnchorPoint()
                await gate.resume(point)
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                await gate.resume(nil)
            }
        }
    }
    
    private actor AnchorGate {
        private var continuation: CheckedContinuation<NSPoint?, Never>?
        
        init(_ continuation: CheckedContinuation<NSPoint?, Never>) {
            self.continuation = continuation
        }
        
        func resume(_ value: NSPoint?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
    
    private func handleKeyUp() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        
        let holdToRecordEnabled = AppPreferences.shared.holdToRecord
        
        Task { @MainActor in
            if holdToRecordEnabled && self.holdMode && self.activeVm != nil {
                IndicatorWindowManager.shared.stopRecording()
            }
            self.holdMode = false
        }
    }
}
