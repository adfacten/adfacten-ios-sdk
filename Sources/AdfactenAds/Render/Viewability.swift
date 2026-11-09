import QuartzCore
import UIKit

/// Pure visibility math (unit tested).
enum Visibility {
    /// Fraction (0…1) of `rect` that lies inside `bounds` and inside every clipping ancestor rect.
    /// All rects are in window coordinates.
    static func geometricRatio(rect: CGRect, clips: [CGRect], bounds: CGRect) -> CGFloat {
        let area = rect.width * rect.height
        guard area > 0, rect.isNull == false, rect.isInfinite == false else { return 0 }
        var visible = rect.intersection(bounds)
        for c in clips {
            if visible.isNull || visible.isEmpty { return 0 }
            visible = visible.intersection(c)
        }
        guard !visible.isNull, !visible.isEmpty else { return 0 }
        return min(1, max(0, (visible.width * visible.height) / area))
    }

    /// The visible part of `rect` (or nil) — the region sampled for occlusion.
    static func visibleRect(rect: CGRect, clips: [CGRect], bounds: CGRect) -> CGRect? {
        var visible = rect.intersection(bounds)
        for c in clips { visible = visible.intersection(c) }
        return (visible.isNull || visible.isEmpty) ? nil : visible
    }

    /// 3×3 grid of sample points inset inside `rect`.
    static func samplePoints(in rect: CGRect) -> [CGPoint] {
        let xs = [0.15, 0.5, 0.85].map { rect.minX + rect.width * $0 }
        let ys = [0.15, 0.5, 0.85].map { rect.minY + rect.height * $0 }
        return ys.flatMap { y in xs.map { CGPoint(x: $0, y: y) } }
    }

    /// Geometric ratio reduced by the share of sample points covered by other views.
    static func combined(geometric: CGFloat, unoccludedSamples: Int, totalSamples: Int) -> CGFloat {
        guard totalSamples > 0 else { return geometric }
        return geometric * CGFloat(unoccludedSamples) / CGFloat(totalSamples)
    }

    /// Measures how much of `view` is on screen right now (0…1).
    @MainActor
    static func measure(_ view: UIView) -> CGFloat {
        guard let window = view.window, !window.isHidden, window.alpha > 0.01 else { return 0 }
        var node: UIView? = view
        var clips: [CGRect] = []
        while let n = node, n !== window {
            if n.isHidden || n.alpha < 0.01 { return 0 }
            if n !== view, n.clipsToBounds {
                clips.append(n.convert(n.bounds, to: window))
            }
            node = n.superview
        }
        let rect = view.convert(view.bounds, to: window)
        let geo = geometricRatio(rect: rect, clips: clips, bounds: window.bounds)
        guard geo > 0, let visible = visibleRect(rect: rect, clips: clips, bounds: window.bounds) else { return 0 }
        let points = samplePoints(in: visible)
        var clear = 0
        for p in points {
            guard let hit = window.hitTest(p, with: nil) else { clear += 1; continue }
            if hit === view || hit.isDescendant(of: view) || view.isDescendant(of: hit) { clear += 1 }
        }
        return combined(geometric: geo, unoccludedSamples: clear, totalSamples: points.count)
    }
}

/// Continuous-time rule: fires once after `ratio ≥ minRatio` has held for `minMs` without a break.
struct ViewRuleState: Sendable {
    let minRatio: Double
    let minMs: Double
    private(set) var accumulatedMs: Double = 0
    private(set) var satisfied = false

    init(minRatio: Double, minMs: Double) {
        self.minRatio = minRatio
        self.minMs = minMs
    }

    /// Feeds one sample. Returns true exactly once, when the rule becomes satisfied.
    mutating func tick(ratio: Double, deltaMs: Double, active: Bool) -> Bool {
        guard !satisfied else { return false }
        if active && ratio >= minRatio && ratio > 0 {
            // Cap one step so a stalled main thread can't jump the clock.
            accumulatedMs += min(max(deltaMs, 0), 250)
            if accumulatedMs >= minMs {
                satisfied = true
                return true
            }
        } else {
            accumulatedMs = 0
        }
        return false
    }
}

/// Samples a view's visibility 10× a second on the main run loop and reports render / view /
/// on-screen time. Paused while the app is not active.
@MainActor
final class ViewabilityTracker {
    private weak var view: UIView?
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var rule: ViewRuleState
    private var rendered = false
    private let isActive: @MainActor () -> Bool

    /// Set when the creative has actually drawn (image set, HTML loaded, video playing).
    var contentReady = false
    var onRender: (() -> Void)?
    var onViewable: (() -> Void)?
    /// Called each tick with the seconds the view was visible (> 0 %) since the last tick.
    var onVisibleTime: ((TimeInterval) -> Void)?
    private(set) var lastRatio: CGFloat = 0

    init(view: UIView, rule: AdPayload.ViewRule, isActive: @escaping @MainActor () -> Bool) {
        self.view = view
        self.rule = ViewRuleState(minRatio: rule.minRatio, minMs: rule.minMs)
        self.isActive = isActive
    }

    func start() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        guard let view else { stop(); return }
        let active = isActive()
        let ratio = (active && contentReady) ? Visibility.measure(view) : 0
        lastRatio = ratio
        if ratio > 0 && !rendered {
            rendered = true
            onRender?()
        }
        if rendered, rule.tick(ratio: Double(ratio), deltaMs: dt * 1000, active: active) {
            onViewable?()
        }
        if ratio > 0 { onVisibleTime?(min(dt, 0.25)) }
    }

    var isViewable: Bool { rule.satisfied }
    var hasRendered: Bool { rendered }
}
