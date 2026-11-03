// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The sheet of "Add to iPhone Calendar & Contacts": one screen per phase of `NCDeviceSyncFlow`.
struct NCDeviceSyncFlowView: View {
    @State private var flow: NCDeviceSyncFlow
    @Environment(\.dismiss) private var dismiss

    init(account: String) {
        _flow = State(initialValue: NCDeviceSyncFlow(dependencies: .live(account: account)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString(closeIsDone ? "_close_" : "_cancel_", comment: "")) {
                        flow.cancel()
                        dismiss()
                    }
                    .accessibilityIdentifier("devicesyncCancel")
                }
            }
        }
        .interactiveDismissDisabled(flow.phase == .waiting || flow.phase == .opening)
        .onDisappear {
            // The system's sign-in sheet covers this one while the flow waits: that is not a close.
            if flow.phase == .intro || flow.phase == .installSteps {
                flow.cancel()
            }
        }
    }

    private var closeIsDone: Bool {
        flow.phase == .done || flow.phase == .undone
    }

    private var title: String {
        switch flow.phase {
        case .installSteps: return NCDeviceSync.text("_nodrive_devicesync_install_title_")
        default: return NCDeviceSync.text("_nodrive_devicesync_step1_title_")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .intro:
            message("_nodrive_devicesync_step1_", id: "devicesyncStep1")
            primary("_nodrive_devicesync_continue_", id: "devicesyncContinue") { flow.begin() }
        case .waiting:
            HStack(spacing: 12) {
                ProgressView()
                Text(NCDeviceSync.text("_nodrive_devicesync_waiting_"))
                    .font(.body)
                    .accessibilityIdentifier("devicesyncWaiting")
            }
            secondary("_nodrive_devicesync_reopen_", id: "devicesyncReopen") { flow.reopenSignIn() }
        case .timedOut:
            message("_nodrive_devicesync_timeout_", id: "devicesyncTimeout")
            primary("_nodrive_devicesync_try_again_", id: "devicesyncTryAgain") { flow.begin() }
        case .refused:
            message("_nodrive_devicesync_refused_", id: "devicesyncRefused")
            primary("_nodrive_devicesync_try_again_", id: "devicesyncTryAgain") { flow.begin() }
        case .failed:
            message("_nodrive_devicesync_failed_", id: "devicesyncFailed")
            primary("_nodrive_devicesync_try_again_", id: "devicesyncTryAgain") { flow.begin() }
        case .opening:
            HStack(spacing: 12) {
                ProgressView()
                Text(NCDeviceSync.text("_nodrive_devicesync_opening_"))
                    .font(.body)
                    .accessibilityIdentifier("devicesyncOpening")
            }
        case .installSteps:
            message("_nodrive_devicesync_install_steps_", id: "devicesyncInstallSteps")
            primary("_nodrive_devicesync_installed_", id: "devicesyncInstalled") { flow.installed() }
            secondary("_nodrive_devicesync_didnt_work_", id: "devicesyncDidntWork") { flow.didntWork() }
            secondary("_nodrive_devicesync_open_safari_", id: "devicesyncOpenSafari") {
                Task { await flow.openSafari() }
            }
        case .done:
            message("_nodrive_devicesync_done_", id: "devicesyncDone")
            primary("_nodrive_devicesync_done_button_", id: "devicesyncClose") {
                flow.cancel()
                dismiss()
            }
        case .undone:
            message("_nodrive_devicesync_undone_", id: "devicesyncUndone")
            primary("_nodrive_devicesync_try_again_", id: "devicesyncTryAgain") { flow.begin() }
        case .expired:
            message("_nodrive_devicesync_expired_", id: "devicesyncExpired")
            primary("_nodrive_devicesync_try_again_", id: "devicesyncTryAgain") { flow.begin() }
        }
    }

    private func message(_ key: String, id: String) -> some View {
        Text(NCDeviceSync.text(key))
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(id)
    }

    private func primary(_ key: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(NCDeviceSync.text(key))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityIdentifier(id)
    }

    private func secondary(_ key: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(NCDeviceSync.text(key))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityIdentifier(id)
    }
}
