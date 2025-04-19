import Foundation
import Capacitor
@preconcurrency import WebKit
import UIKit

// Add DownloadDelegate class
@available(iOS 13.0, *)
class DownloadDelegate: NSObject, WKDownloadDelegate {
    weak var webViewController: WKWebViewController?

    @available(iOS 14.5, *)
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documentsPath.appendingPathComponent(suggestedFilename)
        completionHandler(url)
    }

    @available(iOS 14.5, *)
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let alert = UIAlertController(title: "Download Failed", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        DispatchQueue.main.async {
            self.webViewController?.present(alert, animated: true)
        }
    }

    @available(iOS 14.5, *)
    func downloadDidFinish(_ download: WKDownload) {
        let alert = UIAlertController(title: "Download Complete", message: "Your file has been downloaded successfully", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        DispatchQueue.main.async {
            self.webViewController?.present(alert, animated: true)
        }
    }
}

extension UIColor {

    convenience init(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int = UInt64()
        Scanner(string: hex).scanHexInt64(&int)
        let components = (
            R: CGFloat((int >> 16) & 0xff) / 255,
            G: CGFloat((int >> 08) & 0xff) / 255,
            B: CGFloat((int >> 00) & 0xff) / 255
        )
        self.init(red: components.R, green: components.G, blue: components.B, alpha: 1)
    }

}

/**
 * Please read the Capacitor iOS Plugin Development Guide
 * here: https://capacitorjs.com/docs/plugins/ios
 */
