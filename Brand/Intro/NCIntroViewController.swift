// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2019 Marino Faggiana
// SPDX-FileCopyrightText: 2019 Philippe Weidmann
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import NextcloudKit

class NCIntroViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    @IBOutlet weak var buttonLogin: UIButton!
    @IBOutlet weak var buttonSignUp: UIButton!
    @IBOutlet weak var buttonHost: UIButton!
    @IBOutlet weak var introCollectionView: UICollectionView!
    @IBOutlet weak var pageControl: UIPageControl!

    weak var delegate: NCIntroViewController?
    // Controller
    var controller: NCMainTabBarController?

    private let appDelegate = (UIApplication.shared.delegate as? AppDelegate)!
    // NoDrive: two slides (Nourax logo; files and sharing). No Nextcloud artwork, no mail/meeting slides.
    private let titles = [NSLocalizedString("_intro_1_title_", comment: ""), NSLocalizedString("_intro_2_title_", comment: "")]
    private let images = [UIImage(named: "intro1"),
                          UIImage(systemName: "folder.badge.person.crop", withConfiguration: UIImage.SymbolConfiguration(pointSize: 120, weight: .regular))?.withTintColor(.white, renderingMode: .alwaysOriginal)]
    private var timer: Timer?
    private var textColor: UIColor = .white
    private var textColorOpponent: UIColor = .black
    private var activeLoginProvider: NCLoginProvider?

    // MARK: - View Life Cycle

    override func viewDidLoad() {
        super.viewDidLoad()

        let isTooLight = NCBrandColor.shared.customer.isTooLight()
        let isTooDark = NCBrandColor.shared.customer.isTooDark()

        if isTooLight {
            textColor = .black
            textColorOpponent = .white
        } else if isTooDark {
            textColor = .white
            textColorOpponent = .black
        } else {
            textColor = .white
            textColorOpponent = .black
        }

        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithTransparentBackground()
        navBarAppearance.shadowColor = .clear
        navBarAppearance.shadowImage = UIImage()
        self.navigationController?.navigationBar.standardAppearance = navBarAppearance
        self.navigationController?.view.backgroundColor = NCBrandColor.shared.customer
        self.navigationController?.navigationBar.tintColor = textColor

        if !NCManageDatabase.shared.getAllTableAccount().isEmpty {
            let navigationItemCancel = UIBarButtonItem(image: UIImage(systemName: "xmark"), style: .plain, target: self, action: #selector(actionCancel(_:)))
            navigationItemCancel.tintColor = textColor
            navigationItem.rightBarButtonItem = navigationItemCancel
        }

        pageControl.currentPageIndicatorTintColor = textColor
        pageControl.pageIndicatorTintColor = .lightGray

        buttonLogin.layer.cornerRadius = 8
        buttonLogin.setTitleColor(NCBrandColor.shared.customer, for: .normal)
        buttonLogin.backgroundColor = textColor
        buttonLogin.setTitle(NSLocalizedString("_log_in_", comment: ""), for: .normal)

        buttonSignUp.layer.cornerRadius = 8
        buttonSignUp.setTitleColor(textColor, for: .normal)
        buttonSignUp.backgroundColor = textColor.withAlphaComponent(0.2)
        buttonSignUp.titleLabel?.adjustsFontSizeToFitWidth = true
        buttonSignUp.setTitle(NSLocalizedString("_sign_up_", comment: ""), for: .normal)

        buttonHost.layer.cornerRadius = 20
        buttonHost.setTitle(NSLocalizedString("_host_your_own_server", comment: ""), for: .normal)
        buttonHost.setTitleColor(textColor.withAlphaComponent(0.5), for: .normal)

        // NoDrive: one fixed server, so no "Sign up with provider" and no "Host your own server".
        buttonLogin.accessibilityIdentifier = "nodriveLoginButton"
        buttonSignUp.isHidden = NCBrandOptions.shared.linkloginPreferredProviders.isEmpty
        buttonHost.isHidden = NCBrandOptions.shared.linkLoginHost.isEmpty

        introCollectionView.register(UINib(nibName: "NCIntroCollectionViewCell", bundle: nil), forCellWithReuseIdentifier: "introCell")
        introCollectionView.dataSource = self
        introCollectionView.delegate = self
        introCollectionView.backgroundColor = NCBrandColor.shared.customer
        pageControl.numberOfPages = self.titles.count

        view.backgroundColor = NCBrandColor.shared.customer

        self.timer = Timer.scheduledTimer(timeInterval: 4, target: self, selector: (#selector(self.autoScroll(_:))), userInfo: nil, repeats: true)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        if traitCollection.userInterfaceStyle == .light {
            return .lightContent
        } else {
            return .darkContent
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        timer?.invalidate()
        timer = nil
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        coordinator.animate(alongsideTransition: nil) { _ in
            self.pageControl?.currentPage = 0
            self.introCollectionView?.collectionViewLayout.invalidateLayout()
        }
    }

    @objc func autoScroll(_ sender: Any?) {
        if pageControl.currentPage + 1 >= titles.count {
            pageControl.currentPage = 0
        } else {
            pageControl.currentPage += 1
        }
        introCollectionView.scrollToItem(at: IndexPath(row: pageControl.currentPage, section: 0), at: .centeredHorizontally, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, targetContentOffsetForProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        return CGPoint.zero
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return titles.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = (collectionView.dequeueReusableCell(withReuseIdentifier: "introCell", for: indexPath) as? NCIntroCollectionViewCell)!
        cell.backgroundColor = NCBrandColor.shared.customer
        cell.indexPath = indexPath
        cell.titleLabel.textColor = textColor
        cell.titleLabel.text = titles[indexPath.row]
        cell.imageView.image = images[indexPath.row]
        cell.accessibilityIdentifier = "nodriveIntroSlide\(indexPath.row + 1)" // NoDrive: for the screenshot UI test
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        return collectionView.bounds.size
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        timer = Timer.scheduledTimer(timeInterval: 4, target: self, selector: (#selector(autoScroll(_:))), userInfo: nil, repeats: true)
        pageControl.currentPage = Int(scrollView.contentOffset.x) / Int(scrollView.frame.width)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Action

    @objc func actionCancel(_ sender: Any?) {
        dismiss(animated: true) { }
    }

    @IBAction func login(_ sender: Any) {
        // NoDrive: the server is fixed, so start the browser sign-in (Login Flow v2) right away.
        if NCBrandOptions.shared.disable_request_login_url, !NCBrandOptions.shared.loginBaseUrl.isEmpty {
            startFixedServerLogin(url: NCBrandOptions.shared.loginBaseUrl)
            return
        }
        if let viewController = UIStoryboard(name: "NCLogin", bundle: nil).instantiateViewController(withIdentifier: "NCLogin") as? NCLogin {
            viewController.controller = self.controller
            self.navigationController?.pushViewController(viewController, animated: true)
        }
    }

    @IBAction func signupWithProvider(_ sender: Any) {
        let loginProvider = NCLoginProvider()
        loginProvider.controller = self.controller
        loginProvider.initialURLString = NCBrandOptions.shared.linkloginPreferredProviders
        loginProvider.presentingViewController = self
        loginProvider.startAuthentication()
        self.activeLoginProvider = loginProvider
    }

    @IBAction func host(_ sender: Any) {
        guard let url = URL(string: NCBrandOptions.shared.linkLoginHost) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - NoDrive fixed-server sign-in

    /// Login Flow v2 against the one NoDrive server, without the server-address screen.
    /// Same calls as `NCLogin.startLogin(url:)`.
    private func startFixedServerLogin(url: String) {
        buttonLogin.isEnabled = false
        buttonLogin.hideButtonAndShowSpinner(tint: textColor)

        NextcloudKit.shared.getServerStatus(serverUrl: url) { [weak self] _, serverInfoResult in
            guard let self else { return }
            switch serverInfoResult {
            case .success:
                if let host = URL(string: url)?.host {
                    NCNetworking.shared.writeCertificate(host: host)
                }
                let loginOptions = NKRequestOptions(customUserAgent: userAgent)
                NextcloudKit.shared.getLoginFlowV2(serverUrl: url, options: loginOptions) { [weak self] token, endpoint, login, _, error in
                    guard let self else { return }
                    if error == .success, let token, let endpoint, let login {
                        let loginProvider = NCLoginProvider()
                        loginProvider.initialURLString = login
                        loginProvider.delegate = self
                        loginProvider.controller = self.controller
                        loginProvider.presentingViewController = self
                        loginProvider.startPolling(loginFlowV2Token: token, loginFlowV2Endpoint: endpoint, loginFlowV2Login: login)
                        loginProvider.startAuthentication()
                        self.activeLoginProvider = loginProvider
                    } else {
                        self.showFixedServerLoginError(error)
                    }
                }
            case .failure(let error):
                self.showFixedServerLoginError(error)
            }
        }
    }

    private func showFixedServerLoginError(_ error: NKError) {
        onBack()
        Task { @MainActor in
            let windowScene = SceneManager.shared.getWindowScene(controller: self.controller)
            await showErrorBanner(windowScene: windowScene, error: error)
        }
    }
}

// MARK: - NCLoginProviderDelegate (NoDrive)

extension NCIntroViewController: NCLoginProviderDelegate {
    /// Browser sign-in cancelled or failed: show "Log in" again.
    func onBack() {
        buttonLogin.isEnabled = true
        buttonLogin.hideSpinnerAndShowButton()
        activeLoginProvider?.cancel()
        activeLoginProvider = nil
    }
}

extension UINavigationController {
    open override var childForStatusBarStyle: UIViewController? {
        return topViewController?.childForStatusBarStyle ?? topViewController
    }
}
