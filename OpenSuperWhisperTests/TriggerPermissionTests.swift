import AVFoundation
import Combine
import XCTest
@testable import OpenSuperWhisper

private final class MockPermissionSystem {
    var microphoneStatus: AVAuthorizationStatus = .notDetermined
    var microphoneRequestResult = false
    var microphoneRequestCount = 0
    var accessibilityTrusted = false
    var inputDecision: InputMonitoringDecision = .notDetermined
    var inputPreflightGranted = false
    var inputRequestResult = false
    var inputRequestCount = 0
    var onInputRequest: (() -> Void)?
    var onOpenSystemSettings: ((URL) -> Void)?

    func makeClient() -> PermissionClient {
        PermissionClient(
            microphoneAuthorizationStatus: { self.microphoneStatus },
            requestMicrophoneAccess: { completion in
                self.microphoneRequestCount += 1
                completion(self.microphoneRequestResult)
            },
            isAccessibilityTrusted: { self.accessibilityTrusted },
            inputMonitoringDecision: { self.inputDecision },
            preflightInputMonitoringAccess: { self.inputPreflightGranted },
            requestInputMonitoringAccess: {
                self.inputRequestCount += 1
                self.onInputRequest?()
                return self.inputRequestResult
            },
            openSystemSettings: { self.onOpenSystemSettings?($0) }
        )
    }
}

@MainActor
final class TriggerPermissionTests: XCTestCase {
    func testPermissionAbsentKeepsRegularShortcutAndTranscriptionAvailableWithoutPrompt() async throws {
        let system = MockPermissionSystem()
        system.inputDecision = .denied
        let manager = makeManager(system)

        await refresh(manager)

        XCTAssertEqual(system.inputRequestCount, 0)
        XCTAssertEqual(manager.inputMonitoringPermissionState, .denied)
        XCTAssertEqual(
            ShortcutManager.resolveRecordingTrigger(
                modifierKey: .rightOption,
                mouseButton: .none,
                accessibilityGranted: false,
                inputMonitoringState: manager.inputMonitoringPermissionState,
                keyCombinationAssigned: true
            ),
            .keyCombination
        )

        let service = TranscriptionService(engine: NamedTestEngine("transcription available"))
        let text = try await service.transcribeAudio(
            url: URL(fileURLWithPath: "/unused.wav"),
            settings: Settings()
        )

        XCTAssertEqual(text, "transcription available")
        XCTAssertEqual(system.inputRequestCount, 0)
    }

    func testEnablingModifierTriggerRequestsInputMonitoringOnce() async {
        let system = MockPermissionSystem()
        system.inputRequestResult = false
        system.onInputRequest = { system.inputDecision = .denied }
        let manager = makeManager(system)

        let denied = expectation(description: "denied")
        let cancellable = manager.$inputMonitoringPermissionState
            .filter { $0 == .denied }
            .sink { _ in denied.fulfill() }

        manager.requestInputMonitoringPermissionIfNeeded()
        manager.requestInputMonitoringPermissionIfNeeded()
        await fulfillment(of: [denied], timeout: 1)
        manager.requestInputMonitoringPermissionIfNeeded()

        XCTAssertEqual(system.inputRequestCount, 1)
        withExtendedLifetime(cancellable) {}
    }

    func testInputMonitoringGrantBecomesActive() async {
        let system = MockPermissionSystem()
        system.inputRequestResult = true
        system.onInputRequest = {
            system.inputDecision = .granted
            system.inputPreflightGranted = true
        }
        let manager = makeManager(system)

        await requestInputMonitoring(manager, expecting: .granted)

        XCTAssertTrue(manager.isInputMonitoringPermissionGranted)
        XCTAssertEqual(system.inputRequestCount, 1)
    }

    func testInputMonitoringDenialUsesInputMonitoringSettingsRecovery() async {
        let system = MockPermissionSystem()
        system.inputRequestResult = false
        system.onInputRequest = { system.inputDecision = .denied }
        let manager = makeManager(system)
        await requestInputMonitoring(manager, expecting: .denied)

        let opened = expectation(description: "settings opened")
        system.onOpenSystemSettings = { url in
            XCTAssertEqual(url, Permission.inputMonitoring.systemSettingsURL)
            XCTAssertTrue(url.absoluteString.contains("Privacy_ListenEvent"))
            opened.fulfill()
        }
        manager.requestInputMonitoringPermissionOrOpenSystemPreferences()
        await fulfillment(of: [opened], timeout: 1)

        XCTAssertEqual(system.inputRequestCount, 1)
    }

