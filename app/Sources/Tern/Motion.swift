import AppKit
import SwiftUI

/// tern's transitions: quick, eased out, never in the way. With Reduce Motion on, anything
/// that moves becomes a short fade.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Fast out, gentle settle.
    static let curve = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    static let duration: TimeInterval = 0.22
    /// Leaving is a little quicker than arriving.
    static let exit: TimeInterval = 0.16

    /// The same curve for SwiftUI, or a plain fade-length ease when motion is reduced.
    static func animation(_ duration: TimeInterval = duration) -> Animation {
        reduced ? .easeOut(duration: 0.15) : .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }

    /// Runs `changes` (made through views' `animator()` proxies) on tern's curve.
    static func animate(_ duration: TimeInterval = duration, _ changes: () -> Void,
                        completion: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = curve
            changes()
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }

    /// Fades a layer in, rising `rise` points as it does unless motion is reduced. The layer's
    /// own values don't change; this only plays over them.
    static func reveal(_ layer: CALayer?, rise: CGFloat = 0, duration: TimeInterval = 0.2) {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        var parts: [CAAnimation] = [fade]
        if rise != 0, !reduced {
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = -rise
            move.toValue = 0
            parts.append(move)
        }
        let group = CAAnimationGroup()
        group.animations = parts
        group.duration = duration
        group.timingFunction = curve
        layer.add(group, forKey: "tern.reveal")
    }
}

extension Motion {
    /// tern's curve, cubic-bezier(0.22, 1, 0.36, 1), at `x` in 0…1.
    nonisolated static func ease(_ x: Double) -> Double {
        let (x1, y1, x2, y2) = (0.22, 1.0, 0.36, 1.0)
        func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
        }
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        // Find the t whose x is `x` by bisection; the curve's x is monotonic.
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<24 {
            if bezier(t, x1, x2) < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return bezier(t, y1, y2)
    }
}

/// Moves views' frames along tern's curve, a step per display refresh. Unlike `animator()`, which
/// left views that were already on screen at their final frame, it sets the real frame each step.
final class FrameAnimator: NSObject {
    private struct Move {
        let view: NSView
        let from: CGRect
        let to: CGRect
        let start: CFTimeInterval
        let duration: TimeInterval
    }

    private weak var host: NSView?
    private var moves: [ObjectIdentifier: Move] = [:]
    private var link: CADisplayLink?

    init(host: NSView) {
        self.host = host
    }

    func move(_ view: NSView, from: CGRect, to: CGRect, duration: TimeInterval = Motion.duration) {
        view.frame = from
        moves[ObjectIdentifier(view)] = Move(view: view, from: from, to: to, start: CACurrentMediaTime(), duration: duration)
        guard link == nil, let host else { return }
        link = host.displayLink(target: self, selector: #selector(step))
        link?.add(to: .main, forMode: .common)
    }

    /// Stops moving `view`, leaving it where it is.
    func cancel(_ view: NSView) {
        moves[ObjectIdentifier(view)] = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        for (key, m) in moves {
            let t = min(1, (now - m.start) / m.duration)
            let e = CGFloat(Motion.ease(t))
            func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + (b - a) * e).rounded() }
            m.view.frame = t >= 1 ? m.to : CGRect(x: mix(m.from.minX, m.to.minX), y: mix(m.from.minY, m.to.minY),
                                                   width: mix(m.from.width, m.to.width), height: mix(m.from.height, m.to.height))
            if t >= 1 { moves[key] = nil }
        }
        if moves.isEmpty {
            link.invalidate()
            self.link = nil
        }
    }
}
