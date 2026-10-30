// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

/// The section of Settings -> Advanced: the switch "Send problem reports to Nourax" (off by default) and the row
/// "Report a problem" (always works, also with the switch off).
struct NCProblemReportsSection: View {
    let controller: NCMainTabBarController?
    @State private var enabled: Bool

    init(controller: NCMainTabBarController?) {
        self.controller = controller
        _enabled = State(initialValue: NCProblemReports.shared.isEnabled)
    }

    var body: some View {
        Section(content: {
            Toggle(NCProblemReports.text("_nodrive_reports_switch_"), isOn: Binding(
                get: { enabled },
                set: { value in
                    enabled = value
                    NCProblemReports.shared.setEnabled(value)
                }))
                .font(.body)
                .tint(Color(NCBrandColor.shared.getElement(account: NCSession.shared.getSession(controller: controller).account)))
                .accessibilityIdentifier("nodriveReportsSwitch")

            NavigationLink(destination: LazyView {
                NCProblemReportView()
            }) {
                HStack {
                    Image(systemName: "exclamationmark.bubble")
                        .font(.icon())
                        .frame(width: 26)
                        .foregroundColor(Color(NCBrandColor.shared.iconImageColor))
                    Text(NCProblemReports.text("_nodrive_reports_report_"))
                        .font(.body)
                }
            }
            .accessibilityIdentifier("nodriveReportProblem")
        }, footer: {
            Text(NCProblemReports.text("_nodrive_reports_summary_"))
                .font(.footnote)
        })
    }
}

/// "Report a problem": an optional note, the link "What's included", and Send.
struct NCProblemReportView: View {
    @State private var note = ""
    @State private var sending = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField(NCProblemReports.text("_nodrive_reports_prompt_"), text: $note, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.body)
                    .accessibilityIdentifier("nodriveReportNote")
            }
            Section {
                NavigationLink(destination: NCProblemReportIncludedView()) {
                    Text(NCProblemReports.text("_nodrive_reports_included_link_"))
                        .font(.body)
                }
                .accessibilityIdentifier("nodriveReportIncluded")
            }
        }
        .navigationTitle(NCProblemReports.text("_nodrive_reports_report_"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("_cancel_", comment: "")) {
                    dismiss()
                }
                .disabled(sending)
            }
            ToolbarItem(placement: .confirmationAction) {
                if sending {
                    ProgressView()
                } else {
                    Button(NCProblemReports.text("_nodrive_reports_send_")) {
                        send()
                    }
                    .accessibilityIdentifier("nodriveReportSend")
                }
            }
        }
    }

    private func send() {
        sending = true
        let text = note
        Task { @MainActor in
            _ = await NCProblemReports.shared.sendManual(note: text)
            sending = false
            dismiss()
        }
    }
}

/// "What's included", in plain words.
struct NCProblemReportIncludedView: View {
    private let items = ["_nodrive_reports_included_version_",
                         "_nodrive_reports_included_device_",
                         "_nodrive_reports_included_time_",
                         "_nodrive_reports_included_note_",
                         "_nodrive_reports_included_crash_",
                         "_nodrive_reports_included_logs_"]

    var body: some View {
        Form {
            Section(content: {
                ForEach(items, id: \.self) { key in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        Text(NCProblemReports.text(key))
                            .font(.body)
                    }
                    .accessibilityElement(children: .combine)
                }
            }, header: {
                Text(NCProblemReports.text("_nodrive_reports_included_header_"))
                    .font(.headline)
            }, footer: {
                Text(NCProblemReports.text("_nodrive_reports_included_footer_"))
                    .font(.footnote)
            })
        }
        .navigationTitle(NCProblemReports.text("_nodrive_reports_included_link_"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("nodriveReportIncludedList")
    }
}
