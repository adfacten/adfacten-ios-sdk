import AVFoundation
import UIKit

/// Plays a VAST linear MediaFile with AVPlayer (muted by default) and reports VAST progress events.
@MainActor
final class VideoCreativeView: UIView, CreativeView {
    var onReady: (() -> Void)?
    var onFailure: ((AdfactenError) -> Void)?
    var onTap: ((URL?) -> Void)?
    /// VAST event name (start, firstQuartile, midpoint, thirdQuartile, complete, mute, unmute, pause,
    /// resume, progress-<offset>) plus the playhead.
    var onEvent: ((String, TimeInterval) -> Void)?
    var onProgress: ((_ position: TimeInterval, _ duration: TimeInterval) -> Void)?
    var onComplete: (() -> Void)?

    let media: VASTAd.MediaFile
    private let vast: VASTAd
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var startTimer: Timer?
    private var started = false
    private var completed = false
    private var firedQuartiles = Set<String>()
    private var firedProgress = Set<Int>()
    private var pausedByApp = false
    private(set) var isMuted = true

    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

    init(vast: VASTAd, media: VASTAd.MediaFile) {
        self.vast = vast
        self.media = media
        super.init(frame: .zero)
        backgroundColor = .black
        playerLayer?.videoGravity = .resizeAspect
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityLabel = Strings.advertisement
        accessibilityTraits = [.startsMediaSession, .link]
    }

    required init?(coder: NSCoder) { nil }

    @objc private func tapped() { onTap?(nil) }

    var duration: TimeInterval {
        if let item = player?.currentItem {
            let d = CMTimeGetSeconds(item.duration)
            if d.isFinite, d > 0 { return d }
        }
        return vast.duration ?? 0
    }

    var position: TimeInterval {
        guard let p = player else { return 0 }
        let t = CMTimeGetSeconds(p.currentTime())
        return t.isFinite ? max(0, t) : 0
    }

    func startLoading() {
        guard player == nil else { return }
        let item = AVPlayerItem(url: media.url)
        item.preferredForwardBufferDuration = 5
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        p.actionAtItemEnd = .pause
        p.preventsDisplaySleepDuringVideoPlayback = true
        player = p
        playerLayer?.player = p

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.progressTick() }
        }
        let nc = NotificationCenter.default
        endObserver = nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didFinish() }
        }
        failObserver = nc.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fail("playback failed") }
        }
        // A stalled CDN must not trap the user on a black screen.
        startTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.started else { return }
                self.fail("video did not start in time")
            }
        }
        p.play()
    }

    func setMuted(_ muted: Bool) {
        guard let player, muted != isMuted else { return }
        isMuted = muted
        player.isMuted = muted
        onEvent?(muted ? "mute" : "unmute", position)
    }

    func pauseForBackground() {
        guard let player, started, !completed, player.rate > 0 else { return }
        pausedByApp = true
        player.pause()
        onEvent?("pause", position)
    }

    func resumeFromBackground() {
        guard let player, pausedByApp, !completed else { return }
        pausedByApp = false
        player.play()
        onEvent?("resume", position)
    }

    func stop() {
        startTimer?.invalidate()
        startTimer = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        endObserver = nil
        failObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func progressTick() {
        guard let player, let item = player.currentItem else { return }
        if item.status == .failed { fail(item.error?.localizedDescription ?? "playback failed"); return }
        let pos = position
        if !started, pos > 0.05, player.rate > 0 {
            started = true
            startTimer?.invalidate()
            onReady?()
            onEvent?("creativeView", pos)
            onEvent?("start", pos)
        }
        guard started, !completed else { return }
        let d = duration
        onProgress?(pos, d)
        guard d > 0 else { return }
        let f = pos / d
        for (name, mark) in [("firstQuartile", 0.25), ("midpoint", 0.5), ("thirdQuartile", 0.75)]
            where f >= mark && !firedQuartiles.contains(name) {
            firedQuartiles.insert(name)
            onEvent?(name, pos)
        }
        for (i, t) in vast.tracking.enumerated() where t.event == "progress" && !firedProgress.contains(i) {
            guard let off = t.offset else { continue }
            let at = t.isFraction ? off * d : off
            if pos >= at {
                firedProgress.insert(i)
                onEvent?("progress#\(i)", pos)
            }
        }
    }

    private func didFinish() {
        guard !completed else { return }
        if !started {
            // Very short clip that ended between ticks.
            started = true
            onReady?()
            onEvent?("start", 0)
        }
        for name in ["firstQuartile", "midpoint", "thirdQuartile"] where !firedQuartiles.contains(name) {
            firedQuartiles.insert(name)
            onEvent?(name, duration)
        }
        completed = true
        onProgress?(duration, duration)
        onEvent?("complete", duration)
        onComplete?()
    }

    private func fail(_ reason: String) {
        guard !completed else { return }
        completed = true
        startTimer?.invalidate()
        Log.warning("video creative failed: \(reason)")
        onFailure?(AdfactenError(.creativeFailed, "video failed: \(reason)"))
    }
}
