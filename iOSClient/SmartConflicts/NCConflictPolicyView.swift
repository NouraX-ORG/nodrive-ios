// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

/// The row "If a file is already in NoDrive" of the Auto upload screen: title, the current choice on the right.
/// A tap opens the list of the four choices.
struct NCConflictPolicySection: View {
    let account: String
    @State private var policy: NCConflictPolicy

    init(account: String) {
        self.account = account
        _policy = State(initialValue: NCConflictPolicyStore().policy(account: account))
    }

    var body: some View {
        Section(content: {
            NavigationLink(destination: NCConflictPolicyList(account: account, policy: $policy)) {
                HStack {
                    Image(systemName: "doc.on.doc")
                        .font(.icon())
                        .frame(width: 26)
                        .foregroundColor(Color(NCBrandColor.shared.iconImageColor))

                    Text(NCConflictPolicy.settingTitle)
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text(policy.title)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .accessibilityIdentifier("nodriveConflictRow")
        })
        .onAppear {
            // The list screen writes the choice; read it again when this screen comes back.
            policy = NCConflictPolicyStore().policy(account: account)
        }
    }
}

/// The four choices. Smart has its summary line. There is no "Ask me every time": Auto upload runs in the
/// background.
struct NCConflictPolicyList: View {
    let account: String
    @Binding var policy: NCConflictPolicy

    var body: some View {
        Form {
            Section(content: {
                ForEach(NCConflictPolicy.allCases, id: \.rawValue) { choice in
                    Button {
                        NCConflictPolicyStore().setPolicy(choice, account: account)
                        policy = choice
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(choice.title)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                if let summary = choice.summary {
                                    Text(summary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if policy == choice {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color(NCBrandColor.shared.getElement(account: account)))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(choice.rowIdentifier)
                    .accessibilityAddTraits(policy == choice ? .isSelected : [])
                }
            })
        }
        .navigationTitle(NCConflictPolicy.settingTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}
