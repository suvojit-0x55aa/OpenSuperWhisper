import SwiftUI

struct InputMonitoringPermissionNotice: View {
    @ObservedObject var permissionsManager: PermissionsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch permissionsManager.inputMonitoringPermissionState {
            case .granted:
                Label("Input Monitoring granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("The single modifier key trigger is active.")
                    .foregroundColor(.secondary)
            case .notDetermined:
                Label("Input Monitoring not granted yet", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("macOS requires it only for the single modifier key trigger. The regular key combination and in-app recording remain available.")
                    .foregroundColor(.secondary)
                Button("Grant Input Monitoring") {
                    permissionsManager.requestInputMonitoringPermissionOrOpenSystemPreferences()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .denied:
                Label("Input Monitoring not granted", systemImage: "xmark.circle.fill")
                    .foregroundColor(.orange)
                Text("The single modifier key trigger is inactive. Use the regular key combination, or allow OpenSuperWhisper in Privacy & Security → Input Monitoring.")
                    .foregroundColor(.secondary)
                settingsButton
            case .restartRequired:
                Label("Restart required", systemImage: "arrow.clockwise.circle.fill")
                    .foregroundColor(.orange)
                Text("Input Monitoring is enabled in System Settings. Quit and reopen OpenSuperWhisper to activate the single modifier key trigger.")
                    .foregroundColor(.secondary)
                settingsButton
            }
        }
        .font(.caption)
        .padding(.top, 4)
    }

    private var settingsButton: some View {
        Button("Open Input Monitoring Settings") {
            permissionsManager.openInputMonitoringSystemPreferences()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
