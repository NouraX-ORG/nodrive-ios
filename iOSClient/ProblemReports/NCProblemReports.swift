// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import NextcloudKit

/// Problem reports: the switch "Send problem reports to Nourax", the button "Report a problem", the report after
/// a crash or an unclean exit, and the upload to the signed-in account's own server (see NCProblemReportSender).
///
/// Nothing is sent while the switch is off, except the one report the user chose to send. No analytics, no
/// background pings, no third-party SDK; Firebase Crashlytics stays off.
@MainActor
final class NCProblemReports {
    static let shared = NCProblemReports(dependencies: .live())

    /// The switch, in the app group's user defaults (absent = off).
    static let enabledKey = "NoDriveProblemReportsEnabled"

    /// Everything the engine touches outside itself, so the unit tests run it with a fake server and fake screens.
    struct Dependencies {
        /// `Application Support/NoDrive/ProblemReports`: marker, pending exception, MetricKit files, pending zips.
        var directory: URL
        var defaults: UserDefaults
        var build: String
        var shortVersion: String
        /// False in UI-test runs that are not about reports (the relaunches there must not be interrupted).
        var detectionEnabled: Bool
        var now: () -> Date
        var info: () -> NCProblemReportInfo
        /// The signed-in account's server, or nil without an account.
        var transport: () -> NCProblemReportTransport?
        var accountExists: () -> Bool
        /// Reads the log files. It runs on a background task (the folder can be large), so it must not use the main actor.
        var logs: @Sendable () -> [NCProblemReportLogFile]
        /// "NoDrive closed unexpectedly. Send a problem report?" -> true for Send, false for Not now.
        var confirm: () async -> Bool
        /// A small message ("Problem report sent").
        var notify: (String) -> Void
        /// How long to wait for MetricKit after an unclean exit, and for the account's session after a start.
        var metricKitWait: TimeInterval
        var transportWait: TimeInterval
        /// At least this long between two rounds of sending the reports kept on the phone.
        var flushInterval: TimeInterval
    }

    let dependencies: Dependencies
    private var started = false
    private var previousRunUnclean = false
    private var previousRunHandled = false
    private var previousRunReported = false
    /// True while `processPreviousRun` runs: a diagnostic that MetricKit delivers meanwhile stays in the store for it.
    private var processingPreviousRun = false
    /// The start-up step queued by `didBecomeActive`, so a test can wait for it.
    private(set) var previousRunTask: Task<Void, Never>?
    private var lastFlush: Date?
    private var collector: NCMetricKitCollector?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: Switch

    var isEnabled: Bool {
        dependencies.defaults.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ value: Bool) {
        dependencies.defaults.set(value, forKey: Self.enabledKey)
    }

    // MARK: Files

    private var directory: URL { dependencies.directory }
    private var runMarker: NCProblemReportRunMarker { .init(url: directory.appendingPathComponent("run-marker.json")) }
    private var exceptionFile: URL { directory.appendingPathComponent("crash-pending.txt") }
    /// Set at the start when the previous run ended on screen without a normal exit; removed when it is handled.
    /// (A start in the background must not lose the news before the user opens the app.)
    private var uncleanFlag: URL { directory.appendingPathComponent("unclean-pending") }
    private var metricStore: NCMetricKitStore { .init(directory: directory.appendingPathComponent("metrickit", isDirectory: true)) }

    /// Reports the user chose to send (Report a problem, or Send in the question) wait here.
    private func sender(automatic: Bool, transport: NCProblemReportTransport?) -> NCProblemReportSender {
        NCProblemReportSender(transport: transport,
                              pendingDirectory: directory.appendingPathComponent(automatic ? "pending-auto" : "pending", isDirectory: true),
                              workDirectory: directory.appendingPathComponent("work", isDirectory: true),
                              otherPendingDirectory: directory.appendingPathComponent(automatic ? "pending" : "pending-auto", isDirectory: true))
    }

    private func prepareDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: Start

