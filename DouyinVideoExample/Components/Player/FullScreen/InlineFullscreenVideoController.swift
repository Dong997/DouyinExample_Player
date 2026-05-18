import UIKit

/// Home 内部的假横屏全屏控制器。
/// 不 present、不触发系统方向变化，只在当前 window 上方创建浮层并旋转播放器容器。
final class InlineFullscreenVideoController: NSObject {

    private weak var player: DYVideoPlayerSession?
    private weak var originView: UIView?
    private weak var window: UIWindow?

    private var overlayView: UIView?
    private var dimmingView: UIView?
    private var contentContainerView: UIView?
    private var playerContainerView: UIView?
    private var controlsView: InlineFullscreenControlsView?

    private var restoreVideoGravity: DYVideoGravity = .aspectFit
    private var isAnimating = false
    private var isPresented = false
    private var isDraggingProgress = false
    private var isFastPlayingByLongPress = false
    private var currentSpeed: Float = 1.0
    private var controlsAutoHideTimer: Timer?
    private var originFrameInWindow: CGRect = .zero
    private var targetBounds: CGRect = .zero
    private var targetCenter: CGPoint = .zero
    private var targetTransform: CGAffineTransform = .identity
    private var targetRotationAngle: CGFloat = 0
    private var statusBarWasHiddenBeforeEnter = false
    private var restoreStatusBarWorkItem: DispatchWorkItem?

    var onDismiss: (() -> Void)?

    func enter(
        from originView: UIView,
        player: DYVideoPlayerSession,
        orientationMask: UIInterfaceOrientationMask
    ) {
        guard !isAnimating, !isPresented, let window = originView.window else { return }

        self.player = player
        self.originView = originView
        self.window = window
        restoreVideoGravity = player.videoGravity
        currentSpeed = player.playbackRate
        originFrameInWindow = originView.convert(originView.bounds, to: window)
        configureTargetGeometry(in: window.bounds, orientationMask: orientationMask)
        hideStatusBarForFullscreen()

        let overlayView = UIView(frame: window.bounds)
        overlayView.backgroundColor = .clear
        overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let dimmingView = UIView(frame: overlayView.bounds)
        dimmingView.backgroundColor = .black
        dimmingView.alpha = 0
        dimmingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let contentContainerView = UIView(frame: .zero)
        contentContainerView.backgroundColor = .clear
        contentContainerView.clipsToBounds = true
        contentContainerView.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        contentContainerView.bounds = targetBounds
        contentContainerView.center = CGPoint(x: originFrameInWindow.midX, y: originFrameInWindow.midY)
        contentContainerView.transform = collapsedTransform(for: originFrameInWindow)

        let playerContainerView = UIView(frame: contentContainerView.bounds)
        playerContainerView.backgroundColor = .clear
        playerContainerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let controlsView = InlineFullscreenControlsView(frame: contentContainerView.bounds)
        controlsView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controlsView.configure(currentSpeed: currentSpeed)

        contentContainerView.addSubview(playerContainerView)
        contentContainerView.addSubview(controlsView)
        overlayView.addSubview(dimmingView)
        overlayView.addSubview(contentContainerView)
        window.addSubview(overlayView)

        self.overlayView = overlayView
        self.dimmingView = dimmingView
        self.contentContainerView = contentContainerView
        self.playerContainerView = playerContainerView
        self.controlsView = controlsView

        configureControlCallbacks(controlsView)
        installPlaybackGestures(on: contentContainerView)

        player.setVideoGravity(.aspectFit)
        player.updateContainer(playerContainerView)
        player.multicastDelegate.add(self)
        updateProgress(currentTime: player.currentTime, totalTime: player.duration)

        animateEnter()
    }

