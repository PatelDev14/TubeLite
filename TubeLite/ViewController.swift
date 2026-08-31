import UIKit
import WebKit
import AVFoundation
import MediaPlayer

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
    var audioSaverButton: UIButton!
    var searchBar: UISearchBar!

    // KVO observations
    var progressObservation: NSKeyValueObservation?
    var backObservation: NSKeyValueObservation?
    var forwardObservation: NSKeyValueObservation?

    let toolbarHeight: CGFloat = 56

    /// Only force-play while the app is backgrounded / locked
    private var isInBackground = false
    private var nativeUserPaused = false
    private var bgResumeTimer: Timer?

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        setupAudioSession()
        setupProgressBar()
        setupToolbar()
        setupRemoteCommandCenter()
        prepareWebViewAndLoad()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(forceKeepPlaying),
            name: .forceKeepPlaying,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        func setupRemoteCommandCenter() {
            let cc = MPRemoteCommandCenter.shared()
            cc.pauseCommand.isEnabled = true
            cc.playCommand.isEnabled = true
            cc.togglePlayPauseCommand.isEnabled = true

            cc.pauseCommand.addTarget { [weak self] _ in
                self?.nativeUserPaused = true
                self?.webView?.evaluateJavaScript(
                    "var v=document.querySelector('video'); if(v) v.pause();", completionHandler: nil)
                return .success
            }
            cc.playCommand.addTarget { [weak self] _ in
                self?.nativeUserPaused = false
                self?.webView?.evaluateJavaScript(
                    "var v=document.querySelector('video'); if(v) v.play();", completionHandler: nil)
                return .success
            }
            cc.togglePlayPauseCommand.addTarget { [weak self] _ in
                guard let self = self else { return .commandFailed }
                self.nativeUserPaused.toggle()
                let js = self.nativeUserPaused
                    ? "var v=document.querySelector('video'); if(v) v.pause();"
                    : "var v=document.querySelector('video'); if(v) v.play();"
                self.webView?.evaluateJavaScript(js, completionHandler: nil)
                return .success
            }
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    deinit {
        progressObservation?.invalidate()
        backObservation?.invalidate()
        forwardObservation?.invalidate()
        NotificationCenter.default.removeObserver(self)
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

    // MARK: - Background / Foreground control of force-play
    @objc func forceKeepPlaying() {
        guard webView != nil else { return }
        isInBackground = true
        startBackgroundResumeTimer()
    }

    @objc func appWillEnterForeground() {
        isInBackground = false
        stopBackgroundResumeTimer()
        resumeIfNeeded()
    }

    private func startBackgroundResumeTimer() {
        stopBackgroundResumeTimer()
        resumeIfNeeded()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.resumeIfNeeded()
        }
        RunLoop.main.add(t, forMode: .common)
        bgResumeTimer = t
    }

    private func stopBackgroundResumeTimer() {
        bgResumeTimer?.invalidate()
        bgResumeTimer = nil
    }

    private func resumeIfNeeded() {
        guard webView != nil, !nativeUserPaused else { return }
        webView.evaluateJavaScript("""
            (function() {
                var v = document.querySelector('video');
                if (v && v.paused && !v.ended) {
                    var p = v.play();
                    if (p && p.catch) p.catch(function(){});
                }
            })();
        """, completionHandler: nil)
    }
    
    // MARK: - WebView (created only after ad-block rules are compiled)
    func prepareWebViewAndLoad() {
        let config = WKWebViewConfiguration()

        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true

        let ucc = config.userContentController
        ucc.addUserScript(makeScript(spoofJS(),              time: .atDocumentStart, mainOnly: false))
        ucc.addUserScript(makeScript(visibilityJS(),         time: .atDocumentStart, mainOnly: false))
        ucc.addUserScript(makeScript(adSkipJS(),             time: .atDocumentEnd,   mainOnly: true))
        ucc.addUserScript(makeScript(speedControlJS(),       time: .atDocumentEnd,   mainOnly: true))
        ucc.addUserScript(makeScript(playlistSaveButtonJS(), time: .atDocumentEnd,   mainOnly: true))
        ucc.addUserScript(makeScript(audioSaverJS(),         time: .atDocumentEnd,   mainOnly: true))
        ucc.addUserScript(makeScript(playbackStateReporterJS(), time: .atDocumentEnd, mainOnly: true))

        compileAdBlockRules(for: config) { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.createWebView(with: config)
                self.setupConstraints()
                self.loadYouTube()
            }
        }
    }
    
    func playbackStateReporterJS() -> String { """
    (function() {
        if (window.__ytStateReporterInstalled) return;
        window.__ytStateReporterInstalled = true;
        window.__ytLastGesture = 0;

        ['touchend', 'mouseup', 'click'].forEach(function(evt) {
            document.addEventListener(evt, function() {
                window.__ytLastGesture = Date.now();
            }, true);
        });

        function attach(v) {
            if (!v || v.__ytStateReported) return;
            v.__ytStateReported = true;
            v.addEventListener('pause', function() {
                // Only report as a REAL pause if it followed an actual tap.
                // A pause with no recent tap is WebKit stalling the video in
                // the background — native ignores it and keeps resuming.
                if (Date.now() - window.__ytLastGesture < 600) {
                    window.location.href = 'yttube://state?paused=1';
                }
            });
            v.addEventListener('play', function() {
                window.location.href = 'yttube://state?paused=0';
            });
        }

        new MutationObserver(function() {
            attach(document.querySelector('video'));
        }).observe(document.documentElement, { childList: true, subtree: true });

        attach(document.querySelector('video'));
    })();
    """ }
    
    func handleStateScheme(_ url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let val = comps.queryItems?.first(where: { $0.name == "paused" })?.value
        else { return }
        nativeUserPaused = (val == "1")
    }

    func createWebView(with config: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = .black
        webView.isOpaque = false

        webView.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4_1 like Mac OS X) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
            "Version/17.4.1 Mobile/15E148 Safari/604.1"

        view.insertSubview(webView, at: 0)

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
            DispatchQueue.main.async {
                let p = Float(change.newValue ?? 0)
                self?.progressBar.progress = p
                UIView.animate(withDuration: 0.2) {
                    self?.progressBar.alpha = p >= 1.0 ? 0 : 1
                }
            }
        }

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
        toolbar = UIView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1.0)
        view.addSubview(toolbar)

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

        backButton    = makeToolbarButton(sfSymbol: "chevron.left",      action: #selector(goBack))
        forwardButton = makeToolbarButton(sfSymbol: "chevron.right",     action: #selector(goForward))
        homeButton    = makeToolbarButton(sfSymbol: "house.fill",        action: #selector(goHome))
        libraryButton = makeToolbarButton(sfSymbol: "rectangle.stack.fill", action: #selector(goLibrary))
        refreshButton = makeToolbarButton(sfSymbol: "arrow.clockwise",   action: #selector(refreshPage))
        audioSaverButton = makeToolbarButton(sfSymbol: "bolt.slash.fill", action: #selector(toggleAudioSaver))

        let navStack = UIStackView(arrangedSubviews: [backButton, forwardButton, refreshButton, homeButton, audioSaverButton, libraryButton])
        navStack.translatesAutoresizingMaskIntoConstraints = false
        navStack.axis = .horizontal
        navStack.distribution = .fillEqually
        navStack.alignment = .center
        navStack.spacing = 0
        toolbar.addSubview(navStack)

        let mainStack = UIStackView(arrangedSubviews: [searchContainer, navStack])
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.axis = .vertical
        mainStack.distribution = .fill
        mainStack.alignment = .fill
        mainStack.spacing = 0
        toolbar.addSubview(mainStack)

        NSLayoutConstraint.activate([
            searchContainer.heightAnchor.constraint(equalToConstant: 52),
            navStack.heightAnchor.constraint(equalToConstant: toolbarHeight),
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

    // MARK: - Constraints
    func setupConstraints() {
        guard webView != nil else { return }

        NSLayoutConstraint.activate([
            progressBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 3),

            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 3),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            toolbar.heightAnchor.constraint(greaterThanOrEqualToConstant: toolbarHeight + 52)
        ])
    }

    // MARK: - Navigation Actions
    @objc func goBack()    { if webView.canGoBack    { webView.goBack() } }
    @objc func goForward() { if webView.canGoForward { webView.goForward() } }
    @objc func goHome()    { loadYouTube() }

    @objc func goLibrary() {
        let vc = PlaylistViewController()
        vc.onSelect = { [weak self] item in
            guard let url = URL(string: item.url) else { return }
            self?.webView.load(URLRequest(url: url))
        }
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    @objc func refreshPage() { webView.reload() }

    @objc func toggleAudioSaver() {
        webView.evaluateJavaScript("window.__ytToggleAudioSaver && window.__ytToggleAudioSaver();") { [weak self] result, _ in
            DispatchQueue.main.async {
                let isOn = (result as? Bool) ?? false
                self?.audioSaverButton.tintColor = isOn ? .systemGreen : .white
            }
        }
    }

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

    // MARK: - Custom URL scheme (native save handoff)
    func handleAppScheme(_ url: URL) {
        guard url.host == "save",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let dataParam = components.queryItems?.first(where: { $0.name == "data" })?.value,
              let decoded = dataParam.removingPercentEncoding,
              let data = decoded.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let title = json["title"], let videoURL = json["url"]
        else { return }

        let thumb = json["thumb"]
        let playlists = PlaylistManager.shared.playlists
        let sheet = UIAlertController(title: "Save to Playlist", message: title, preferredStyle: .actionSheet)
        for pl in playlists {
            sheet.addAction(UIAlertAction(title: pl.name, style: .default) { _ in
                PlaylistManager.shared.save(title: title, url: videoURL, thumb: thumb, toPlaylist: pl.id)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    // MARK: - Ad Blocking
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
        'use strict';
        try {
            Object.defineProperty(document, 'hidden', {
                get: function() { return false; },
                configurable: true
            });
            Object.defineProperty(document, 'visibilityState', {
                get: function() { return 'visible'; },
                configurable: true
            });
            Object.defineProperty(document, 'webkitHidden', {
                get: function() { return false; },
                configurable: true
            });
            Object.defineProperty(document, 'webkitVisibilityState', {
                get: function() { return 'visible'; },
                configurable: true
            });
        } catch(e) {}

        try {
            document.hasFocus = function() { return true; };
        } catch(e) {}

        function block(e) {
            e.stopImmediatePropagation();
            e.stopPropagation();
            e.preventDefault();
        }
        var events = [
            'visibilitychange', 'webkitvisibilitychange',
            'pagehide', 'pageshow', 'freeze', 'resume',
            'blur', 'focus', 'focusin', 'focusout'
        ];
        events.forEach(function(evt) {
            window.addEventListener(evt, block, true);
            document.addEventListener(evt, block, true);
        });

        try {
            Object.defineProperty(window, 'outerWidth', {
                get: function() { return window.innerWidth; },
                configurable: true
            });
        } catch(e) {}
    })();
    """ }

    /// Safe ad-skip: clicks skip buttons + hides ad overlays only.
    /// Deliberately does NOT touch currentTime/playbackRate on the real
    /// video — that trick was jumping the actual video, not just ads.
    func adSkipJS() -> String { """
    (function() {
        if (typeof window.__ytPrevRate === 'undefined') window.__ytPrevRate = 1;

        function realClick(el) {
            var opts = { bubbles: true, cancelable: true, view: window };
            el.dispatchEvent(new PointerEvent('pointerdown', opts));
            el.dispatchEvent(new MouseEvent('mousedown', opts));
            el.dispatchEvent(new PointerEvent('pointerup', opts));
            el.dispatchEvent(new MouseEvent('mouseup', opts));
            el.dispatchEvent(new MouseEvent('click', opts));
            el.click();
        }

        function skipAds() {
            var skipSelectors = [
                '.ytp-skip-ad-button',
                '.ytp-ad-skip-button',
                '.ytp-ad-skip-button-modern',
                '.ytp-ad-skip-button-container button',
                '.ytp-ad-overlay-close-button',
                'button[class*="skip"]'
            ];
            for (var i = 0; i < skipSelectors.length; i++) {
                var btn = document.querySelector(skipSelectors[i]);
                if (btn) { realClick(btn); }
            }

            var overlaySelectors = [
                '.ytp-ad-overlay-container', '.ytp-ad-text-overlay', '.ytp-ad-image-overlay',
                '.ytd-banner-promo-renderer', '.ytd-statement-banner-renderer',
                'ytd-ad-slot-renderer', 'ytd-promoted-sparkles-web-renderer',
                '#masthead-ad', '#player-ads', '.ytd-rich-section-renderer[is-ads]'
            ];
            overlaySelectors.forEach(function(sel) {
                document.querySelectorAll(sel).forEach(function(el) {
                    el.style.display = 'none';
                    el.remove();
                });
            });

            document.querySelectorAll('ytd-ad-slot-renderer, ytm-promoted-video-renderer').forEach(function(el) {
                var parent = el.closest('ytd-rich-item-renderer, ytm-item-section-renderer');
                if (parent) { parent.remove(); } else { el.remove(); }
            });

            var video = document.querySelector('video');
            var player = document.querySelector('#movie_player, .html5-video-player');
            var classAd = player && (player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting'));
            if (video && classAd && isFinite(video.duration) && video.duration < 60 && video.currentTime < 2) {
                video.currentTime = video.duration - 0.05;
            }
        }

        skipAds();
        setInterval(skipAds, 300);

        var observer = new MutationObserver(function() { skipAds(); });
        observer.observe(document.body || document.documentElement, { childList: true, subtree: true });
    })();
    """ }

    /// Floating speed control (+/-), persists via localStorage, works on
    /// both regular videos and Shorts.
    func speedControlJS() -> String { """
    (function() {
        if (window.__ytSpeedInstalled) return;
        window.__ytSpeedInstalled = true;

        var SPEEDS = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0];
        var cur = parseFloat(localStorage.getItem('yt_spd') || '1.0');
        var idx = SPEEDS.indexOf(cur);
        if (idx < 0) idx = SPEEDS.indexOf(1.0);

        function getVideo() {
            var vids = Array.from(document.querySelectorAll('video'));
            if (!vids.length) return null;
            if (vids.length === 1) return vids[0];
            var active = document.querySelector('ytd-reel-video-renderer[is-active] video, ytd-shorts video.html5-main-video');
            if (active) return active;
            var playing = vids.find(function(v) {
                var r = v.getBoundingClientRect();
                return r.width > 0 && !v.paused;
            });
            if (playing) return playing;
            var visible = vids.find(function(v) {
                var r = v.getBoundingClientRect();
                return r.width > 0;
            });
            return visible || vids[0];
        }

        function applySpeed() {
            var v = getVideo();
            if (v) v.playbackRate = cur;
            var el = document.getElementById('yt-spd-label');
            if (el) el.textContent = cur === 1.0 ? '1x' : cur.toFixed(2) + 'x';
        }

        function save() { localStorage.setItem('yt_spd', cur); }
        function cycleFwd() { idx = (idx + 1) % SPEEDS.length; cur = SPEEDS[idx]; save(); applySpeed(); }
        function cycleBack() { idx = (idx - 1 + SPEEDS.length) % SPEEDS.length; cur = SPEEDS[idx]; save(); applySpeed(); }

        function addUI() {
            if (document.getElementById('yt-spd-btn')) return;
            var btn = document.createElement('div');
            btn.id = 'yt-spd-btn';
            btn.style.cssText = 'position:fixed;bottom:72px;right:12px;z-index:999999;background:rgba(0,0,0,0.78);border-radius:22px;display:flex;align-items:center;overflow:hidden;user-select:none;box-shadow:0 2px 12px rgba(0,0,0,0.5);';
            var tapStyle = 'padding:10px 10px;color:white;font-size:18px;font-weight:700;cursor:pointer;background:transparent;border:none;line-height:1;';
            btn.innerHTML = '<button id="yt-spd-dn" style="' + tapStyle + '">-</button>' +
                '<span id="yt-spd-label" style="color:white;font-size:13px;font-weight:700;min-width:36px;text-align:center;">' +
                (cur === 1.0 ? '1x' : cur.toFixed(2) + 'x') + '</span>' +
                '<button id="yt-spd-up" style="' + tapStyle + '">+</button>';
            document.body.appendChild(btn);
            document.getElementById('yt-spd-up').addEventListener('click', cycleFwd);
            document.getElementById('yt-spd-dn').addEventListener('click', cycleBack);
        }

        new MutationObserver(function() {
            applySpeed();
            addUI();
        }).observe(document.documentElement, { childList: true, subtree: true });

        document.addEventListener('yt-navigate-finish', function() {
            window.__ytSpeedInstalled = false;
            var el = document.getElementById('yt-spd-btn');
            if (el) el.remove();
        });

        document.addEventListener('keydown', function(e) {
            var tag = document.activeElement && document.activeElement.tagName;
            if (tag === 'INPUT' || tag === 'TEXTAREA') return;
            if (e.key === ']') cycleFwd();
            else if (e.key === '[') cycleBack();
        });

        addUI();
        applySpeed();
    })();
    """ }

    /// Adds a "+ Save" button on watch pages that hands the video title,
    /// URL, and thumbnail back to native via a custom URL scheme.
    func playlistSaveButtonJS() -> String { #"""
    (function() {
        if (window.__ytSaveBtnInstalled) return;
        window.__ytSaveBtnInstalled = true;

        function tryInject() {
            if (location.pathname.indexOf('/watch') !== 0 && location.pathname.indexOf('/shorts') !== 0) return;
            if (document.getElementById('yt-native-save-btn')) return;

            var titleEl = document.querySelector(
                'h1.slim-video-information-title span, h1.slim-video-information-title, .slim-video-information-title, ytm-slim-video-metadata-renderer h2, ytd-watch-metadata h1 yt-formatted-string, h1'
            );
            var title = (titleEl && titleEl.textContent.trim()) || document.title.replace(' - YouTube', '');
            var url = location.href;

            var vidMatch = url.match(/[?&]v=([^&]+)/) || location.pathname.match(/\/shorts\/([^/?]+)/);
            var videoId = vidMatch ? vidMatch[1] : null;
            var thumb = videoId ? ('https://i.ytimg.com/vi/' + videoId + '/mqdefault.jpg') : '';

            var btn = document.createElement('button');
            btn.id = 'yt-native-save-btn';
            btn.textContent = '+ Save';
            btn.style.cssText = 'position:fixed;top:60px;left:12px;z-index:999999;background:#ff0000;color:white;border:none;border-radius:20px;padding:7px 14px;font-size:13px;font-weight:700;cursor:pointer;box-shadow:0 2px 8px rgba(0,0,0,0.4);';
            btn.addEventListener('click', function() {
                var encoded = encodeURIComponent(JSON.stringify({ title: title, url: url, thumb: thumb }));
                window.location.href = 'yttube://save?data=' + encoded;
                btn.textContent = 'Saved';
                btn.style.background = '#333';
                setTimeout(function() { btn.textContent = '+ Save'; btn.style.background = '#ff0000'; }, 2000);
            });
            document.body.appendChild(btn);
        }

        new MutationObserver(tryInject).observe(document.documentElement, { childList: true, subtree: true });
        document.addEventListener('yt-navigate-finish', function() {
            var el = document.getElementById('yt-native-save-btn');
            if (el) el.remove();
            window.__ytSaveBtnInstalled = false;
        });
        tryInject();
    })();
    """# }

    /// Toggleable battery saver: shrinks video to near-zero size and
    /// forces lowest playback quality while leaving audio untouched.
    func audioSaverJS() -> String { """
    (function() {
        if (window.__ytAudioSaverInstalled) return;
        window.__ytAudioSaverInstalled = true;
        window.__ytAudioSaverOn = window.__ytAudioSaverOn || false;

        function applyState() {
            var video = document.querySelector('video');
            var player = document.querySelector('#movie_player, .html5-video-player');
            if (!video) return;

            if (window.__ytAudioSaverOn) {
                video.style.transform = 'scale(0.001)';
                video.style.transformOrigin = 'top left';
                video.style.opacity = '0';
                try {
                    if (player && player.setPlaybackQualityRange) player.setPlaybackQualityRange('tiny', 'tiny');
                    if (player && player.setPlaybackQuality) player.setPlaybackQuality('tiny');
                } catch(e) {}
            } else {
                video.style.transform = '';
                video.style.opacity = '';
            }
        }

        window.__ytToggleAudioSaver = function() {
            window.__ytAudioSaverOn = !window.__ytAudioSaverOn;
            applyState();
            return window.__ytAudioSaverOn;
        };

        new MutationObserver(applyState).observe(document.documentElement, { childList: true, subtree: true });
        applyState();
    })();
    """ }
}

// MARK: - WKNavigationDelegate
extension ViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progressBar.alpha = 1
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(visibilityJS(), completionHandler: nil)
        //webView.evaluateJavaScript(keepPlayingJS(), completionHandler: nil)
        let flag = isInBackground ? "true" : "false"
        webView.evaluateJavaScript("window.__ytForcePlay = \(flag);", completionHandler: nil)
        webView.evaluateJavaScript(adSkipJS(), completionHandler: nil)
        webView.evaluateJavaScript(speedControlJS(), completionHandler: nil)
        webView.evaluateJavaScript(playlistSaveButtonJS(), completionHandler: nil)
        webView.evaluateJavaScript(audioSaverJS(), completionHandler: nil)
        webView.evaluateJavaScript(playbackStateReporterJS(), completionHandler: nil)
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

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.scheme == "yttube" {
            if url.host == "save" { handleAppScheme(url) }
            else if url.host == "state" { handleStateScheme(url) }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
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

        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let searchURL = URL(string: "https://m.youtube.com/results?search_query=\(encodedQuery)")!
        webView.load(URLRequest(url: searchURL))

        searchBar.resignFirstResponder()
    }
}