    /// Called once from the app delegate. Installs the crash capture and starts watching the app's state.
    func start() {
        guard !started else { return }
        started = true
        guard dependencies.detectionEnabled else { return }
        prepareDirectory()
        NCProblemReportCrash.installExceptionHandler(writingTo: exceptionFile)
        let collector = NCMetricKitCollector(store: metricStore, build: dependencies.build, shortVersion: dependencies.shortVersion)
        collector.onSaved = { [weak self] in
            Task { @MainActor in await self?.diagnosticArrived() }
        }
        collector.start()
        self.collector = collector
        prepareLaunch()

        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didBecomeActive() }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterBackground() }
        }
        center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willTerminate() }
        }
        // A new sign-in: reports kept on the phone because there was no account are sent now.
        center.addObserver(forName: Notification.Name(NCGlobal.shared.notificationCenterChangeUser), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.flushPending(force: true) }
        }
        NCProblemReportUITestHooks.scheduleIfRequested()
    }

    // MARK: Run marker

    /// Reads what the previous run left behind, then marks this run as "background" until the app is active.
    func prepareLaunch() {
        if runMarker.previousRunEndedUncleanly(currentBuild: dependencies.build) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? Data().write(to: uncleanFlag)
        }
        previousRunUnclean = FileManager.default.fileExists(atPath: uncleanFlag.path)
        runMarker.write(.background, build: dependencies.build)
    }

    func didBecomeActive() {
        runMarker.write(.foreground, build: dependencies.build)
        if !previousRunHandled {
            // Both flags are set here, before the task is queued: a diagnostic job already waiting on the main
            // actor must find the previous run taken (diagnosticArrived would report it as its own crash).
            previousRunHandled = true
            processingPreviousRun = true
            previousRunTask = Task { await processPreviousRun() }
        } else {
            Task { await flushPending(force: false) }
        }
    }

    func didEnterBackground() {
        runMarker.write(.background, build: dependencies.build)
    }

    func willTerminate() {
        runMarker.remove()
    }

    // MARK: The previous run

    /// One report per previous run: `crash` when there is an exception file or a crash diagnostic, otherwise
    /// `unclean-exit` when the marker said so. For an unclean exit with no exception it waits for MetricKit.
    func processPreviousRun() async {
        previousRunHandled = true
        processingPreviousRun = true
        try? FileManager.default.removeItem(at: uncleanFlag)
        let exception = NCProblemReportCrash.takePendingException(at: exceptionFile)
        var diagnostics = metricStore.takeAll()
        if exception == nil, diagnostics.isEmpty, previousRunUnclean {
            var polls = Int((dependencies.metricKitWait / 0.25).rounded(.up))
            while polls > 0, !metricStore.hasDiagnostics {
                try? await Task.sleep(for: .milliseconds(250))
                polls -= 1
            }
            diagnostics = metricStore.takeAll()
        }
        let parts = [exception].compactMap { $0 } + diagnostics
        // From here on the previous run is decided; a later diagnostic is the same event (see diagnosticArrived).
        processingPreviousRun = false
        // One round for everything this start sends: the share to Support is looked at once and the round is
        // announced once (the new report and any older ones that were waiting).
        let round = NCProblemReportShareRound()
        var fresh: NCProblemReportOutcome?
        if !previousRunReported {
            if !parts.isEmpty {
                previousRunReported = true
                fresh = await deliver(.crash, crashText: parts.joined(separator: "\n\n"), round: round, announceResult: false)
            } else if previousRunUnclean {
                previousRunReported = true
                fresh = await deliver(.uncleanExit, crashText: nil, round: round, announceResult: false)
            }
        }
        let waiting = await flushPending(force: false, round: round, announceResult: false)
        // The older reports speak for the round when they went out; a failed retry of them stays quiet.
        let waitingSent = waiting == .keptForLater ? nil : waiting
        if let outcome = waitingSent ?? fresh {
            announce(outcome)
        }
    }

    /// A diagnostic that MetricKit delivered after the start. It is its own crash report only when no report was
    /// made for the previous run; otherwise it is the same event and is dropped.
    func diagnosticArrived() async {
        // The start-up step takes it: before it ran, and while it waits for MetricKit (it finds the diagnostic
        // in the store; taking it here too would give one crash two reports and two questions).
        guard previousRunHandled, !processingPreviousRun else { return }
        let texts = metricStore.takeAll()
        guard !texts.isEmpty, !previousRunReported else { return }
        previousRunReported = true
        await deliver(.crash, crashText: texts.joined(separator: "\n\n"))
    }

    /// Switch on: send now. Switch off: ask once; Not now forgets the event.
    @discardableResult
    func deliver(_ kind: NCProblemReportKind, crashText: String?, round: NCProblemReportShareRound = NCProblemReportShareRound(),
                 announceResult: Bool = true) async -> NCProblemReportOutcome? {
        if isEnabled {
            return await sendReport(kind: kind, note: "", crashText: crashText, automatic: true, round: round, announceResult: announceResult)
        }
        guard await dependencies.confirm() else { return nil }
        return await sendReport(kind: kind, note: "", crashText: crashText, automatic: false, round: round, announceResult: announceResult)
    }

    // MARK: Sending

    /// "Report a problem": always works, also with the switch off.
    func sendManual(note: String) async -> NCProblemReportOutcome {
        await sendReport(kind: .manual, note: note, crashText: nil, automatic: false)
    }

    private func sendReport(kind: NCProblemReportKind, note: String, crashText: String?, automatic: Bool,
                            round: NCProblemReportShareRound = NCProblemReportShareRound(), announceResult: Bool = true) async -> NCProblemReportOutcome {
        // Right after a start the account's session may not be set up yet.
        var polls = Int((dependencies.transportWait / 0.5).rounded(.up))
        while polls > 0, dependencies.transport() == nil, dependencies.accountExists() {
            try? await Task.sleep(for: .milliseconds(500))
            polls -= 1
        }
        let transport = dependencies.transport()
        let date = dependencies.now()
        var info = dependencies.info()
        if let host = transport?.host { info.serverHost = host }
        let readLogs = dependencies.logs
        let reportInfo = info
        // Reading the log folder, scrubbing and zipping all happen off the main actor.
        let zip = await Task.detached(priority: .utility) {
            NCProblemReportBuilder.build(kind: kind, note: note, crashText: crashText, logs: readLogs(), info: reportInfo, date: date)
        }.value
        let fileName = NCProblemReportBuilder.fileName(date: date, appVersion: reportInfo.appVersion)
        let outcome = await sender(automatic: automatic, transport: transport).send(zip: zip, fileName: fileName, round: round)
        if announceResult { announce(outcome) }
        return outcome
    }

    /// Sends the reports kept on the phone, at most once per `flushInterval` unless `force` (a new sign-in).
    /// Returns the outcome it announces (or would announce), nil when nothing was sent.
    @discardableResult
    func flushPending(force: Bool, round: NCProblemReportShareRound = NCProblemReportShareRound(),
                      announceResult: Bool = true) async -> NCProblemReportOutcome? {
        guard let transport = dependencies.transport() else { return nil }
        let now = dependencies.now()
        if !force, let last = lastFlush, now.timeIntervalSince(last) < dependencies.flushInterval { return nil }
        let explicit = sender(automatic: false, transport: transport)
        let automatic = sender(automatic: true, transport: transport)
        guard explicit.hasPending || automatic.hasPending else { return nil }
        lastFlush = now
        // One round: the share to Support is looked at once, and the round is announced once.
        var outcomes: [NCProblemReportOutcome] = []
        if let outcome = await explicit.sendPending(round: round) { outcomes.append(outcome) }
        if isEnabled {
            if let outcome = await automatic.sendPending(round: round) { outcomes.append(outcome) }
        } else {
            // The switch is off: reports that were waiting only because it was on are not sent, and not kept.
            automatic.discardPending()
        }
        guard let outcome = outcomes.last(where: { $0 != .keptForLater }) else { return outcomes.last }
        if announceResult { announce(outcome) }
        return outcome
    }

    private func announce(_ outcome: NCProblemReportOutcome) {
        switch outcome {
        case .sent:
            dependencies.notify(Self.text("_nodrive_reports_sent_"))
        case .savedNotShared:
            dependencies.notify(Self.text("_nodrive_reports_saved_"))
        case .keptForLater:
            dependencies.notify(Self.text("_nodrive_reports_retry_"))
        case .noAccount:
            dependencies.notify(Self.text("_nodrive_reports_after_signin_"))
        }
    }

    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: "ProblemReports", comment: "")
    }
}

