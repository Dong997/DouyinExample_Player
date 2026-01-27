//
//  VideoProgressBar.swift
//  Swift_SJG_APP
//
//  Created by 华博-技术支撑 on 2025/8/12.
//

import UIKit

/// 拖拽开始回调，适用于通知外部开始 Seek 或更新 UI
typealias VideoProgressBarDragStartHandler = () -> Void
/// 拖拽过程中进度变更回调，参数为 0~1 的归一化进度
typealias VideoProgressBarProgressChangeHandler = (CGFloat) -> Void
/// 拖拽结束回调，参数为最终归一化进度
typealias VideoProgressBarDragEndHandler = (CGFloat) -> Void

/// 进度条交互模式
/// - interactive: 支持用户拖拽和点击
/// - displayOnly: 仅展示进度，不响应触摸事件
enum VideoProgressBarInteractionMode {
    case interactive
    case displayOnly
}

/// 通用视频进度条组件
/// 支持：缓冲进度展示、拖拽 Seek、加载动画、父滚动视图联动
class VideoProgressBar: UIView {

    // MARK: - 自定义颜色
    /// 轨道底色
    var trackColor: UIColor = UIColor.gray.withAlphaComponent(0.4) {
        didSet { trackLayer.backgroundColor = trackColor.cgColor }
    }
    /// 缓冲进度条颜色
    var bufferColor: UIColor = UIColor.gray.withAlphaComponent(0.7) {
        didSet { bufferLayer.backgroundColor = bufferColor.cgColor }
    }
    /// 已播放进度条与拖拽圆点颜色
    var progressColor: UIColor = .white {
        didSet {
            progressLayer.backgroundColor = progressColor.cgColor
            loadingLayer.backgroundColor = progressColor.cgColor
            thumbLayer.backgroundColor = progressColor.cgColor
        }
    }
    
    /// 是否在拖拽时放大进度条高度
    var enableScaleAnimation: Bool = true
    /// 是否在 0~5% 范围内关闭进度动画，避免首屏抖动
    var disableAnimationForZeroToFivePercent: Bool = false
    /// 当前组件的交互模式
    var interactionMode: VideoProgressBarInteractionMode = .interactive
    /// 外部注入父滚动视图解析逻辑，用于控制滚动冲突处理
    var scrollViewResolver: ((VideoProgressBar) -> UIScrollView?)?
    /// 是否启用播放进度动画
    var isProgressAnimationEnabled: Bool = true
    /// 是否启用缓冲进度动画
    var isBufferAnimationEnabled: Bool = true
    /// 触发进度动画的最小进度差阈值
    var progressAnimationMinDelta: CGFloat = 0.01
    /// 触发缓冲动画的最小进度差阈值
    var bufferAnimationMinDelta: CGFloat = 0.02
    
    // MARK: - Private
    /// 底部轨道图层
    private let trackLayer = CALayer()
    /// 缓冲进度图层
    private let bufferLayer = CALayer()
    /// 播放进度图层
    private let progressLayer = CALayer()
    /// 加载动画图层
    private let loadingLayer = CALayer()
    /// 拖拽圆点图层
    private let thumbLayer = CALayer()

    /// 当前播放进度（0~1）
    private var currentProgress: CGFloat = 0
    /// 当前缓冲进度（0~1）
    private var currentBuffer: CGFloat = 0
    
    /// 加载动画使用的 Key
    private let loadingAnimationKey = "loadingAnimation"

