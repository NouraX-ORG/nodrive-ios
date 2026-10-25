// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import UIKit
@testable import Nextcloud

/// Checks the NoDrive values that tools/rebrand.py writes into the brand hooks,
/// the Info.plist and the project. The unit-test host is the app itself, so
/// `Bundle.main` is the built NoDrive app.
@Suite("NoDrive branding")
struct NoDriveBrandingTests {
    let brand = NCBrandOptions.shared

    @Test func appNameAndMaker() {
        #expect(brand.brand == "NoDrive")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "NoDrive")
        #expect(brand.textCopyrightNextcloudServer == "Nourax Workspace %@")
    }

    @Test func bundleIdentifierAndAppGroup() {
        #expect(Bundle.main.bundleIdentifier == "org.nourax.nodrive")
        #expect(brand.capabilitiesGroup == "group.org.nourax.nodrive")
        #expect(brand.capabilitiesGroupApps.isEmpty)
    }

    @Test func urlSchemes() {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes == ["nodrive"])
        #expect(NCGlobal.shared.appScheme == "nodrive")
        #expect(brand.webLoginAutenticationProtocol == "nodrive://")
    }

    @Test func fixedServer() {
        #expect(brand.loginBaseUrl == "https://drive.nourax.org")
        #expect(brand.disable_request_login_url)
        #expect(brand.disable_multiaccount)
        #expect(!brand.disable_intro)
        #expect(!brand.use_AppConfig)
        #expect(brand.enforce_servers.isEmpty)
        #expect(brand.linkLoginHost.isEmpty)
        #expect(brand.linkloginPreferredProviders.isEmpty)
    }

    @Test func version() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "35.2.1")
        #expect(Bundle.main.object(forInfoDictionaryKey: "NouraxVersion") as? String == "35.2.1-nourax.1")
        #expect(brand.textCopyrightNextcloudiOS == "NoDrive 35.2.1-nourax.1")
    }

    /// Nextcloud server 35 recognises the iOS client with this pattern
    /// (`USER_AGENT_CLIENT_IOS` in lib/public/IRequest.php, tag v35.0.2).
    @Test func userAgentMatchesServer() throws {
        let pattern = #"^Mozilla\/5\.0 \(iOS\) (?:ownCloud|Nextcloud)\-iOS\/([^ ]*).*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let agent = userAgent
        let match = try #require(regex.firstMatch(in: agent, range: NSRange(agent.startIndex..., in: agent)))
        let versionRange = try #require(Range(match.range(at: 1), in: agent))
        #expect(String(agent[versionRange]) == "35.2.1")
        #expect(agent == "Mozilla/5.0 (iOS) Nextcloud-iOS/35.2.1 NoDrive")
    }

    @Test func nextcloudServicesAreOff() {
        #expect(brand.pushNotificationServerProxy.isEmpty)
        #expect(brand.appStoreUrl.isEmpty)
        #expect(brand.sourceCode.isEmpty)
        #expect(brand.disable_crash_service)
        #expect(brand.disable_show_more_nextcloud_apps_in_settings)
        #expect(brand.disable_source_code_in_settings)
        #expect(NCGlobal.shared.talkAppStoreUrl.isEmpty)
        #expect(NCGlobal.shared.notesAppStoreUrl.isEmpty)
        #expect(NCGlobal.shared.moreAppsUrl.isEmpty)
        #expect(Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") == nil)
    }

    @Test func privacyLinkHiddenWhileEmpty() {
        #expect(brand.privacy.isEmpty)
    }

    @Test func colours() {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #expect(NCBrandColor.shared.customer.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        #expect(Int((red * 255).rounded()) == 0x25)
        #expect(Int((green * 255).rounded()) == 0x63)
        #expect(Int((blue * 255).rounded()) == 0xEB)
        #expect(!brand.use_themingColor)
    }
}