@objc(InAppBrowserPlugin)
public class InAppBrowserPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "InAppBrowserPlugin"
    public let jsName = "InAppBrowser"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "open", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openWebView", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearCookies", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getCookies", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearAllCookies", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearCache", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "reload", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setUrl", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "show", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "close", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "executeScript", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "postMessage", returnType: CAPPluginReturnPromise)
    ]
    var navigationWebViewController: UINavigationController?
    private var privacyScreen: UIImageView?
    private var isSetupDone = false
    var currentPluginCall: CAPPluginCall?
    var isPresentAfterPageLoad = false
    var webViewController: WKWebViewController?
    private var closeModalTitle: String?
    private var closeModalDescription: String?
    private var closeModalOk: String?
    private var closeModalCancel: String?

    private func setup() {
        self.isSetupDone = true

        #if swift(>=4.2)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive(_:)), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive(_:)), name: UIApplication.willResignActiveNotification, object: nil)
        #else
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive(_:)), name: .UIApplicationDidBecomeActive, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive(_:)), name: .UIApplicationWillResignActive, object: nil)
        #endif
    }

    func presentView(isAnimated: Bool = true) {
        guard let navigationController = self.navigationWebViewController else {
            self.currentPluginCall?.reject("Navigation controller is not initialized")
            return
        }

        guard let rootViewController = UIApplication.shared.windows.first?.rootViewController else {
            self.currentPluginCall?.reject("Root view controller not found")
            return
        }

        DispatchQueue.main.async {
            rootViewController.present(navigationController, animated: isAnimated) { [weak self] in
                self?.currentPluginCall?.resolve()
            }
        }
    }

    @objc func clearAllCookies(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            let dataStore = WKWebsiteDataStore.default()
            let dataTypes = Set([WKWebsiteDataTypeCookies])

            dataStore.removeData(ofTypes: dataTypes,
                                 modifiedSince: Date(timeIntervalSince1970: 0)) { [weak self] in
                call.resolve()
            }
        }
    }

    @objc func clearCache(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            let dataStore = WKWebsiteDataStore.default()
            let dataTypes = Set([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache])

            dataStore.removeData(ofTypes: dataTypes,
                                 modifiedSince: Date(timeIntervalSince1970: 0)) { [weak self] in
                call.resolve()
            }
        }
    }

    @objc func clearCookies(_ call: CAPPluginCall) {
        guard let url = call.getString("url"),
              let host = URL(string: url)?.host else {
            call.reject("Invalid URL")
            return
        }

        DispatchQueue.main.async {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let group = DispatchGroup()
                for cookie in cookies {
                    if cookie.domain == host || cookie.domain.hasSuffix(".\(host)") || host.hasSuffix(cookie.domain) {
                        group.enter()
                        WKWebsiteDataStore.default().httpCookieStore.delete(cookie) {
                            group.leave()
                        }
                    }
                }

                group.notify(queue: .main) {
                    call.resolve()
                }
            }
        }
    }

    @objc func getCookies(_ call: CAPPluginCall) {
        let urlString = call.getString("url") ?? ""
        let includeHttpOnly = call.getBool("includeHttpOnly") ?? true

        guard let url = URL(string: urlString), let host = url.host else {
            call.reject("Invalid URL")
            return
        }

        DispatchQueue.main.async {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                var cookieDict = [String: String]()
                for cookie in cookies {

                    if (includeHttpOnly || !cookie.isHTTPOnly) && (cookie.domain == host || cookie.domain.hasSuffix(".\(host)") || host.hasSuffix(cookie.domain)) {
                        cookieDict[cookie.name] = cookie.value
                    }
                }
                call.resolve(cookieDict)
            }
        }

    }

    @objc func openWebView(_ call: CAPPluginCall) {
        if !self.isSetupDone {
            self.setup()
        }
        self.currentPluginCall = call

        guard let urlString = call.getString("url") else {
            call.reject("Must provide a URL to open")
            return
        }

        if urlString.isEmpty {
            call.reject("URL must not be empty")
            return
        }

        guard let url = URL(string: urlString) else {
            call.reject("Invalid URL format")
            return
        }

        // Configure WebView for downloads
        let config = WKWebViewConfiguration()
        let preferences = WKPreferences()
        preferences.javaScriptEnabled = true
        config.preferences = preferences

        // Add download handling
        if #available(iOS 13.0, *) {
            let downloadDelegate = DownloadDelegate()
            downloadDelegate.webViewController = webViewController
        }

        let headers = call.getObject("headers", [:]).mapValues { String(describing: $0 as Any) }
        let credentials = self.readCredentials(call)
        let closeModal = call.getBool("closeModal", false)
        let closeModalTitle = call.getString("closeModalTitle", "Close")
        let closeModalDescription = call.getString("closeModalDescription", "Are you sure you want to close this window?")
        let closeModalOk = call.getString("closeModalOk", "OK")
        let closeModalCancel = call.getString("closeModalCancel", "Cancel")
        let isInspectable = call.getBool("isInspectable", false)
        let preventDeeplink = call.getBool("preventDeeplink", false)
        let isAnimated = call.getBool("isAnimated", true)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                call.reject("Self reference is nil")
                return
            }

            do {
                self.webViewController = WKWebViewController(url: url, headers: headers, isInspectable: isInspectable, credentials: credentials, preventDeeplink: preventDeeplink, blankNavigationTab: false)

                guard let webViewController = self.webViewController else {
                    call.reject("Failed to initialize WebViewController")
                    return
                }

                if self.bridge?.statusBarVisible == true {
                    let subviews = self.bridge?.webView?.superview?.subviews
                    if let emptyStatusBarIndex = subviews?.firstIndex(where: { $0.subviews.isEmpty }) {
                        if let emptyStatusBar = subviews?[emptyStatusBarIndex] {
                            webViewController.capacitorStatusBar = emptyStatusBar
                            emptyStatusBar.removeFromSuperview()
                        }
                    }
                }

                webViewController.source = .remote(url)
                webViewController.leftNavigationBarItemTypes = []
                webViewController.capBrowserPlugin = self
                webViewController.title = call.getString("title", "New Window")
                webViewController.websiteTitleInNavigationBar = call.getBool("visibleTitle", true)
                webViewController.ignoreUntrustedSSLError = call.getBool("ignoreUntrustedSSLError", false)

                if closeModal {
                    webViewController.closeModal = true
                    webViewController.closeModalTitle = closeModalTitle
                    webViewController.closeModalDescription = closeModalDescription
                    webViewController.closeModalOk = closeModalOk
                    webViewController.closeModalCancel = closeModalCancel
                }

                self.navigationWebViewController = UINavigationController(rootViewController: webViewController)
                self.navigationWebViewController?.modalPresentationStyle = .fullScreen
                self.navigationWebViewController?.navigationBar.isTranslucent = false

                // Ensure no lines or borders appear by default
                self.navigationWebViewController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
                self.navigationWebViewController?.navigationBar.shadowImage = UIImage()
                self.navigationWebViewController?.navigationBar.setValue(true, forKey: "hidesShadow")

                // Always hide toolbar
                self.navigationWebViewController?.setToolbarHidden(true, animated: false)

                if !self.isPresentAfterPageLoad {
                    self.presentView(isAnimated: isAnimated)
                }
                call.resolve()
            } catch {
                call.reject("Error initializing WebView: \(error.localizedDescription)")
            }
        }
    }

    @objc func reload(_ call: CAPPluginCall) {
        self.webViewController?.reload()
        call.resolve()
    }

    @objc func setUrl(_ call: CAPPluginCall) {
        guard let urlString = call.getString("url") else {
            call.reject("Cannot get new url to set")
            return
        }

        guard let url = URL(string: urlString) else {
            call.reject("Invalid URL")
            return
        }

        self.webViewController?.load(remote: url)
        call.resolve()
    }

    @objc func executeScript(_ call: CAPPluginCall) {
        guard let script = call.getString("code") else {
            call.reject("Cannot get script to execute")
            return
        }
        DispatchQueue.main.async {
            self.webViewController?.executeScript(script: script)
            call.resolve()
        }
    }

    @objc func postMessage(_ call: CAPPluginCall) {
        let eventData = call.getObject("detail", [:])
        // Check if eventData is empty
        if eventData.isEmpty {
            call.reject("Event data must not be empty")
            return
        }
        print("Event data: \(eventData)")

        DispatchQueue.main.async {
            self.webViewController?.postMessageToJS(message: eventData)
        }
        call.resolve()
    }

    func isHexColorCode(_ input: String) -> Bool {
        let hexColorRegex = "^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$"

        do {
            let regex = try NSRegularExpression(pattern: hexColorRegex)
            let range = NSRange(location: 0, length: input.utf16.count)
            if let _ = regex.firstMatch(in: input, options: [], range: range) {
                return true
            }
        } catch {
            print("Error creating regular expression: \(error)")
        }

        return false
    }

    @objc func open(_ call: CAPPluginCall) {
        if !self.isSetupDone {
            self.setup()
        }

        let isInspectable = call.getBool("isInspectable", false)
        let preventDeeplink = call.getBool("preventDeeplink", false)
        self.isPresentAfterPageLoad = call.getBool("isPresentAfterPageLoad", false)

        self.currentPluginCall = call

        guard let urlString = call.getString("url") else {
            call.reject("Must provide a URL to open")
            return
        }

        if urlString.isEmpty {
            call.reject("URL must not be empty")
            return
        }

        let headers = call.getObject("headers", [:]).mapValues { String(describing: $0 as Any) }
        let credentials = self.readCredentials(call)

        DispatchQueue.main.async { [weak self] in
            guard let url = URL(string: urlString) else {
                call.reject("Invalid URL format")
                return
            }

            self?.webViewController = WKWebViewController(url: url, headers: headers, isInspectable: isInspectable, credentials: credentials, preventDeeplink: preventDeeplink, blankNavigationTab: true)

            guard let webViewController = self?.webViewController else {
                call.reject("Failed to initialize WebViewController")
                return
            }

            if self?.bridge?.statusBarVisible == true {
				let subviews = self?.bridge?.webView?.superview?.subviews
				if let emptyStatusBarIndex = subviews?.firstIndex(where: { $0.subviews.isEmpty }) {
					if let emptyStatusBar = subviews?[emptyStatusBarIndex] {
						webViewController.capacitorStatusBar = emptyStatusBar
						emptyStatusBar.removeFromSuperview()
					}
				}
			}

            webViewController.source = .remote(url)
            webViewController.leftNavigationBarItemTypes = [.back, .forward, .reload]
            webViewController.capBrowserPlugin = self
            webViewController.hasDynamicTitle = true

            self?.navigationWebViewController = UINavigationController.init(rootViewController: webViewController)
            self?.navigationWebViewController?.navigationBar.isTranslucent = false

            // Ensure no lines or borders appear by default
            self?.navigationWebViewController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
            self?.navigationWebViewController?.navigationBar.shadowImage = UIImage()
            self?.navigationWebViewController?.navigationBar.setValue(true, forKey: "hidesShadow")

            // Use system appearance
            let isDarkMode = UITraitCollection.current.userInterfaceStyle == .dark
            let backgroundColor = isDarkMode ? UIColor.black : UIColor.white
            let textColor = isDarkMode ? UIColor.white : UIColor.black

            // Apply colors
            webViewController.setupStatusBarBackground(color: backgroundColor)
            webViewController.tintColor = textColor
            self?.navigationWebViewController?.navigationBar.tintColor = textColor
            self?.navigationWebViewController?.navigationBar.titleTextAttributes = [NSAttributedString.Key.foregroundColor: textColor]
            webViewController.statusBarStyle = isDarkMode ? .lightContent : .darkContent
            webViewController.updateStatusBarStyle()

            // Always hide toolbar to ensure no bottom bar
            self?.navigationWebViewController?.setToolbarHidden(true, animated: false)

            self?.navigationWebViewController?.modalPresentationStyle = .fullScreen

            if !(self?.isPresentAfterPageLoad ?? false) {
                self?.presentView()
            }
            call.resolve()
        }
    }

    @objc func close(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.navigationWebViewController?.dismiss(animated: true, completion: nil)
            self.notifyListeners("closeEvent", data: ["url": self.webViewController?.url?.absoluteString ?? ""])
            call.resolve()
        }
    }

    private func showPrivacyScreen() {
        if privacyScreen == nil {
            self.privacyScreen = UIImageView()
            if let launchImage = UIImage(named: "LaunchImage") {
                privacyScreen!.image = launchImage
                privacyScreen!.frame = UIScreen.main.bounds
                privacyScreen!.contentMode = .scaleAspectFill
                privacyScreen!.isUserInteractionEnabled = false
            } else if let launchImage = UIImage(named: "Splash") {
                privacyScreen!.image = launchImage
                privacyScreen!.frame = UIScreen.main.bounds
                privacyScreen!.contentMode = .scaleAspectFill
                privacyScreen!.isUserInteractionEnabled = false
            }
        }
        self.navigationWebViewController?.view.addSubview(self.privacyScreen!)
    }

    private func hidePrivacyScreen() {
        self.privacyScreen?.removeFromSuperview()
    }

    @objc func appDidBecomeActive(_ notification: NSNotification) {
        self.hidePrivacyScreen()
    }

    @objc func appWillResignActive(_ notification: NSNotification) {
        self.showPrivacyScreen()
    }

    private func readCredentials(_ call: CAPPluginCall) -> WKWebViewCredentials? {
        var credentials: WKWebViewCredentials?
        let credentialsDict = call.getObject("credentials", [:]).mapValues { String(describing: $0 as Any) }
        if !credentialsDict.isEmpty, let username = credentialsDict["username"], let password = credentialsDict["password"] {
            credentials = WKWebViewCredentials(username: username, password: password)
        }
        return credentials
    }

    private func isDarkColor(_ color: UIColor) -> Bool {
        let components = color.cgColor.components ?? []
        let red = components[0]
        let green = components[1]
        let blue = components[2]
        let brightness = (red * 299 + green * 587 + blue * 114) / 1000
        return brightness < 0.5
    }
}
