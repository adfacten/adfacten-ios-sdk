import UIKit

/// Full-screen presentation used by interstitial, rewarded and app-open ads.
@MainActor
final class FullScreenAdViewController: UIViewController {
    struct Options {
        var rewarded: Bool
        /// Seconds (of on-screen time) before the close button appears.
        var closeAfter: TimeInterval
        /// Rewarded non-video: on-screen seconds needed for completion.
        var rewardAfter: TimeInterval
    }

    var onShown: (() -> Void)?
    var onClick: (() -> Void)?
    var onReward: (() -> Void)?
    var onClosed: (() -> Void)?

    private let ad: LoadedAd
    private let context: SDKContext
    private let options: Options
    private let preloadedImage: UIImage?
    private var creative: CreativeView?
    private var video: VideoCreativeView? { creative as? VideoCreativeView }
    private var tracker: ViewabilityTracker?

    private let closeButton = UIButton(type: .custom)
    private let countdownLabel = UILabel()
    private let muteButton = UIButton(type: .custom)
    private let badge: AdBadge
    private var visibleTime: TimeInterval = 0
    private var closeAvailable = false
    private var completed = false
    private var rewarded = false
    private var finished = false
    private var observers: [NSObjectProtocol] = []

    init(ad: LoadedAd, context: SDKContext, options: Options, preloadedImage: UIImage?) {
        self.ad = ad
        self.context = context
        self.options = options
        self.preloadedImage = preloadedImage
        self.badge = AdBadge(text: Strings.label(ad.payload.label))
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    required init?(coder: NSCoder) { nil }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let content = makeCreative()
        creative = content
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        layoutCreative(content)

        view.addSubview(badge)
        setupCountdown()
        setupClose()
        if video != nil { setupMute() }

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            badge.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
        ])

        let t = ViewabilityTracker(view: content, rule: ad.viewRule, isActive: context.env.appIsActive)
        t.onRender = { [weak self] in self?.didRender() }
        t.onViewable = { [weak self] in
            guard let self else { return }
            self.context.fire(.view, for: self.ad)
            self.checkCompletion()
        }
        t.onVisibleTime = { [weak self] dt in self?.addVisibleTime(dt) }
        tracker = t

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.video?.pauseForBackground() }
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.video?.resumeFromBackground() }
        })
        updateCloseUI()
    }

    private var appeared = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !appeared else { return }
        appeared = true
        creative?.startLoading()
        tracker?.start()
        onShown?()
        onShown = nil
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Dismissed by someone else (e.g. the app tore down its stack): still report the close.
        if !finished, isBeingDismissed || presentingViewController == nil {
            finished = true
            context.fire(.close, for: ad)
            teardown()
            let done = onClosed
            onClosed = nil
            done?()
        }
    }

    // MARK: Building

    private func makeCreative() -> CreativeView {
        let c: CreativeView
        switch ad.payload.kind {
        case .video:
            if let vast = ad.vast,
               let media = MediaSelector.select(vast.mediaFiles,
                                                screenPx: (Int(UIScreen.main.nativeBounds.width), Int(UIScreen.main.nativeBounds.height)),
                                                connection: context.connection.current) {
                let v = VideoCreativeView(vast: vast, media: media)
                v.onEvent = { [weak self] name, pos in self?.videoEvent(name, pos) }
                v.onProgress = { [weak self] pos, dur in self?.videoProgress(pos, dur) }
                v.onComplete = { [weak self] in self?.videoCompleted() }
                c = v
            } else {
                c = ImageCreativeView(image: nil, preloaded: nil, loader: nil)
            }
        case .html:
            c = HTMLCreativeView(html: ad.payload.html ?? "")
        default:
            c = ImageCreativeView(image: ad.payload.image, preloaded: preloadedImage, loader: context.images)
        }
        c.onReady = { [weak self] in self?.tracker?.contentReady = true }
        c.onFailure = { [weak self] err in self?.creativeFailed(err) }
        c.onTap = { [weak self] url in self?.handleTap(url) }
        return c
    }

    private func layoutCreative(_ c: UIView) {
        let guide = view.safeAreaLayoutGuide
        if c is VideoCreativeView {
            NSLayoutConstraint.activate([
                c.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                c.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                c.topAnchor.constraint(equalTo: view.topAnchor),
                c.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            return
        }
        // Image / HTML: keep the creative's aspect ratio, as large as fits inside the safe area.
        let w = CGFloat(ad.payload.w ?? 0), h = CGFloat(ad.payload.h ?? 0)
        var cs: [NSLayoutConstraint] = [
            c.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            c.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            c.widthAnchor.constraint(lessThanOrEqualTo: guide.widthAnchor),
            c.heightAnchor.constraint(lessThanOrEqualTo: guide.heightAnchor, constant: -56),
        ]
        if w > 0, h > 0, ad.payload.kind == .html {
            cs.append(c.widthAnchor.constraint(equalTo: c.heightAnchor, multiplier: w / h))
            let fillW = c.widthAnchor.constraint(equalTo: guide.widthAnchor)
            fillW.priority = .defaultHigh
            let fillH = c.heightAnchor.constraint(equalTo: guide.heightAnchor, constant: -56)
            fillH.priority = .defaultHigh - 1
            cs += [fillW, fillH]
        } else {
            let fw = c.widthAnchor.constraint(equalTo: guide.widthAnchor)
            fw.priority = .defaultHigh
            let fh = c.heightAnchor.constraint(equalTo: guide.heightAnchor, constant: -56)
            fh.priority = .defaultHigh
            cs += [fw, fh]
        }
        NSLayoutConstraint.activate(cs)
    }

    private func setupCountdown() {
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        countdownLabel.textColor = .white
        countdownLabel.textAlignment = .center
        countdownLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        countdownLabel.layer.cornerRadius = 16
        countdownLabel.layer.masksToBounds = true
        view.addSubview(countdownLabel)
        NSLayoutConstraint.activate([
            countdownLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            countdownLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            countdownLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 32),
            countdownLabel.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func setupClose() {
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        closeButton.layer.cornerRadius = 16
        closeButton.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
        closeButton.layer.borderWidth = 1
        closeButton.accessibilityLabel = Strings.close
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func setupMute() {
        muteButton.translatesAutoresizingMaskIntoConstraints = false
        muteButton.tintColor = .white
        muteButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        muteButton.layer.cornerRadius = 18
        muteButton.addTarget(self, action: #selector(muteTapped), for: .touchUpInside)
        view.addSubview(muteButton)
        NSLayoutConstraint.activate([
            muteButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            muteButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            muteButton.widthAnchor.constraint(equalToConstant: 36),
            muteButton.heightAnchor.constraint(equalToConstant: 36),
        ])
        updateMuteUI()
    }

    private func updateMuteUI() {
        let muted = video?.isMuted ?? true
        let symbol = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        muteButton.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
        muteButton.accessibilityLabel = muted ? Strings.unmute : Strings.mute
    }

    // MARK: Events

    private func didRender() {
        context.fire(.render, for: ad)
        if let vast = ad.vast { context.fireExternal(vast.impressions, key: "impression", for: ad) }
    }

    private func addVisibleTime(_ dt: TimeInterval) {
        visibleTime += dt
        if !closeAvailable, visibleTime >= options.closeAfter { closeAvailable = true }
        checkCompletion()
        updateCloseUI()
    }

    /// Non-video completion: rewarded image/HTML after the required on-screen time.
    private func checkCompletion() {
        guard !completed, ad.payload.kind != .video, options.rewarded,
              tracker?.isViewable == true, visibleTime >= options.rewardAfter else { return }
        markCompleted()
    }

    private func markCompleted() {
        guard !completed else { return }
        completed = true
        context.fire(.complete, for: ad)
        if options.rewarded, !rewarded {
            rewarded = true
            onReward?()
        }
        closeAvailable = true
        updateCloseUI()
    }

    private func videoEvent(_ name: String, _ pos: TimeInterval) {
        guard let vast = ad.vast else { return }
        if name.hasPrefix("progress#"), let i = Int(name.dropFirst("progress#".count)), vast.tracking.indices.contains(i) {
            context.fireExternal([vast.tracking[i].url], key: "progress#\(i)", for: ad, playhead: pos)
            return
        }
        var urls = vast.trackers(for: name)
        if name == "creativeView" { urls = vast.trackers(for: "creativeView") }
        // mute/unmute/pause/resume may repeat; key them by occurrence.
        let repeatable: Set<String> = ["mute", "unmute", "pause", "resume"]
        let key = repeatable.contains(name) ? "\(name)@\(Int(pos * 1000))" : name
        context.fireExternal(urls, key: key, for: ad, playhead: pos)
        if name == "mute" || name == "unmute" { updateMuteUI() }
    }

    private func videoProgress(_ pos: TimeInterval, _ dur: TimeInterval) {
        guard dur > 0 else { return }
        let left = max(0, Int((dur - pos).rounded(.up)))
        if !closeAvailable { countdownLabel.text = " \(left) " }
    }

    private func videoCompleted() {
        // Complete needs a valid view; a full-screen video that played to the end satisfied it
        // unless the app was backgrounded throughout — then the server's view rule decides.
        markCompleted()
    }

    private func creativeFailed(_ err: AdfactenError) {
        Log.warning("full-screen creative failed: \(err.message)")
        if let vast = ad.vast, !vast.errors.isEmpty {
            let urls = vast.errors.compactMap(URL.init(string:))
            context.fireExternal(urls, key: "error", for: ad, errorCode: 405)
        }
        closeAvailable = true
        updateCloseUI()
    }

    private func updateCloseUI() {
        closeButton.isHidden = !closeAvailable
        countdownLabel.isHidden = closeAvailable
        if !closeAvailable, video == nil {
            let left = max(0, Int((options.closeAfter - visibleTime).rounded(.up)))
            countdownLabel.text = " \(left) "
        }
    }

    private func handleTap(_ url: URL?) {
        let target = ClickTarget.resolve(clickURL: ad.clickURL, tapped: url)
        guard let target else { return }
        if ClickHandler.shared.open(target, from: self, session: context.session) {
            if let vast = ad.vast { context.fireExternal(vast.clickTracking, key: "click", for: ad) }
            onClick?()
        }
    }

    @objc private func muteTapped() {
        guard let video else { return }
        video.setMuted(!video.isMuted)
        updateMuteUI()
    }

    @objc private func closeTapped() {
        guard closeAvailable else { return }
        if options.rewarded && !rewarded {
            let alert = UIAlertController(title: Strings.skipTitle, message: Strings.skipMessage, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: Strings.keepWatching, style: .cancel))
            alert.addAction(UIAlertAction(title: Strings.closeAnyway, style: .destructive) { [weak self] _ in
                self?.finish()
            })
            present(alert, animated: true)
            return
        }
        finish()
    }

    /// Closes the ad: fires `close`, stops playback, dismisses.
    func finish() {
        guard !finished else { return }
        finished = true
        context.fire(.close, for: ad)
        if let vast = ad.vast {
            context.fireExternal(vast.trackers(for: "close") + vast.trackers(for: "closeLinear"), key: "close", for: ad,
                                 playhead: video?.position)
            if !completed { context.fireExternal(vast.trackers(for: "skip"), key: "skip", for: ad, playhead: video?.position) }
        }
        teardown()
        let done = onClosed
        onClosed = nil
        if let presenter = presentingViewController {
            presenter.dismiss(animated: true) { done?() }
        } else {
            done?()
        }
    }

    private func teardown() {
        tracker?.stop()
        video?.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
}
