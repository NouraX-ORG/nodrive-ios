// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The button "Add to iPhone Calendar & Contacts" and the sheet it opens. Disabled without a signed-in account.
struct NCDeviceSyncButton: View {
    let account: String
    var showsIcon = true
    @State private var showFlow = false

    private var signedIn: Bool {
        !account.isEmpty && NCWorkspaceSession.credentials(account: account) != nil
    }

    var body: some View {
        Button(action: { showFlow = true }, label: {
            HStack {
                if showsIcon {
                    Image(systemName: "calendar.badge.plus")
                        .font(.icon())
                        .foregroundColor(Color(NCBrandColor.shared.iconImageColor))
                        .frame(width: 39)
                }
                Text(NCDeviceSync.text("_nodrive_devicesync_button_"))
                    .font(.body)
            }
        })
        .tint(Color(NCBrandColor.shared.textColor))
        .disabled(!signedIn)
        .accessibilityIdentifier("devicesyncButton")
        .sheet(isPresented: $showFlow) {
            NCDeviceSyncFlowView(account: account)
        }
    }
}

/// The section "Calendar and contacts" of Settings. It takes the place of upstream's section, which fetched the server's
/// profile (no password in it, and named after the server's theme); that one is switched off with the brand option.
struct NCDeviceSyncSection: View {
    let controller: NCMainTabBarController?

    private var account: String {
        NCSession.shared.getSession(controller: controller).account
    }

    var body: some View {
        Section(content: {
            NCDeviceSyncButton(account: account)
        }, header: {
            Text(NCDeviceSync.text("_nodrive_devicesync_header_"))
                .font(.headline)
        }, footer: {
            VStack(alignment: .leading, spacing: 6) {
                if account.isEmpty || NCWorkspaceSession.credentials(account: account) == nil {
                    Text(NCDeviceSync.text("_nodrive_devicesync_signin_first_"))
                        .font(.footnote)
                }
                Text(NCDeviceSync.text("_nodrive_devicesync_footer_"))
                    .font(.footnote)
            }
        })
        .onAppear {
            NCDeviceSyncUITestHooks.scheduleAccountRemovalIfRequested()
        }
    }
}

/// The same button at the bottom of NoAgenda's Sources screen.
struct NCDeviceSyncSourcesSection: View {
    let account: String

    var body: some View {
        Section(content: {
            NCDeviceSyncButton(account: account, showsIcon: false)
        }, footer: {
            Text(NCDeviceSync.text("_nodrive_devicesync_footer_"))
                .font(.footnote)
        })
    }
}
