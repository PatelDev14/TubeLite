import UIKit
import WebKit
import AVFoundation

class ViewController: UIViewController {

    // MARK: - UI Properties
    var webView: WKWebView!
    var progressBar: UIProgressView!
    var toolbar: UIView!
    var backButton: UIButton!
    var forwardButton: UIButton!
    var homeButton: UIButton!
    var libraryButton: UIButton!
    var refreshButton: UIButton!
    var searchBar: UISearchBar!

    // KVO observations
    var progressObservation: NSKeyValueObservation?
    var backObservation: NSKeyValueObservation?
    var forwardObservation: NSKeyValueObservation?

    let toolbarHeight: CGFloat = 56

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        setupAudioSession()
        setupProgressBar()
        setupToolbar()
        // WebView is created after content rules are ready
        prepareWebViewAndLoad()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    // MARK: - Audio Session
    func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    // MARK: - WebView (created only after ad-block rules are compiled)
    func prepareWebViewAndLoad() {
        let config = WKWebViewConfiguration()

        // Media settings
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true

        // Inject all JS fixes
        let ucc = config.userContentController
        ucc.addUserScript(makeScript(spoofJS(),    time: .atDocumentStart, mainOnly: false))
        ucc.addUserScript(makeScript(visibilityJS(), time: .atDocumentStart, mainOnly: false))
        ucc.addUserScript(makeScript(adSkipJS(),   time: .atDocumentEnd,   mainOnly: true))

        // Compile ad-block rules first, then create the web view
        compileAdBlockRules(for: config) { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.createWebView(with: config)
                self.setupConstraints()
                self.loadYouTube()
            }
        }
    }

    func createWebView(with config: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = .black
        webView.isOpaque = false

        // Full mobile Safari user agent
        webView.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4_1 like Mac OS X) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
            "Version/17.4.1 Mobile/15E148 Safari/604.1"

        view.insertSubview(webView, at: 0)

        // Observe loading progress
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
            DispatchQueue.main.async {
                let p = Float(change.newValue ?? 0)
                self?.progressBar.progress = p
                UIView.animate(withDuration: 0.2) {
                    self?.progressBar.alpha = p >= 1.0 ? 0 : 1
                }
            }
        }

        // Observe back/forward
        backObservation = webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateNavButtons() }
        }
        forwardObservation = webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateNavButtons() }
        }
    }

    func makeScript(_ source: String, time: WKUserScriptInjectionTime, mainOnly: Bool) -> WKUserScript {
        WKUserScript(source: source, injectionTime: time, forMainFrameOnly: mainOnly)
    }

    // MARK: - Progress Bar
    func setupProgressBar() {
        progressBar = UIProgressView(progressViewStyle: .bar)
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.tintColor = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        progressBar.trackTintColor = .clear
        progressBar.alpha = 0
        progressBar.layer.zPosition = 100
        view.addSubview(progressBar)
    }

    // MARK: - Toolbar with Search Bar
    func setupToolbar() {
        // Main toolbar background
        toolbar = UIView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1.0)
        view.addSubview(toolbar)

        // Separator line at top of toolbar
        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        toolbar.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: toolbar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5)
        ])

        // MARK: - Search Bar Row
        let searchContainer = UIView()
        searchContainer.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.backgroundColor = UIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)
        toolbar.addSubview(searchContainer)

        searchBar = UISearchBar()
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.placeholder = "Search YouTube"
        searchBar.barStyle = .black
        searchBar.backgroundColor = UIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)
        searchBar.delegate = self
        searchBar.searchBarStyle = .minimal

        // Customize search bar text color
        if let textField = searchBar.value(forKey: "searchField") as? UITextField {
            textField.textColor = .white
            textField.backgroundColor = UIColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1.0)
        }

        searchContainer.addSubview(searchBar)

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: searchContainer.topAnchor, constant: 4),
            searchBar.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor),
            searchBar.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: -4),
            searchBar.heightAnchor.constraint(equalToConstant: 44)
        ])

        // MARK: - Navigation Buttons Row
        backButton    = makeToolbarButton(sfSymbol: "chevron.left",      action: #selector(goBack))
        forwardButton = makeToolbarButton(sfSymbol: "chevron.right",     action: #selector(goForward))
        homeButton    = makeToolbarButton(sfSymbol: "house.fill",        action: #selector(goHome))
        libraryButton = makeToolbarButton(sfSymbol: "rectangle.stack.fill", action: #selector(goLibrary))
        refreshButton = makeToolbarButton(sfSymbol: "arrow.clockwise",   action: #selector(refreshPage))

        let navStack = UIStackView(arrangedSubviews: [backButton, forwardButton, refreshButton, homeButton, libraryButton])
        navStack.translatesAutoresizingMaskIntoConstraints = false
        navStack.axis = .horizontal
        navStack.distribution = .fillEqually
        navStack.alignment = .center
        navStack.spacing = 0
        toolbar.addSubview(navStack)

        // Stack views inside toolbar
        let mainStack = UIStackView(arrangedSubviews: [searchContainer, navStack])
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.axis = .vertical
        mainStack.distribution = .fill
        mainStack.alignment = .fill
        mainStack.spacing = 0
        toolbar.addSubview(mainStack)

        NSLayoutConstraint.activate([
            // Search container height
            searchContainer.heightAnchor.constraint(equalToConstant: 52),

            // Navigation stack height
            navStack.heightAnchor.constraint(equalToConstant: toolbarHeight),

            // Main stack fills toolbar
            mainStack.topAnchor.constraint(equalTo: toolbar.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor)
        ])

        updateNavButtons()
    }

    func makeToolbarButton(sfSymbol: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        btn.setImage(UIImage(systemName: sfSymbol, withConfiguration: config), for: .normal)
        btn.tintColor = .white
        btn.addTarget(self, action: action, for: .touchUpInside)
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }

    // MARK: - Constraints (SAFE AREA AWARE)
    func setupConstraints() {
        guard webView != nil else { return }

        NSLayoutConstraint.activate([
            // Progress bar — sits BELOW safe area at top
            progressBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 3),

            // WebView — respects safe area at TOP and bottom (above toolbar)
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 3),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),

            // Toolbar — pinned to SAFE AREA bottom
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            // Let toolbar size itself based on content
            toolbar.heightAnchor.constraint(greaterThanOrEqualToConstant: toolbarHeight + 52)
        ])
    }

    // MARK: - Navigation Actions
    @objc func goBack()    { if webView.canGoBack    { webView.goBack() } }
    @objc func goForward() { if webView.canGoForward { webView.goForward() } }
    @objc func goHome()    { loadYouTube() }
    @objc func goLibrary() {
        let url = URL(string: "https://m.youtube.com/feed/library")!
        webView.load(URLRequest(url: url))
    }
    @objc func refreshPage() { webView.reload() }

    func updateNavButtons() {
        guard webView != nil else { return }
        backButton.alpha    = webView.canGoBack    ? 1.0 : 0.35
        forwardButton.alpha = webView.canGoForward ? 1.0 : 0.35
        backButton.isEnabled    = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    // MARK: - Load YouTube
    func loadYouTube() {
        let url = URL(string: "https://m.youtube.com")!
        webView.load(URLRequest(url: url))
    }

    // MARK: - Ad Blocking (synchronous completion before WebView creation)
    func compileAdBlockRules(for config: WKWebViewConfiguration, completion: @escaping () -> Void) {
        let rules = """
        [
          {"trigger":{"url-filter":".*\\\\.doubleclick\\\\.net"},"action":{"type":"block"}},
          {"trigger":{"url-filter":".*googlesyndication\\\\.com"},"action":{"type":"block"}},
          {"trigger":{"url-filter":".*youtube\\\\.com\\\\/pagead"},"action":{"type":"block"}},
          {"trigger":{"url-filter":".*youtube\\\\.com\\\\/api\\\\/stats\\\\/ads"},"action":{"type":"block"}},
          {"trigger":{"url-filter":".*\\\\.googleadservices\\\\.com"},"action":{"type":"block"}},
          {"trigger":{"url-filter":".*\\\\.googletagservices\\\\.com"},"action":{"type":"block"}},
          {"trigger":{"url-filter":".*ads\\\\.youtube\\\\.com"},"action":{"type":"block"}},
          {"trigger":{"url-filter":".*\\\\.adnxs\\\\.com"},"action":{"type":"block"}},
          {"trigger":{"url-filter":".*\\\\.2mdn\\\\.net"},"action":{"type":"block"}}
        ]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "YTAdBlock",
            encodedContentRuleList: rules
        ) { ruleList, error in
            if let ruleList = ruleList {
                config.userContentController.add(ruleList)
            } else if let error = error {
                print("Ad-block rule compile error: \(error)")
            }
            completion()
        }
    }

    // MARK: - JavaScript Injections

    func spoofJS() -> String { """
    (function() {
        'use strict';
        try {
            Object.defineProperty(window, 'webkit', {
                get: function() { return undefined; },
                configurable: false,
                enumerable: false
            });
        } catch(e) {}

        const safariUA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4_1 like Mac OS X) ' +
                         'AppleWebKit/605.1.15 (KHTML, like Gecko) ' +
                         'Version/17.4.1 Mobile/15E148 Safari/604.1';
        try {
            Object.defineProperty(navigator, 'userAgent', {
                get: () => safariUA, configurable: false
            });
        } catch(e) {}

        try {
            Object.defineProperty(navigator, 'webdriver', {
                get: () => false, configurable: false
            });
        } catch(e) {}

        try {
            Object.defineProperty(navigator, 'platform', {
                get: () => 'iPhone', configurable: false
            });
        } catch(e) {}

        if (window.MediaSource) {
            const origIsTypeSupported = MediaSource.isTypeSupported.bind(MediaSource);
            MediaSource.isTypeSupported = function(type) {
                if (type.includes('avc1') || type.includes('mp4a')) return true;
                return origIsTypeSupported(type);
            };
        }
    })();
    """ }

    func visibilityJS() -> String { """
    (function() {
        try {
            Object.defineProperty(document, 'hidden', {
                get: () => false, configurable: true
            });
            Object.defineProperty(document, 'visibilityState', {
                get: () => 'visible', configurable: true
            });
        } catch(e) {}

        document.addEventListener('visibilitychange', function(e) {
            e.stopImmediatePropagation();
        }, true);
        document.addEventListener('webkitvisibilitychange', function(e) {
            e.stopImmediatePropagation();
        }, true);

        window.addEventListener('pagehide', function(e) {
            e.stopImmediatePropagation();
        }, true);
    })();
    """ }

    func adSkipJS() -> String { """
    (function() {
        function skipAds() {
            const skipSelectors = [
                '.ytp-skip-ad-button',
                '.ytp-ad-skip-button',
                '.ytp-ad-skip-button-modern',
                'button[class*="skip"]'
            ];
            for (const sel of skipSelectors) {
                const btn = document.querySelector(sel);
                if (btn) { btn.click(); return; }
            }

            const video = document.querySelector('video');
            const adShowing = document.querySelector('.ad-showing');
            if (video && adShowing) {
                video.playbackRate = 16.0;
                if (video.duration && isFinite(video.duration)) {
                    video.currentTime = video.duration - 0.1;
                }
            }

            const overlayAds = [
                '.ytp-ad-overlay-container',
                '.ytp-ad-text-overlay',
                '.ytp-ad-image-overlay',
                '.ytd-banner-promo-renderer',
                '.ytd-statement-banner-renderer',
                'ytd-ad-slot-renderer',
                'ytd-promoted-sparkles-web-renderer',
                '#masthead-ad',
                '.ytd-rich-section-renderer[is-ads]'
            ];
            for (const sel of overlayAds) {
                document.querySelectorAll(sel).forEach(el => {
                    el.style.display = 'none';
                    el.remove();
                });
            }

            document.querySelectorAll('ytd-ad-slot-renderer, ytm-promoted-video-renderer').forEach(el => {
                el.closest('ytd-rich-item-renderer, ytm-item-section-renderer')?.remove();
                el.remove();
            });
        }

        skipAds();
        setInterval(skipAds, 400);

        const observer = new MutationObserver(() => skipAds());
        observer.observe(document.body || document.documentElement, {
            childList: true,
            subtree: true
        });
    })();
    """ }

    deinit {
        progressObservation?.invalidate()
        backObservation?.invalidate()
        forwardObservation?.invalidate()
    }
}

// MARK: - WKNavigationDelegate
extension ViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progressBar.alpha = 1
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(visibilityJS(), completionHandler: nil)
        webView.evaluateJavaScript(adSkipJS(), completionHandler: nil)
        updateNavButtons()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        progressBar.alpha = 0
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        progressBar.alpha = 0
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
    }
}

// MARK: - WKUIDelegate
extension ViewController: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

// MARK: - UISearchBarDelegate
extension ViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        guard let query = searchBar.text, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }

        // Build YouTube search URL
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let searchURL = URL(string: "https://m.youtube.com/results?search_query=\(encodedQuery)")!
        webView.load(URLRequest(url: searchURL))

        // Dismiss keyboard
        searchBar.resignFirstResponder()
    }
}
