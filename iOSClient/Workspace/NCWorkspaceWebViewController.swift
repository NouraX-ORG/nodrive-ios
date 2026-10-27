// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
@preconcurrency import WebKit
import SafariServices

/// A Workspace web app (Mail, Calendar, Talk, ...) inside NoDrive, already signed in.
///
/// Sign-in: the app's own HTTP client trades the account's app password for session cookies
/// (`NCWorkspaceSession.bootstrap`); only those host-only cookies are put into this web view, which then loads
/// the page with no credential header. The web view uses its own non-persistent data store: nothing reaches
/// the disk, nothing is shared between accounts, and closing the screen forgets it all.
@MainActor
final class NCWorkspaceWebViewController: UIViewController {
    /// The web view's user agent is the system's default plus this name ("... Mobile/15E148 NoDrive"), so the
    /// server's web pages do not take it for an unsupported browser.
    static let applicationName = "Mobile/15E148 NoDrive"

    /// What the screen does with a decision. The real ones act on the web view and the screen; the unit tests
    /// replace them to see which decision was taken.
    struct Effects {
        var load: (URL) -> Void
        var signIn: (URL) -> Void
        var failure: () -> Void
        var openPanel: (URL) -> Void
        var openSystem: (URL) -> Void
        var close: () -> Void
    }

    let account: String
    let showsCloseButton: Bool
    private let startURL: URL
    private let base: String
    private var webView: WKWebView!
    private let spinner = UIActivityIndicatorView(style: .large)
    private var canGoBackObservation: NSKeyValueObservation?
    private var startTask: Task<Void, Never>?
    private(set) var lastPageURL: URL
    private var lastReauthentication: Date?
    private var failurePending = false

    /// True once the account was removed or signed out: the screen is closed, its web data cleared, and it never
    /// signs in or loads anything again.
    private(set) var isInvalidated = false

    /// The screen's own data store (nil before the view is loaded).
    var websiteDataStore: WKWebsiteDataStore? {
        webView?.configuration.websiteDataStore
    }

    /// How the screen leaves when the account goes. Nil: the real way (see `leaveScreen`). Tests set it.
    var leaveHandler: (() -> Void)?

    lazy var effects = Effects(
        load: { [weak self] url in
            guard let self, !self.isInvalidated else { return }
            self.lastPageURL = url
            self.webView?.load(URLRequest(url: url))
        },
        signIn: { [weak self] url in self?.signInAndLoad(url) },
        failure: { [weak self] in self?.showFailure() },
        openPanel: { [weak self] url in self?.openInBrowserPanel(url) },
        openSystem: { url in UIApplication.shared.open(url) },
        close: { [weak self] in self?.closeScreen() }
    )

