import SwiftUI
import OpenBridgeUI

struct MeetingCloudPrivacyNotice: View {
    let provider: String
    var onSettings: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Cloud privacy", systemImage: "hand.raised").font(OpenBridgeTypography.body(size: 13, weight: .semibold))
            Text("Cloud sends text to your configured AI provider. If privacy matters, choose a provider with suitable private-processing, retention and no-training policies. OpenBridge cannot guarantee a provider’s privacy practices. Charges may apply.")
                .font(OpenBridgeTypography.metadata).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(provider).font(OpenBridgeTypography.metadata).lineLimit(2)
                Spacer(minLength: 4)
                Button("Settings", action: onSettings).buttonStyle(.link)
                Link("Privacy help", destination: URL(string: "https://openrouter.ai/docs/guides/privacy/provider-logging")!)
                    .font(OpenBridgeTypography.metadata)
            }
        }.foregroundStyle(OpenBridgeTheme.mutedInk).padding(12)
            .background(OpenBridgeTheme.coolSurface, in: RoundedRectangle(cornerRadius: 8))
    }
}

extension Notification.Name {
    static let manageMeetingResearch = Notification.Name("studio.lunr.openbridge.manageMeetingResearch")
}

struct MeetingResearchPermissionView: View {
    @ObservedObject var controller: MeetingResearchController
    @ObservedObject var providerSettings: ProviderSettingsController
    let onSettings: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [MeetingResearchController.PermissionRow] = []
    @State private var pending: [MeetingResearchController.PermissionRow] = []
    @State private var pendingAllowed = true
    @State private var confirming = false
    @State private var busy = false
    @State private var status: String?
    @State private var expectedProvider: ProviderConfiguration?

    private var providerLabel: String { "\(providerSettings.settings.providerLabel) · \(providerSettings.settings.model)" }
    private var ready: Bool {
        providerSettings.hasCurrentTestAttestation && providerSettings.settings.mayStartExternalRequest(hasCredential: providerSettings.hasCredential)
    }
    private var saved: [MeetingResearchController.PermissionRow] { rows.filter { !$0.isCurrent } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Cloud research access").font(OpenBridgeTypography.sectionTitle); Spacer(); Button("Done") { dismiss() } }
            Text("Research sends selected excerpts only when you submit a question. These choices never enable transcript cleanup.")
                .font(OpenBridgeTypography.body).foregroundStyle(.secondary)
            MeetingCloudPrivacyNotice(provider: providerLabel) { dismiss(); onSettings() }
            if !ready {
                Text("Configure your cloud provider and pass Test Connection in Settings before enabling research.")
                    .font(OpenBridgeTypography.body).foregroundStyle(.secondary)
            }
            if let current = rows.first(where: \.isCurrent) {
                Text("This meeting").font(.headline)
                permissionRow(current)
            }
            Divider()
            HStack {
                Text("Saved meetings (\(saved.count))").font(.headline)
                Spacer()
                Button("Approve existing saved meetings") { confirm(saved, allowed: true) }
                    .disabled(saved.isEmpty || !ready)
            }
            Text("Includes eligible meetings across workspaces. Future recordings are not included. Deleted, expired and never-store transcripts cannot be searched.")
                .font(OpenBridgeTypography.metadata).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(saved) { permissionRow($0) }
                }
            }.frame(minHeight: 100, maxHeight: 240)
            if let status { Text(status).font(OpenBridgeTypography.body).foregroundStyle(.secondary) }
            if busy { ProgressView("Saving research permissions…").controlSize(.small) }
        }.padding(24).frame(width: 620).disabled(busy)
            .task { rows = await controller.permissionRows() }
            .alert(pendingAllowed ? "Enable cloud research?" : "Turn off cloud research?", isPresented: $confirming) {
                Button("Cancel", role: .cancel) { pending = [] }
                Button(pendingAllowed ? "Enable research" : "Turn off", role: pendingAllowed ? nil : .destructive) {
                    let ids = pending.map(\.id), allowed = pendingAllowed, expected = expectedProvider
                    busy = true
                    Task {
                        let failed = await controller.applyResearchPermission(ids: ids, allowed: allowed, expectedProvider: expected)
                        rows = await controller.permissionRows(); busy = false
                        status = failed.isEmpty ? "Research permissions updated. Submit or retry a question when you are ready."
                            : "Could not update \(failed.count) meeting(s). Nothing was sent. Check provider settings and try again."
                        pending = []
                    }
                }
            } message: {
                Text(pendingAllowed
                    ? "Allow questions, relevant transcript excerpts and recent conversation from these \(pending.count) meeting(s) to be sent to \(providerLabel)? Includes discussion already recorded. Conversations are saved locally with the meeting and follow its retention and deletion settings. No audio, no automatic requests, no cleanup, and no future meetings.\n\n\(pending.prefix(8).map(\.title).joined(separator: "\n"))\(pending.count > 8 ? "\n…and \(pending.count - 8) more shown in the list." : "")"
                    : "Stop new research requests using these meetings and cancel affected pending questions. Text already sent cannot be recalled. Cleanup settings are unchanged.")
            }
    }

    private func confirm(_ targets: [MeetingResearchController.PermissionRow], allowed: Bool) {
        pending = targets; pendingAllowed = allowed; expectedProvider = providerSettings.settings.configuration; confirming = true
    }

    private func permissionRow(_ row: MeetingResearchController.PermissionRow) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.callout.weight(.medium)).lineLimit(2)
                Text(row.date.formatted(date: .abbreviated, time: .shortened)).font(OpenBridgeTypography.metadata).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(row.allowed ? "Research on" : "Research off").font(OpenBridgeTypography.metadata).foregroundStyle(.secondary)
            Button(row.allowed ? "Turn off" : "Enable") { confirm([row], allowed: !row.allowed) }
                .disabled(!row.allowed && !ready).controlSize(.small)
        }
    }
}