// MARK: - The app's real surroundings

extension NCProblemReports.Dependencies {
    @MainActor
    static func live() -> NCProblemReports.Dependencies {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let bundle = Bundle.main
        return NCProblemReports.Dependencies(
            directory: support.appendingPathComponent("NoDrive/ProblemReports", isDirectory: true),
            defaults: UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup) ?? .standard,
            build: (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "",
            shortVersion: (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "",
            detectionEnabled: !NCProblemReportUITestHooks.detectionSuppressed,
            now: { Date() },
            info: { NCProblemReportInfo.current(serverHost: "") },
            transport: { NCProblemReportPresenter.liveTransport() },
            accountExists: { NCManageDatabase.shared.getActiveTableAccount() != nil },
            logs: {
                NextcloudKit.flushLogger()
                return NCProblemReportBuilder.readLogs(in: NCPreferences.sharedLogDirectory)
            },
            confirm: { await NCProblemReportPresenter.confirmSend() },
            notify: { text in NCProblemReportPresenter.showMessage(text) },
            metricKitWait: 15,
            transportWait: 20,
            flushInterval: 600)
    }
}

// MARK: - Screens

@MainActor
enum NCProblemReportPresenter {
    /// The signed-in (active) account's own server and session, or nil.
    static func liveTransport() -> NCProblemReportTransport? {
        guard let account = NCManageDatabase.shared.getActiveTableAccount() else { return nil }
        let session = NCSession.shared.getSession(account: account.account)
        guard !session.account.isEmpty, !session.urlBase.isEmpty, !session.userId.isEmpty else { return nil }
        return NCNextcloudKitReportTransport(account: session.account, urlBase: session.urlBase, userId: session.userId)
    }

