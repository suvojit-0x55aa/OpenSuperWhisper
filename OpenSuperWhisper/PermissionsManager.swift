import AVFoundation
import AppKit
import Foundation
import IOKit.hid

enum Permission {
    case microphone
    case accessibility
    case inputMonitoring

    var systemSettingsURL: URL {
        let anchor: String
        switch self {
        case .microphone:
            anchor = "Privacy_Microphone"
        case .accessibility:
            anchor = "Privacy_Accessibility"
        case .inputMonitoring:
            anchor = "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)")!
    }
}

enum InputMonitoringDecision: Equatable {
    case notDetermined
    case denied
    case granted
}

enum InputMonitoringPermissionState: Equatable {
    case notDetermined
    case denied
    case restartRequired
    case granted

    static func resolve(preflightGranted: Bool, decision: InputMonitoringDecision) -> Self {
        if preflightGranted {
            return .granted
        }
        switch decision {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .granted:
            // TCC has recorded the grant, but this process does not have it yet.
            return .restartRequired
        }
    }
}

struct PermissionClient {
    var microphoneAuthorizationStatus: () -> AVAuthorizationStatus
    var requestMicrophoneAccess: (@escaping (Bool) -> Void) -> Void
    var isAccessibilityTrusted: () -> Bool
    var inputMonitoringDecision: () -> InputMonitoringDecision
    var preflightInputMonitoringAccess: () -> Bool
    var requestInputMonitoringAccess: () -> Bool
    var openSystemSettings: (URL) -> Void

    static let live = PermissionClient(
        microphoneAuthorizationStatus: { AVCaptureDevice.authorizationStatus(for: .audio) },
        requestMicrophoneAccess: { completion in
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        },
        isAccessibilityTrusted: { AXIsProcessTrusted() },
        inputMonitoringDecision: {
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted:
                return .granted
            case kIOHIDAccessTypeDenied:
                return .denied
            default:
                return .notDetermined
            }
        },
        // The modifier trigger is a listen-only CGEvent tap, so use the
        // matching Core Graphics preflight/request pair rather than AX trust.
        preflightInputMonitoringAccess: { CGPreflightListenEventAccess() },
        requestInputMonitoringAccess: { CGRequestListenEventAccess() },
        openSystemSettings: { url in _ = NSWorkspace.shared.open(url) }
    )
}

