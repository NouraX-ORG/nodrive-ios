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

    let account: String
    private let startURL: URL
    private let base: String
    private let showsCloseButton: Bool
    private var webView: WKWebView!
    private let spinner = UIActivityIndicatorView(style: .large)
    private var canGoBackObservation: NSKeyValueObservation?
    private var startTask: Task<Void, Never>?
    private var lastPageURL: URL
    private var lastReauthentication: Date?

    /// - Parameters:
    ///   - account: the NoDrive account whose app password signs the page in.
    ///   - url: the page; it must be of the account's own origin.
    ///   - showsCloseButton: true when presented on its own (notification links), false inside the main screen.
    init(account: String, url: URL, title: String, showsCloseButton: Bool = false) {
        self.account = account
        self.startURL = url
        self.lastPageURL = url
        self.base = NCWorkspaceSession.credentials(account: account)?.base ?? ""
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

    // MARK: - Sign-in and loading

    /// Signs in natively, puts the session cookies into the web view, then loads `url` without a credential.
    private func signInAndLoad(_ url: URL) {
        startTask?.cancel()
        spinner.startAnimating()
        let account = account
        let store = webView.configuration.websiteDataStore.httpCookieStore
        startTask = Task { [weak self] in
            do {
                let session = try await NCWorkspaceSession.bootstrap(account: account)
                guard !Task.isCancelled, let self else { return }
                guard NCWorkspaceOrigin.isSameOrigin(url.absoluteString, base: session.base) else {
                    throw NCWorkspaceSessionError.noSession
                }
                for cookie in session.cookies {
                    await store.setCookie(cookie)
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
        spinner.stopAnimating()
        guard presentedViewController == nil else { return }
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
        guard isViewLoaded else { return }
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
        if presentingViewController != nil || navigationController?.presentingViewController != nil {
            dismiss(animated: true)
        } else {
            // Inside the main screen: back to the files.
            (tabBarController as? NCMainTabBarController)?.openSidebarFiles()
        }
    }

    /// Called when the account is removed or signed out: stop everything and leave nothing behind.
    func invalidate() {
        startTask?.cancel()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        if presentingViewController != nil || navigationController?.presentingViewController != nil {
            dismiss(animated: false)
        }
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
        switch NCWorkspaceOrigin.navigationDecision(for: url.absoluteString, base: base) {
        case .allow:
            lastPageURL = url
            decisionHandler(.allow)
        case .reauthenticate:
            decisionHandler(.cancel)
            reauthenticate()
        case .close:
            decisionHandler(.cancel)
            closeScreen()
        case .openExternally:
            decisionHandler(.cancel)
            openInBrowserPanel(url)
        case .openSystem:
            decisionHandler(.cancel)
            UIApplication.shared.open(url)
        case .cancel:
            decisionHandler(.cancel)
        }
    }

    /// The server ended the web session (a login page came up): sign in again natively, once a minute at most.
    private func reauthenticate() {
        if let last = lastReauthentication, Date().timeIntervalSince(last) < 60 {
            showFailure()
            return
        }
        lastReauthentication = Date()
        signInAndLoad(lastPageURL)
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
        guard let url = navigationAction.request.url else { return nil }
        switch NCWorkspaceOrigin.navigationDecision(for: url.absoluteString, base: base) {
        case .allow:
            webView.load(URLRequest(url: url))
        case .openExternally:
            openInBrowserPanel(url)
        default:
            break
        }
        return nil
    }
}
