import SwiftUI

struct InputMonitoringPermissionNotice: View {
    @ObservedObject var permissionsManager: PermissionsManager
    @ObservedObject private var shortcutManager = ShortcutManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch permissionsManager.inputMonitoringPermissionState {
            case .granted:
                Label("Input Monitoring granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(Self.activationDescription(for: shortcutManager.activeRecordingTrigger))
                    .foregroundColor(.secondary)
            case .notDetermined:
                Label("Input Monitoring not granted yet", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("macOS requires it only for the single modifier key trigger. In-app recording remains available.")
                    .foregroundColor(.secondary)
                Text(Self.activationDescription(for: shortcutManager.activeRecordingTrigger))
                    .foregroundColor(.secondary)
                Button("Grant Input Monitoring") {
                    permissionsManager.requestInputMonitoringPermissionOrOpenSystemPreferences()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .denied:
                Label("Input Monitoring not granted", systemImage: "xmark.circle.fill")
                    .foregroundColor(.orange)
                Text("The single modifier key trigger is inactive. Allow OpenSuperWhisper in Privacy & Security → Input Monitoring to enable it.")
                    .foregroundColor(.secondary)
                Text(Self.activationDescription(for: shortcutManager.activeRecordingTrigger))
                    .foregroundColor(.secondary)
                settingsButton
            case .restartRequired:
                Label("Restart required", systemImage: "arrow.clockwise.circle.fill")
                    .foregroundColor(.orange)
                Text("Input Monitoring is enabled in System Settings. Quit and reopen OpenSuperWhisper to activate the single modifier key trigger.")
                    .foregroundColor(.secondary)
                Text(Self.activationDescription(for: shortcutManager.activeRecordingTrigger))
                    .foregroundColor(.secondary)
                settingsButton
            }
        }
        .font(.caption)
        .padding(.top, 4)
    }

    static func activationDescription(for trigger: RecordingTrigger) -> String {
        switch trigger {
        case .modifier:
            return "The single modifier key trigger is active."
        case .keyCombination:
            return "The regular key combination is active instead."
        case .mouseButton:
            return "The mouse-button trigger is active instead."
        case .unavailable:
            return "No global trigger is active. Configure a key combination in Shortcuts."
        }
    }

    private var settingsButton: some View {
        Button("Open Input Monitoring Settings") {
            permissionsManager.openInputMonitoringSystemPreferences()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