    func testInputMonitoringGrantReportsRestartRequiredUntilFreshProcessPreflight() async {
        let system = MockPermissionSystem()
        system.inputRequestResult = true
        system.onInputRequest = {
            system.inputDecision = .granted
            system.inputPreflightGranted = false
        }
        let manager = makeManager(system)

        await requestInputMonitoring(manager, expecting: .restartRequired)
        XCTAssertFalse(manager.isInputMonitoringPermissionGranted)

        system.inputPreflightGranted = true
        let relaunchedManager = makeManager(system)
        await refresh(relaunchedManager)
        XCTAssertEqual(relaunchedManager.inputMonitoringPermissionState, .granted)
    }

    func testAccessibilityAndMicrophoneChecksRemainIndependent() async {
        let firstSystem = MockPermissionSystem()
        firstSystem.microphoneStatus = .authorized
        firstSystem.accessibilityTrusted = false
        firstSystem.inputDecision = .denied
        let firstManager = makeManager(firstSystem)
        await refresh(firstManager)

        XCTAssertTrue(firstManager.isMicrophonePermissionGranted)
        XCTAssertFalse(firstManager.isAccessibilityPermissionGranted)
        XCTAssertEqual(firstManager.inputMonitoringPermissionState, .denied)

        let secondSystem = MockPermissionSystem()
        secondSystem.microphoneStatus = .denied
        secondSystem.accessibilityTrusted = true
        secondSystem.inputDecision = .granted
        secondSystem.inputPreflightGranted = true
        let secondManager = makeManager(secondSystem)
        await refresh(secondManager)

        XCTAssertFalse(secondManager.isMicrophonePermissionGranted)
        XCTAssertTrue(secondManager.isAccessibilityPermissionGranted)
        XCTAssertEqual(secondManager.inputMonitoringPermissionState, .granted)

        XCTAssertEqual(
            ShortcutManager.resolveRecordingTrigger(
                modifierKey: .rightOption,
                mouseButton: .none,
                accessibilityGranted: false,
                inputMonitoringState: .granted,
                keyCombinationAssigned: true
            ),
            .modifier(.rightOption)
        )
        XCTAssertEqual(
            ShortcutManager.resolveRecordingTrigger(
                modifierKey: .rightOption,
                mouseButton: .none,
                accessibilityGranted: true,
                inputMonitoringState: .denied,
                keyCombinationAssigned: true
            ),
            .keyCombination
        )
        XCTAssertEqual(
            ShortcutManager.resolveRecordingTrigger(
                modifierKey: .none,
                mouseButton: .middle,
                accessibilityGranted: true,
                inputMonitoringState: .denied,
                keyCombinationAssigned: true
            ),
            .mouseButton(.middle)
        )
    }

    func testUnavailableModifierWithClearedFallbackReportsNoGlobalTrigger() {
        XCTAssertEqual(
            ShortcutManager.resolveRecordingTrigger(
                modifierKey: .rightOption,
                mouseButton: .none,
                accessibilityGranted: false,
                inputMonitoringState: .denied,
                keyCombinationAssigned: false
            ),
            .unavailable
        )
    }

    func testPermissionGrantAndRevocationReconfigureTriggerOnce() {
        let permissions = CurrentValueSubject<Int, Never>(0)
        let manager = ShortcutManager(registerShortcuts: false)
        var changes = 0
        manager.observeTriggerPermissions(permissions.eraseToAnyPublisher()) { changes += 1 }
        permissions.send(0)
        XCTAssertEqual(changes, 0)
        permissions.send(1)
        permissions.send(1)
        XCTAssertEqual(changes, 1)
        permissions.send(3)
        permissions.send(0)
        permissions.send(3)
        XCTAssertEqual(changes, 4)
    }

    private func makeManager(_ system: MockPermissionSystem) -> PermissionsManager {
        PermissionsManager(
            client: system.makeClient(),
            monitorSystemChanges: false,
            checkQueue: DispatchQueue(label: "test.permissions.\(UUID().uuidString)")
        )
    }

    private func refresh(_ manager: PermissionsManager) async {
        let checked = expectation(description: "permissions checked")
        let cancellable = manager.$hasCompletedInitialCheck
            .filter { $0 }
            .sink { _ in checked.fulfill() }
        manager.checkAllPermissions()
        await fulfillment(of: [checked], timeout: 1)
        withExtendedLifetime(cancellable) {}
    }

    private func requestInputMonitoring(
        _ manager: PermissionsManager,
        expecting state: InputMonitoringPermissionState
    ) async {
        let changed = expectation(description: "input monitoring state changed")
        let cancellable = manager.$inputMonitoringPermissionState
            .dropFirst()
            .filter { $0 == state }
            .sink { _ in changed.fulfill() }
        manager.requestInputMonitoringPermissionIfNeeded()
        await fulfillment(of: [changed], timeout: 1)
        withExtendedLifetime(cancellable) {}
    }
}