    /// - Parameters:
    ///   - account: the NoDrive account whose app password signs the page in.
    ///   - url: the page; it must be of the account's own origin.
    ///   - showsCloseButton: true when presented on its own (notification links), false inside the main screen.
    ///   - base: the account's server URL; nil takes it from the signed-in account (tests pass their own).
    init(account: String, url: URL, title: String, showsCloseButton: Bool = false, base: String? = nil) {
        self.account = account
        self.startURL = url
        self.lastPageURL = url
        self.base = base ?? NCWorkspaceSession.credentials(account: account)?.base ?? ""
        self.showsCloseButton = showsCloseButton
        super.init(nibName: nil, bundle: nil)
        self.title = title
        navigationItem.largeTitleDisplayMode = .never
        NCWorkspaceWeb.shared.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: - View life cycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        configuration.applicationNameForUserAgent = Self.applicationName
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.accessibilityIdentifier = "workspaceWebView"
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        self.webView = webView

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        if showsCloseButton {
            let close = UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })
            close.accessibilityLabel = NSLocalizedString("_close_", comment: "")
            close.accessibilityIdentifier = "workspaceClose"
            navigationItem.rightBarButtonItem = close
        }

        canGoBackObservation = webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.updateBackButton()
            }
        }

        signInAndLoad(startURL)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateBackButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A failure that came while the browser panel was up is shown now
        if failurePending, presentedViewController == nil {
            failurePending = false
            showFailure()
        }
    }

    // MARK: - Sign-in and loading

    /// Signs in natively, puts the session cookies into the web view, then loads `url` without a credential.
    private func signInAndLoad(_ url: URL) {
        guard !isInvalidated, isViewLoaded else { return }
        startTask?.cancel()
        spinner.startAnimating()
        let account = account
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let dataStore = webView.configuration.websiteDataStore
        startTask = Task { [weak self] in
            do {
                let session = try await NCWorkspaceSession.bootstrap(account: account)
                guard !Task.isCancelled, let self else { return }
                guard NCWorkspaceOrigin.isSameOrigin(url.absoluteString, base: session.base) else {
                    throw NCWorkspaceSessionError.noSession
                }
                for cookie in session.cookies where !self.isInvalidated {
                    await store.setCookie(cookie)
                }
                guard !self.isInvalidated else {
                    // The account went while the cookies were being set: leave nothing in the store
                    await dataStore.removeData(ofTypes: NCWorkspaceWeb.websiteDataTypes, modifiedSince: .distantPast)
                    return
                }
                guard !Task.isCancelled else { return }
                self.lastPageURL = url
                self.webView.load(URLRequest(url: url))
            } catch {
                guard !Task.isCancelled else { return }
                self?.showFailure()
            }
        }
    }

    private func showFailure() {
        guard !isInvalidated else { return }
        spinner.stopAnimating()
        guard presentedViewController == nil else {
            // Shown when the browser panel on top is gone
            failurePending = true
            return
        }
        let alert = UIAlertController(title: NSLocalizedString("_error_", comment: ""),
                                      message: nil,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("_retry_", comment: ""), style: .default) { [weak self] _ in
            guard let self else { return }
            self.signInAndLoad(self.lastPageURL)
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("_close_", comment: ""), style: .cancel) { [weak self] _ in
            self?.closeScreen()
        })
        present(alert, animated: true)
    }

    // MARK: - Back button

    /// The web page's history is walked with a back button next to the sidebar button.
    private func updateBackButton() {
        guard isViewLoaded, !isInvalidated else { return }
        if webView.canGoBack {
            let back = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"), primaryAction: UIAction { [weak self] _ in
                self?.webView.goBack()
            })
            back.accessibilityLabel = NSLocalizedString("_back_", comment: "")
            back.accessibilityIdentifier = "workspaceBack"
            navigationItem.leadingItemGroups = [UIBarButtonItemGroup(barButtonItems: [back], representativeItem: nil)]
        } else {
            navigationItem.leadingItemGroups = []
        }
        (navigationController as? NCMainNavigationController)?.configureSidebarButton()
    }

    // MARK: - Closing

    private func closeScreen() {
        leaveScreen(animated: true)
    }

    /// Presented on its own (notification link): dismiss it. Inside the main screen: back to the files.
    private func leaveScreen(animated: Bool) {
        if presentingViewController != nil || navigationController?.presentingViewController != nil {
            dismiss(animated: animated)
        } else {
            (tabBarController as? NCMainTabBarController)?.openSidebarFiles()
        }
    }

    /// Called when the account is removed (also a remote wipe) or signed out: stops everything, leaves the
    /// screen (a presented one is dismissed; the one in the main view gives way to Files), and clears the
    /// screen's own web data, so a later sign-in can never reuse the page, the cookies or the session.
    func invalidate() async {
        guard !isInvalidated else { return }
        isInvalidated = true
        startTask?.cancel()
        startTask = nil
        canGoBackObservation = nil
        spinner.stopAnimating()
        let store = webView?.configuration.websiteDataStore
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        if let leaveHandler {
            leaveHandler()
        } else {
            leaveScreen(animated: false)
        }
        await store?.removeData(ofTypes: NCWorkspaceWeb.websiteDataTypes, modifiedSince: .distantPast)
    }

    // MARK: - Other origins

    private func openInBrowserPanel(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let panel = SFSafariViewController(url: url)
        (presentedViewController ?? self).present(panel, animated: true)
    }
}

// MARK: - Navigation policy (design rules 2 to 4)

extension NCWorkspaceWebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Sub-frames and sub-resources are left to the engine.
        guard navigationAction.targetFrame?.isMainFrame ?? true, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(policy(forMainFrameNavigationTo: url))
    }

    /// The policy for a main-frame navigation, a server redirect included: the account's own pages load in place,
    /// a login page (the session ended) triggers a native sign-in, the log-out page closes the screen, another
    /// origin goes to the browser panel, and nothing else loads.
    func policy(forMainFrameNavigationTo url: URL) -> WKNavigationActionPolicy {
        guard !isInvalidated else { return .cancel }
        switch NCWorkspaceOrigin.navigationDecision(for: url.absoluteString, base: base) {
        case .allow:
            // Only a real page of the account is a place to come back to (not about:blank)
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                lastPageURL = url
            }
            return .allow
        case .reauthenticate:
            reauthenticate()
        case .close:
            effects.close()
        case .openExternally:
            effects.openPanel(url)
        case .openSystem:
            effects.openSystem(url)
        case .cancel:
            break
        }
        return .cancel
    }

    /// The server ended the web session (a login page came up): sign in again natively, once a minute at most.
    private func reauthenticate() {
        if let last = lastReauthentication, Date().timeIntervalSince(last) < 60 {
            effects.failure()
            return
        }
        lastReauthentication = Date()
        effects.signIn(lastPageURL)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        spinner.stopAnimating()
        if title?.isEmpty ?? true, let pageTitle = webView.title, !pageTitle.isEmpty {
            navigationItem.title = pageTitle
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        spinner.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        spinner.stopAnimating()
    }
}

// MARK: - target="_blank" windows

extension NCWorkspaceWebViewController: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            handleNewWindow(to: url)
        }
        return nil
    }

    /// A page asks for a new window (target="_blank", window.open): never a second web view. The account's own
    /// pages load in place, another origin goes to the browser panel, and the rest is treated as in the main frame.
    func handleNewWindow(to url: URL) {
        guard !isInvalidated else { return }
        switch NCWorkspaceOrigin.navigationDecision(for: url.absoluteString, base: base) {
        case .allow:
            effects.load(url)
        case .reauthenticate:
            reauthenticate()
        case .close:
            effects.close()
        case .openExternally:
            effects.openPanel(url)
        case .openSystem:
            effects.openSystem(url)
        case .cancel:
            break
        }
    }
}