    static func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
    }

    /// A screen to show the question on, or nil while the app is not ready for one (not active, the passcode
    /// screen or another alert on top).
    static func presenter() -> UIViewController? {
        guard UIApplication.shared.applicationState == .active, let scene = activeScene() else { return nil }
        let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        guard var controller = window?.rootViewController else { return nil }
        // The passcode screen is recognised by its class name (the lock screen is upstream code with no shared marker).
        if String(describing: type(of: controller)).contains("Passcode") { return nil }
        while let presented = controller.presentedViewController {
            if presented is UIAlertController || String(describing: type(of: presented)).contains("Passcode") { return nil }
            controller = presented
        }
        return controller
    }

    /// Asks "NoDrive closed unexpectedly. Send a problem report?" once the main screen is visible.
    static func confirmSend() async -> Bool {
        var waited = 0
        while presenter() == nil, waited < 600 {
            try? await Task.sleep(for: .seconds(1))
            waited += 1
        }
        guard let presenter = presenter() else { return false }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: nil, message: NCProblemReports.text("_nodrive_reports_closed_"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NCProblemReports.text("_nodrive_reports_send_"), style: .default) { _ in
                continuation.resume(returning: true)
            })
            alert.addAction(UIAlertAction(title: NCProblemReports.text("_nodrive_reports_not_now_"), style: .cancel) { _ in
                continuation.resume(returning: false)
            })
            presenter.present(alert, animated: true)
        }
    }

    static func showMessage(_ text: String) {
        Task { @MainActor in
            await showInfoBanner(windowScene: activeScene(), text: text)
        }
    }
}