class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published private(set) var isMicrophonePermissionGranted = false
    @Published private(set) var isAccessibilityPermissionGranted = false
    @Published private(set) var inputMonitoringPermissionState: InputMonitoringPermissionState = .notDetermined
    @Published private(set) var hasCompletedInitialCheck = false

    var isInputMonitoringPermissionGranted: Bool {
        inputMonitoringPermissionState == .granted
    }

    private let client: PermissionClient
    private let checkQueue: DispatchQueue
    private var isCheckInFlight = false
    private var isInputMonitoringRequestInFlight = false
    private var hasRequestedInputMonitoring = false
    private var permissionCheckTimer: Timer?
    private var windowObservers: [NSObjectProtocol] = []
    private var isIndicatorSessionActive = false

    init(
        client: PermissionClient = .live,
        monitorSystemChanges: Bool = true,
        checkQueue: DispatchQueue = DispatchQueue(
            label: "com.opensuperwhisper.permissions",
            qos: .utility
        )
    ) {
        self.client = client
        self.checkQueue = checkQueue

        guard monitorSystemChanges else { return }
        checkAllPermissions()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityPermissionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        setupWindowObservers()
    }

    deinit {
        stopPermissionChecking()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupWindowObservers() {
        let showObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.startPermissionChecking()
        }
        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopPermissionChecking()
        }
        let hideObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopPermissionChecking()
        }
        let indicatorShowObserver = NotificationCenter.default.addObserver(
            forName: .indicatorWindowWillShow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isIndicatorSessionActive = true
        }
        let indicatorHideObserver = NotificationCenter.default.addObserver(
            forName: .indicatorWindowDidHide,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isIndicatorSessionActive = false
        }

        windowObservers = [
            showObserver,
            closeObserver,
            hideObserver,
            indicatorShowObserver,
            indicatorHideObserver
        ]

        if let window = NSApplication.shared.mainWindow, window.isKeyWindow {
            startPermissionChecking()
        }
    }

    private func startPermissionChecking() {
        guard permissionCheckTimer == nil else { return }
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, !self.isIndicatorSessionActive else { return }
            self.checkAllPermissions()
        }
    }

    private func stopPermissionChecking() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    func checkAllPermissions() {
        guard !isCheckInFlight else { return }
        isCheckInFlight = true

        checkQueue.async { [weak self] in
            guard let self else { return }
            let microphone = self.client.microphoneAuthorizationStatus() == .authorized
            let accessibility = self.client.isAccessibilityTrusted()
            let inputMonitoring = self.currentInputMonitoringState()

            DispatchQueue.main.async {
                self.isCheckInFlight = false
                self.isMicrophonePermissionGranted = microphone
                self.isAccessibilityPermissionGranted = accessibility
                self.inputMonitoringPermissionState = self.mergedInputMonitoringState(inputMonitoring)
                self.hasCompletedInitialCheck = true
            }
        }
    }

    func checkMicrophonePermission() {
        checkQueue.async { [weak self] in
            guard let self else { return }
            let granted = self.client.microphoneAuthorizationStatus() == .authorized
            DispatchQueue.main.async {
                self.isMicrophonePermissionGranted = granted
            }
        }
    }

    func checkAccessibilityPermission() {
        checkQueue.async { [weak self] in
            guard let self else { return }
            let granted = self.client.isAccessibilityTrusted()
            DispatchQueue.main.async {
                self.isAccessibilityPermissionGranted = granted
            }
        }
    }

    func checkInputMonitoringPermission() {
        checkQueue.async { [weak self] in
            guard let self else { return }
            let state = self.currentInputMonitoringState()
            DispatchQueue.main.async {
                self.inputMonitoringPermissionState = self.mergedInputMonitoringState(state)
            }
        }
    }

    /// Called only when the user enables the single-modifier trigger.
    /// Previously denied requests remain denied until the explicit recovery action.
    func requestInputMonitoringPermissionIfNeeded() {
        requestInputMonitoring(openSettingsWhenUnavailable: false)
    }

    func requestInputMonitoringPermissionOrOpenSystemPreferences() {
        requestInputMonitoring(openSettingsWhenUnavailable: true)
    }

    func openInputMonitoringSystemPreferences() {
        openSystemPreferences(for: .inputMonitoring)
    }

    private func requestInputMonitoring(openSettingsWhenUnavailable: Bool) {
        switch inputMonitoringPermissionState {
        case .granted:
            return
        case .denied, .restartRequired:
            if openSettingsWhenUnavailable {
                openSystemPreferences(for: .inputMonitoring)
            }
            return
        case .notDetermined:
            break
        }

        guard !isInputMonitoringRequestInFlight, !hasRequestedInputMonitoring else { return }
        isInputMonitoringRequestInFlight = true

        checkQueue.async { [weak self] in
            guard let self else { return }
            let currentState = self.currentInputMonitoringState()

            guard currentState == .notDetermined else {
                DispatchQueue.main.async {
                    self.isInputMonitoringRequestInFlight = false
                    self.inputMonitoringPermissionState = currentState
                    if openSettingsWhenUnavailable,
                       currentState == .denied || currentState == .restartRequired {
                        self.openSystemPreferences(for: .inputMonitoring)
                    }
                }
                return
            }

            let requestGranted = self.client.requestInputMonitoringAccess()
            let stateAfterRequest = self.currentInputMonitoringState()

            DispatchQueue.main.async {
                self.isInputMonitoringRequestInFlight = false
                self.hasRequestedInputMonitoring = true
                if requestGranted {
                    self.inputMonitoringPermissionState = stateAfterRequest == .granted
                        ? .granted
                        : .restartRequired
                } else {
                    self.inputMonitoringPermissionState = stateAfterRequest == .notDetermined
                        ? .denied
                        : stateAfterRequest
                }
            }
        }
    }

    private func currentInputMonitoringState() -> InputMonitoringPermissionState {
        InputMonitoringPermissionState.resolve(
            preflightGranted: client.preflightInputMonitoringAccess(),
            decision: client.inputMonitoringDecision()
        )
    }

    private func mergedInputMonitoringState(
        _ detectedState: InputMonitoringPermissionState
    ) -> InputMonitoringPermissionState {
        guard detectedState == .notDetermined, hasRequestedInputMonitoring else {
            return detectedState
        }
        return inputMonitoringPermissionState == .restartRequired ? .restartRequired : .denied
    }

    func requestAccessibilityPermissionOrOpenSystemPreferences() {
        if client.isAccessibilityTrusted() {
            isAccessibilityPermissionGranted = true
        } else {
            openSystemPreferences(for: .accessibility)
        }
    }

    func requestMicrophonePermissionOrOpenSystemPreferences() {
        switch client.microphoneAuthorizationStatus() {
        case .notDetermined:
            client.requestMicrophoneAccess { [weak self] granted in
                DispatchQueue.main.async {
                    self?.isMicrophonePermissionGranted = granted
                }
            }
        case .authorized:
            isMicrophonePermissionGranted = true
        default:
            openSystemPreferences(for: .microphone)
        }
    }

    @objc private func accessibilityPermissionChanged() {
        checkAccessibilityPermission()
    }

    func openSystemPreferences(for permission: Permission) {
        let url = permission.systemSettingsURL
        DispatchQueue.main.async { [client] in
            client.openSystemSettings(url)
        }
    }
}