    // MARK: - Initialization
    /// 代码初始化入口
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayers()
    }

    /// 不支持从 XIB/Storyboard 初始化
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    /// 构建内部图层结构与默认外观
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
    
    /// 拖拽开始回调
    var didBeginDragging: VideoProgressBarDragStartHandler?
    /// 拖拽中进度变更回调
    var didChangeProgress: VideoProgressBarProgressChangeHandler?
    /// 拖拽结束回调
    var didEndDragging: VideoProgressBarDragEndHandler?
    
    /// 是否处于用户拖拽交互中
    private var isInteracting: Bool = false
    /// 标记当前进度更新是否来源于触摸，避免循环回调
    private var isUpdatingFromTouch: Bool = false
    /// 拖拽结束后的缓冲稳定期标记，用于忽略瞬时大跳动
    private var isSettlingAfterDrag: Bool = false
    /// 稳定期定时器
    private var settleTimer: Timer?
    
    /// 扩大点击区域并在展示模式下关闭交互
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if interactionMode == .displayOnly {
            return false
        }
        let touchArea = bounds.insetBy(dx: 0, dy: -30)
        return touchArea.contains(point)
    }
    
    /// 触摸开始：进入拖拽态，放大进度条并禁用父滚动
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        if interactionMode == .displayOnly {
            return
        }
        isInteracting = true
        resolvedScrollView?.isScrollEnabled = false
        
        // 放大动画
        if enableScaleAnimation {
            UIView.animate(withDuration: 0.2) {
                self.transform = CGAffineTransform(scaleX: 1.0, y: 2.5) // 高度放大2.5倍
            }
        }
        
        didBeginDragging?()
        handleTouch(touches)
    }
    
    /// 触摸移动：持续更新归一化进度
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        if interactionMode == .displayOnly {
            return
        }
        handleTouch(touches)
    }
    
    /// 触摸结束：恢复滚动和尺寸，触发最终 Seek 回调
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        if interactionMode == .displayOnly {
            return
        }
        isInteracting = false
        resolvedScrollView?.isScrollEnabled = true
        
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
    
    /// 触摸取消：与结束逻辑一致，保证状态恢复
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        if interactionMode == .displayOnly {
            return
        }
        isInteracting = false
        resolvedScrollView?.isScrollEnabled = true
        
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
    
    /// 将触摸位置映射为 0~1 的归一化进度并透传给回调
    private func handleTouch(_ touches: Set<UITouch>) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        let progress = max(0, min(1, point.x / bounds.width))
        isUpdatingFromTouch = true
        updateProgress(to: progress, animated: false)
        isUpdatingFromTouch = false
        didChangeProgress?(progress)
    }
    
    /// 解析需要被禁用滚动的父滚动视图
    private var resolvedScrollView: UIScrollView? {
        if let resolver = scrollViewResolver {
            return resolver(self)
        }
        return parentScrollView
    }
    
    /// 从 superview 链中查找最近的 UIScrollView
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
    /// 布局子图层并在尺寸变化时更新进度和加载动画
    override func layoutSubviews() {
        super.layoutSubviews()
        trackLayer.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.cornerRadius = bounds.height / 2
        CATransaction.commit()
        updateBufferFrame()
        updateProgressFrame(animated: false)
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
    
    /// 更新播放进度 (0.0 ~ 1.0)
    /// - Parameters:
    ///   - progress: 归一化播放进度
    ///   - animated: 是否启用动画（仍受内部开关与阈值控制）
    public func updateProgress(to progress: CGFloat, animated: Bool = true) {
        let bounded = max(0, min(1, progress))
        if isInteracting && !isUpdatingFromTouch { return }
        let delta = abs(bounded - currentProgress)
        var disableAnimationOnce = false
        if isSettlingAfterDrag && !isUpdatingFromTouch {
            if delta > 0.02 { return }
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
        let effectiveAnimated = animated
            && isProgressAnimationEnabled
            && !disableAnimationOnce
            && !disableLowRangeAnimation
            && delta >= progressAnimationMinDelta
        updateProgressFrame(animated: effectiveAnimated)
    }

    /// 更新缓冲进度 (0.0 ~ 1.0)
    public func updateBuffer(to buffer: CGFloat) {
        let bounded = max(0, min(1, buffer))
        let delta = abs(bounded - currentBuffer)
        currentBuffer = bounded
        let shouldAnimate = isBufferAnimationEnabled && delta >= bufferAnimationMinDelta
        if shouldAnimate {
            CATransaction.begin()
            CATransaction.setDisableActions(false)
            CATransaction.setAnimationDuration(0.25)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
            updateBufferFrame()
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updateBufferFrame()
            CATransaction.commit()
        }
    }
    
    // MARK: - private Methods

    /// 启动加载动画图层的缩放往复动画
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
    
    /// 根据 currentProgress 更新播放进度图层和圆点位置
    private func updateProgressFrame(animated: Bool = false) {
        if animated {
            CATransaction.begin()
            CATransaction.setDisableActions(false)
            CATransaction.setAnimationDuration(0.25)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
            progressLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * currentProgress, height: bounds.height)
            updateThumbFrame(animated: true)
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            progressLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * currentProgress, height: bounds.height)
            updateThumbFrame(animated: false)
            CATransaction.commit()
        }
    }
    
    /// 根据 currentBuffer 更新缓冲进度图层
    private func updateBufferFrame() {
        bufferLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * currentBuffer, height: bounds.height)
    }
    
    /// 根据当前进度和高度计算拖拽圆点的几何位置与圆角
    private func updateThumbFrame(animated: Bool = false) {
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
        
        if animated {
            thumbLayer.frame = CGRect(x: originX, y: originY, width: diameter, height: diameter)
            thumbLayer.cornerRadius = diameter / 2
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            thumbLayer.frame = CGRect(x: originX, y: originY, width: diameter, height: diameter)
            thumbLayer.cornerRadius = diameter / 2
            CATransaction.commit()
        }
    }
}