    func exit(to restoreView: UIView?) {
        guard !isAnimating, isPresented, let contentContainerView else { return }

        let fallbackFrame = originFrameInWindow
        let restoreFrame = restoreView?.window.flatMap { window in
            restoreView?.convert(restoreView?.bounds ?? .zero, to: window)
        } ?? fallbackFrame

        isAnimating = true
        hideOverlayControls(animated: false)
        dimmingView?.alpha = 0

        contentContainerView.bounds = CGRect(origin: .zero, size: restoreFrame.size)
        contentContainerView.center = targetCenter
        contentContainerView.transform = CGAffineTransform(rotationAngle: targetRotationAngle)
        playerContainerView?.frame = contentContainerView.bounds
        controlsView?.frame = contentContainerView.bounds

        UIView.animate(
            withDuration: 0.46,
            delay: 0,
            usingSpringWithDamping: 0.95,
            initialSpringVelocity: 0.15,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            contentContainerView.center = CGPoint(x: restoreFrame.midX, y: restoreFrame.midY)
            contentContainerView.transform = .identity
        } completion: { _ in
            self.finishExit(to: restoreView)
        }
    }

    private func animateEnter() {
        guard let contentContainerView else { return }
        isAnimating = true

        UIView.animate(
            withDuration: 0.52,
            delay: 0,
            usingSpringWithDamping: 0.93,
            initialSpringVelocity: 0.2,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            self.dimmingView?.alpha = 1
            contentContainerView.center = self.targetCenter
            contentContainerView.transform = self.targetTransform
        } completion: { _ in
            self.isAnimating = false
            self.isPresented = true
            self.showOverlayControls()
            self.scheduleControlsAutoHide()
        }
    }

    private func finishExit(to restoreView: UIView?) {
        if let restoreView, let player {
            player.updateContainer(restoreView)
            player.setVideoGravity(restoreVideoGravity)
            if player.state != .playing {
                player.resume()
            }
        }
        player?.multicastDelegate.remove(self)
        controlsAutoHideTimer?.invalidate()

        overlayView?.removeFromSuperview()
        overlayView = nil
        dimmingView = nil
        contentContainerView = nil
        playerContainerView = nil
        controlsView = nil
        isDraggingProgress = false
        isFastPlayingByLongPress = false
        controlsAutoHideTimer = nil
        isAnimating = false
        isPresented = false

        onDismiss?()
        restoreStatusBarAfterExit()
    }

    private func configureTargetGeometry(
        in bounds: CGRect,
        orientationMask: UIInterfaceOrientationMask
    ) {
        targetCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        if orientationMask.dyInlineIsLandscape {
            targetBounds = CGRect(origin: .zero, size: CGSize(width: bounds.height, height: bounds.width))
            targetRotationAngle = orientationMask == .landscapeLeft ? -.pi / 2 : .pi / 2
            targetTransform = CGAffineTransform(rotationAngle: targetRotationAngle)
        } else {
            targetBounds = CGRect(origin: .zero, size: bounds.size)
            targetRotationAngle = 0
            targetTransform = .identity
        }
    }

    private func collapsedTransform(for frame: CGRect) -> CGAffineTransform {
        guard targetBounds.width > 0, targetBounds.height > 0 else { return .identity }
        return CGAffineTransform(
            scaleX: frame.width / targetBounds.width,
            y: frame.height / targetBounds.height
        )
    }

    private func hideStatusBarForFullscreen() {
        restoreStatusBarWorkItem?.cancel()
        restoreStatusBarWorkItem = nil
        statusBarWasHiddenBeforeEnter = UIApplication.shared.isStatusBarHidden
        UIApplication.shared.setStatusBarHidden(true, with: .none)
    }

