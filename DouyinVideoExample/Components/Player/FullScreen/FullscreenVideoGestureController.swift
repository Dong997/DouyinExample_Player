import UIKit

enum FullscreenVideoGestureKind {
    case brightness
    case volume
    case seek
}

struct FullscreenVideoGestureContext {
    let volume: Float
    let currentTime: Double
    let duration: Double
}

/// 管理全屏画面滑动手势：左侧亮度、右侧音量、横向快进快退。
final class FullscreenVideoGestureController: NSObject {
    var contextProvider: (() -> FullscreenVideoGestureContext)?
    var excludedViewsProvider: (() -> [UIView])?
    var onInteractionBegan: ((FullscreenVideoGestureKind) -> Void)?
    var onVolumeChanged: ((Float) -> Void)?
    var onSeekPreview: ((_ targetTime: Double, _ totalTime: Double, _ progress: CGFloat) -> Void)?
    var onSeekFinished: ((Double) -> Void)?
    var onInteractionEnded: (() -> Void)?

    private weak var hostView: UIView?
    private let hudView: FullscreenGestureHUDView
    private var panGesture: UIPanGestureRecognizer?
    private var activeKind: FullscreenVideoGestureKind?
    private var startBrightness: CGFloat = UIScreen.main.brightness
    private var startVolume: Float = 1.0
    private var startTime: Double = 0
    private var targetTime: Double = 0

    var isInteracting: Bool {
        activeKind != nil
    }

    init(hudView: FullscreenGestureHUDView) {
        self.hudView = hudView
        super.init()
    }

    func install(on view: UIView) {
        hostView = view
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.maximumNumberOfTouches = 1
        panGesture.delegate = self
        view.addGestureRecognizer(panGesture)
        self.panGesture = panGesture
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let hostView else { return }
        let location = gesture.location(in: hostView)
        let translation = gesture.translation(in: hostView)
        let velocity = gesture.velocity(in: hostView)

        switch gesture.state {
        case .began:
            guard
                let context = contextProvider?(),
                let kind = resolveKind(location: location, velocity: velocity, duration: context.duration)
            else {
                return
            }
            activeKind = kind
            startBrightness = UIScreen.main.brightness
            startVolume = context.volume
            startTime = context.currentTime
            targetTime = context.currentTime
            onInteractionBegan?(kind)
            showInitialHUD(for: kind, context: context)
        case .changed:
            guard let activeKind else { return }
            update(kind: activeKind, translation: translation)
        case .ended, .cancelled, .failed:
            finishInteraction()
        default:
            break
        }
    }

    private func resolveKind(location: CGPoint, velocity: CGPoint, duration: Double) -> FullscreenVideoGestureKind? {
        let horizontalSpeed = abs(velocity.x)
        let verticalSpeed = abs(velocity.y)
        guard max(horizontalSpeed, verticalSpeed) > 40 else {
            return nil
        }
        if horizontalSpeed > verticalSpeed {
            return duration > 0 ? .seek : nil
        }
        guard let hostView else { return nil }
        return location.x < hostView.bounds.midX ? .brightness : .volume
    }

    private func update(kind: FullscreenVideoGestureKind, translation: CGPoint) {
        guard let hostView, let context = contextProvider?() else { return }
        switch kind {
        case .brightness:
            let delta = -translation.y / max(hostView.bounds.height, 1)
            let brightness = Self.clamp(startBrightness + delta, min: 0, max: 1)
            UIScreen.main.brightness = brightness
            hudView.show(
                iconName: "sun.max.fill",
                text: "亮度 \(Int(round(brightness * 100)))%",
                progress: Float(brightness)
            )
        case .volume:
            let delta = Float(-translation.y / max(hostView.bounds.height, 1))
            let volume = Self.clamp(startVolume + delta, min: 0, max: 1)
            onVolumeChanged?(volume)
            hudView.show(
                iconName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                text: "音量 \(Int(round(volume * 100)))%",
                progress: volume
            )
        case .seek:
            let totalTime = max(context.duration, 0)
            guard totalTime > 0 else { return }
            let maxDelta = min(totalTime * 0.5, 90)
            let delta = Double(translation.x / max(hostView.bounds.width, 1)) * maxDelta
            targetTime = Self.clamp(startTime + delta, min: 0, max: totalTime)
            let progress = CGFloat(targetTime / totalTime)
            onSeekPreview?(targetTime, totalTime, progress)
            hudView.show(
                iconName: delta >= 0 ? "goforward" : "gobackward",
                text: "\(DYPlayerUtils.formatTime(seconds: targetTime))/\(DYPlayerUtils.formatTime(seconds: totalTime))",
                progress: Float(progress)
            )
        }
    }

    private func finishInteraction() {
        if activeKind == .seek {
            onSeekFinished?(targetTime)
        }
        activeKind = nil
        hudView.hide()
        onInteractionEnded?()
    }

    private func showInitialHUD(for kind: FullscreenVideoGestureKind, context: FullscreenVideoGestureContext) {
        switch kind {
        case .brightness:
            hudView.show(
                iconName: "sun.max.fill",
                text: "亮度 \(Int(round(UIScreen.main.brightness * 100)))%",
                progress: Float(UIScreen.main.brightness)
            )
        case .volume:
            hudView.show(
                iconName: context.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                text: "音量 \(Int(round(context.volume * 100)))%",
                progress: context.volume
            )
        case .seek:
            let totalTime = max(context.duration, 0)
            let progress = totalTime > 0 ? Float(context.currentTime / totalTime) : 0
            hudView.show(
                iconName: "goforward",
                text: "\(DYPlayerUtils.formatTime(seconds: context.currentTime))/\(DYPlayerUtils.formatTime(seconds: totalTime))",
                progress: progress
            )
        }
    }

    private static func clamp<T: Comparable>(_ value: T, min lowerBound: T, max upperBound: T) -> T {
        return min(max(value, lowerBound), upperBound)
    }
}

extension FullscreenVideoGestureController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard
            gestureRecognizer === panGesture,
            let panGesture,
            let hostView
        else {
            return true
        }
        let velocity = panGesture.velocity(in: hostView)
        guard max(abs(velocity.x), abs(velocity.y)) > 40 else {
            return false
        }
        let location = panGesture.location(in: hostView)
        if location.y > hostView.bounds.height - 72 {
            return false
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === panGesture else {
            return true
        }
        return !(excludedViewsProvider?().contains { excludedView in
            touch.view === excludedView || (touch.view?.isDescendant(of: excludedView) ?? false)
        } ?? false)
    }
}
