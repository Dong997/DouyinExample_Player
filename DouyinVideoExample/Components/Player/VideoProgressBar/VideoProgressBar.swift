//
//  VideoProgressBar.swift
//  Swift_SJG_APP
//
//  Created by 华博-技术支撑 on 2025/8/12.
//

import UIKit

class VideoProgressBar: UIView {

    // MARK: - 自定义颜色
    var trackColor: UIColor = UIColor.gray.withAlphaComponent(0.4) {
        didSet { trackLayer.backgroundColor = trackColor.cgColor }
    }
    var bufferColor: UIColor = UIColor.gray.withAlphaComponent(0.7) {
        didSet { bufferLayer.backgroundColor = bufferColor.cgColor }
    }
    var progressColor: UIColor = .white {
        didSet {
            progressLayer.backgroundColor = progressColor.cgColor
            loadingLayer.backgroundColor = progressColor.cgColor
            thumbLayer.backgroundColor = progressColor.cgColor
        }
    }
    
    /// 是否开启拖拽时放大效果
    var enableScaleAnimation: Bool = true
    var disableAnimationForZeroToFivePercent: Bool = false
    
    // MARK: - Private
    private let trackLayer = CALayer()
    private let bufferLayer = CALayer()
    private let progressLayer = CALayer()
    private let loadingLayer = CALayer() // 专门用于加载动画的图层
    private let thumbLayer = CALayer()

    private var currentProgress: CGFloat = 0
    private var currentBuffer: CGFloat = 0
    
    private let loadingAnimationKey = "loadingAnimation"

    // MARK: - Initialization
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    private func setupLayers() {
        layer.cornerRadius = 0
        layer.masksToBounds = false

        // 底部灰色轨道条
        trackLayer.backgroundColor = trackColor.cgColor
        layer.addSublayer(trackLayer)

        // 灰色缓冲进度条
        bufferLayer.backgroundColor = bufferColor.cgColor
        layer.addSublayer(bufferLayer)
        
        // 白色已播放进度条
        progressLayer.backgroundColor = progressColor.cgColor
        layer.addSublayer(progressLayer)
        
        // 中间的加载动画条
        loadingLayer.backgroundColor = progressColor.cgColor
        loadingLayer.isHidden = true
        layer.addSublayer(loadingLayer)
        
        // 进度条前端的小圆球
        thumbLayer.backgroundColor = progressColor.cgColor
        thumbLayer.isHidden = false
        layer.addSublayer(thumbLayer)
    }

    // MARK: - Touch Handling
    
    // 进度回调
    var didBeginDragging: (() -> Void)?
    var didChangeProgress: ((CGFloat) -> Void)?
    var didEndDragging: ((CGFloat) -> Void)?
    
    private var isInteracting: Bool = false
    private var isUpdatingFromTouch: Bool = false
    private var isSettlingAfterDrag: Bool = false
    private var settleTimer: Timer?
    
    // 扩大点击响应范围 (上下各扩大 20pt)
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let touchArea = bounds.insetBy(dx: 0, dy: -30)
        return touchArea.contains(point)
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        isInteracting = true
        // 禁止父视图滚动 (解决手势冲突)
        parentScrollView?.isScrollEnabled = false
        
        // 放大动画
        if enableScaleAnimation {
            UIView.animate(withDuration: 0.2) {
                self.transform = CGAffineTransform(scaleX: 1.0, y: 2.5) // 高度放大2.5倍
            }
        }
        
        didBeginDragging?()
        handleTouch(touches)
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        handleTouch(touches)
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        isInteracting = false
        // 恢复父视图滚动
        parentScrollView?.isScrollEnabled = true
        
        // 恢复大小
        if enableScaleAnimation {
            UIView.animate(withDuration: 0.2) {
                self.transform = .identity
            }
        }
        