    private func restoreStatusBarAfterExit() {
        restoreStatusBarWorkItem?.cancel()
        let shouldHideStatusBar = statusBarWasHiddenBeforeEnter
        let workItem = DispatchWorkItem {
            UIApplication.shared.setStatusBarHidden(shouldHideStatusBar, with: .none)
        }
        restoreStatusBarWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func configureControlCallbacks(_ controlsView: InlineFullscreenControlsView) {
        controlsView.onClose = { [weak self] in
            self?.exit(to: self?.originView)
        }
        controlsView.onPlayPause = { [weak self] in
            self?.togglePlayPause()
        }
        controlsView.onSpeedSelected = { [weak self] speed in
            guard let self else { return }
            self.currentSpeed = speed
            self.player?.setPlaybackRate(speed)
            self.scheduleControlsAutoHide()
        }
        controlsView.onProgressDragStart = { [weak self] in
            guard let self else { return }
            self.isDraggingProgress = true
            self.showOverlayControls()
            self.cancelControlsAutoHide()
            self.player?.pause()
        }
        controlsView.onProgressChanged = { [weak self] progress in
            guard let self, let player = self.player else { return }
            let targetTime = Double(progress) * player.duration
            self.controlsView?.updateTimeLabel(currentTime: targetTime, totalTime: player.duration)
            player.seek(to: targetTime, isPrecise: false, completion: nil)
        }
        controlsView.onProgressEnded = { [weak self] progress in
            guard let self, let player = self.player else { return }
            self.isDraggingProgress = false
            let targetTime = Double(progress) * player.duration
            player.seek(to: targetTime, isPrecise: true) { _ in
                player.resume()
            }
            self.scheduleControlsAutoHide()
        }
    }

    private func showOverlayControls() {
        controlsView?.updatePlaybackState(player?.state)
        controlsView?.show(animated: true)
    }

    private func hideOverlayControls(animated: Bool) {
        controlsView?.hide(animated: animated)
    }

    private func cancelControlsAutoHide() {
        controlsAutoHideTimer?.invalidate()
        controlsAutoHideTimer = nil
    }

    private func scheduleControlsAutoHide() {
        cancelControlsAutoHide()
        let timer = Timer(timeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.hideOverlayControls(animated: true)
        }
        controlsAutoHideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateProgress(currentTime: Double, totalTime: Double) {
        guard !isDraggingProgress else { return }
        controlsView?.updateProgress(currentTime: currentTime, totalTime: totalTime)
    }

    private func installPlaybackGestures(on view: UIView) {
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.delegate = self

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        singleTap.require(toFail: doubleTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.delegate = self

        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(longPress)
    }

    private func togglePlayPause() {
        guard let player else { return }
        if player.state == .playing {
            player.pause()
        } else {
            player.resume()
        }
        showOverlayControls()
        controlsView?.updatePlaybackState(player.state)
        scheduleControlsAutoHide()
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        guard let controlsView else { return }
        if controlsView.isVisible {
            hideOverlayControls(animated: true)
            cancelControlsAutoHide()
        } else {
            showOverlayControls()
            scheduleControlsAutoHide()
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        togglePlayPause()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let player else { return }
        switch gesture.state {
        case .began, .changed:
            cancelControlsAutoHide()
            if !isFastPlayingByLongPress {
                if player.state != .playing {
                    player.resume()
                }
                player.setPlaybackRate(2.0)
                isFastPlayingByLongPress = true
            }
            controlsView?.showSpeedTip()
        case .ended, .cancelled, .failed:
            player.setPlaybackRate(currentSpeed)
            isFastPlayingByLongPress = false
            controlsView?.hideSpeedTip()
            scheduleControlsAutoHide()
        default:
            break
        }
    }
}

extension InlineFullscreenVideoController: DYVideoPlayerDelegate {
    func player(_ player: DYVideoPlayerSession, didChangeState state: DYPlayerState) {
        controlsView?.updatePlaybackState(state)
        if state == .playing {
            controlsView?.finishLoading()
        } else if state == .buffering || state == .preparing {
            controlsView?.startLoading()
        }
    }

    func player(_ player: DYVideoPlayerSession, didUpdateProgress progress: Double, currentTime: Double, totalTime: Double) {
        updateProgress(currentTime: currentTime, totalTime: totalTime)
    }

    func player(_ player: DYVideoPlayerSession, didUpdateBuffer progress: Double) {
        controlsView?.updateBuffer(to: CGFloat(progress))
    }
}

extension InlineFullscreenVideoController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let touchedView = touch.view else { return true }
        return !(controlsView?.containsControl(touchedView) ?? false)
    }
}

private extension UIInterfaceOrientationMask {
    var dyInlineIsLandscape: Bool {
        switch self {
        case .landscape, .landscapeLeft, .landscapeRight:
            return true
        default:
            return false
        }
    }
}