        isSettlingAfterDrag = true
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.isSettlingAfterDrag = false
        }
        
        didEndDragging?(currentProgress)
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        isInteracting = false
        // 恢复父视图滚动
        parentScrollView?.isScrollEnabled = true
        
        // 恢复大小
        if enableScaleAnimation {
            UIView.animate(withDuration: 0.2) {
                self.transform = .identity
            }
        }
        isSettlingAfterDrag = true
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.isSettlingAfterDrag = false
        }
        
        didEndDragging?(currentProgress)
    }
    
    private func handleTouch(_ touches: Set<UITouch>) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        let progress = max(0, min(1, point.x / bounds.width))
        isUpdatingFromTouch = true
        updateProgress(to: progress, animated: false)
        isUpdatingFromTouch = false
        didChangeProgress?(progress)
    }
    
    // MARK: - Helper
    private var parentScrollView: UIScrollView? {
        var view = self.superview
        while view != nil {
            if let scrollView = view as? UIScrollView {
                return scrollView
            }
            view = view?.superview
        }
        return nil
    }
    
    // MARK: - Layout
    override func layoutSubviews() {
        super.layoutSubviews()
        trackLayer.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.cornerRadius = bounds.height / 2
        CATransaction.commit()
        updateBufferFrame()
        updateProgressFrame()
        loadingLayer.frame = CGRect(x: 0, y: 0, width: bounds.width / 1.5, height: bounds.height)
        loadingLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        
        if !loadingLayer.isHidden && loadingLayer.animation(forKey: loadingAnimationKey) == nil {
            startLoadingAnimation()
        }
        
        updateThumbFrame()
    }
    
    // MARK: - Public Methods
    
    /// 开始加载动画
    public func startLoading() {
        progressLayer.isHidden = true
        bufferLayer.isHidden = true
        loadingLayer.isHidden = false
        thumbLayer.isHidden = true
        startLoadingAnimation()
    }
    
    /// 结束加载动画
    public func finishLoading() {
        
        UIView.transition(with: self, duration: 0.3, options: .transitionCrossDissolve, animations: {
            self.loadingLayer.isHidden = true
            self.progressLayer.isHidden = false
            self.bufferLayer.isHidden = false
            self.thumbLayer.isHidden = false
        }) { (finished) in
            if finished {
                self.loadingLayer.removeAllAnimations()
            }
        }

    }
    
    /// 更新播放进度 (0.0 to 1.0)
    /// - Parameters:
    ///   - progress: 播放进度值
    ///   - animated: 是否需要动画效果
    public func updateProgress(to progress: CGFloat, animated: Bool = true) {
        let bounded = max(0, min(1, progress))
        if isInteracting && !isUpdatingFromTouch { return }
        var disableAnimationOnce = false
        if isSettlingAfterDrag && !isUpdatingFromTouch {
            let diff = abs(bounded - currentProgress)
            if diff > 0.02 { return }
            isSettlingAfterDrag = false
            settleTimer?.invalidate()
            disableAnimationOnce = true
        }
        var disableLowRangeAnimation = false
        if disableAnimationForZeroToFivePercent {
            let low: CGFloat = 0.05
            if currentProgress <= low && bounded <= low {
                disableLowRangeAnimation = true
            }
        }
        currentProgress = bounded
        let updateAction = {
            self.updateProgressFrame()
        }
        let effectiveAnimated = animated && !disableAnimationOnce && !disableLowRangeAnimation
        if effectiveAnimated {
            UIView.animate(withDuration: 0.25, animations: updateAction)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updateAction()
            CATransaction.commit()
        }
    }

    /// 更新缓冲进度 (0.0 to 1.0)
    public func updateBuffer(to buffer: CGFloat) {
        currentBuffer = max(0, min(1, buffer))
        
        UIView.animate(withDuration: 0.25) {
            self.updateBufferFrame()
        }
    }
    
    // MARK: - private Methods

    private func startLoadingAnimation() {
        loadingLayer.removeAllAnimations()

        let animation = CABasicAnimation(keyPath: "transform.scale.x")
        animation.fromValue = 0.0
        animation.toValue = 1.0
        animation.duration = 0.8
        animation.repeatCount = .infinity
        animation.autoreverses = true
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        loadingLayer.bounds.size.width = bounds.width / 1.5
        loadingLayer.add(animation, forKey: loadingAnimationKey)
    }
    
    private func updateProgressFrame() {
        progressLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * currentProgress, height: bounds.height)
        updateThumbFrame()
    }
    
    private func updateBufferFrame() {
        bufferLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * currentBuffer, height: bounds.height)
    }
    
    private func updateThumbFrame() {
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else {
            thumbLayer.isHidden = true
            return
        }
        
        let minimumDiameter: CGFloat = 6
        let diameter = max(minimumDiameter, height * 2)
        let centerX = width * currentProgress
        let clampedCenterX = max(diameter / 2, min(width - diameter / 2, centerX))
        let originX = clampedCenterX - diameter / 2
        let originY = (height - diameter) / 2
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbLayer.frame = CGRect(x: originX, y: originY, width: diameter, height: diameter)
        thumbLayer.cornerRadius = diameter / 2
        CATransaction.commit()
    }
}
