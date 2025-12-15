import UIKit

/// 全屏视频转场代理，负责提供自定义 Present 和 Dismiss 动画控制器
final class FullscreenVideoTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {
    /// 原始视频容器视图，用于计算转场起始与结束位置
    private weak var originView: UIView?
    /// 进入全屏时支持的屏幕方向掩码，用于确定旋转方向
    private let fullscreenOrientationMask: UIInterfaceOrientationMask

    /// 使用原始容器视图及全屏方向配置初始化转场代理
    /// - Parameters:
    ///   - originView: 原始小窗视频所在视图，用于生成转场快照
    ///   - fullscreenOrientationMask: 目标全屏方向配置
    init(originView: UIView, fullscreenOrientationMask: UIInterfaceOrientationMask) {
        self.originView = originView
        self.fullscreenOrientationMask = fullscreenOrientationMask
        super.init()
    }
    
    /// 提供自定义 Present 动画控制器
    /// - Parameters:
    ///   - presented: 将要呈现的控制器
    ///   - presenting: 触发展示的控制器
    ///   - source: 源控制器
    /// - Returns: 实现全屏进入动画的动画控制器
    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return FullscreenVideoPresentAnimator(
            originView: originView,
            fullscreenOrientationMask: fullscreenOrientationMask
        )
    }
    
    /// 提供自定义 Dismiss 动画控制器
    /// - Parameter dismissed: 即将被关闭的全屏控制器
    /// - Returns: 实现全屏退出动画的动画控制器
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return FullscreenVideoDismissAnimator(
            originView: originView,
            fullscreenOrientationMask: fullscreenOrientationMask
        )
    }
}

/// 全屏视频进入动画控制器（小窗 → 全屏）
final class FullscreenVideoPresentAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    /// 原始视频容器视图，用于确定小窗位置及生成快照
    private weak var originView: UIView?
    /// 全屏方向掩码，用于确定是否需要横屏旋转
    private let fullscreenOrientationMask: UIInterfaceOrientationMask
    /// 转场动画时长
    private let animationDuration: TimeInterval = 0.35
    
    /// 初始化进入动画控制器
    /// - Parameters:
    ///   - originView: 原始小窗视频视图
    ///   - fullscreenOrientationMask: 目标全屏方向配置
    init(originView: UIView?, fullscreenOrientationMask: UIInterfaceOrientationMask) {
        self.originView = originView
        self.fullscreenOrientationMask = fullscreenOrientationMask
        super.init()
    }
    
    /// 返回转场动画时长
    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return animationDuration
    }
    
    /// 执行动画：从小窗位置放大并可选旋转到全屏
    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        guard
            let containerView = transitionContext.containerView as UIView?,
            let toView = transitionContext.view(forKey: .to)
        else {
            transitionContext.completeTransition(false)
            return
        }
        
        let originView = self.originView
        let snapshot: UIView
        let startFrame: CGRect
        
        if let originView = originView,
           let generatedSnapshot = originView.snapshotView(afterScreenUpdates: false) {
            snapshot = generatedSnapshot
            startFrame = originView.convert(originView.bounds, to: containerView)
        } else {
            snapshot = toView.snapshotView(afterScreenUpdates: true) ?? toView
            startFrame = containerView.bounds
        }
        
        snapshot.frame = startFrame
        /// 全屏目标视图填满容器，先设置为透明，待动画结束显示
        toView.frame = containerView.bounds
        toView.alpha = 0
        
        containerView.addSubview(toView)
        containerView.addSubview(snapshot)
        
        let isLandscapeFullscreen: Bool
        switch fullscreenOrientationMask {
        case .landscape, .landscapeLeft, .landscapeRight:
            isLandscapeFullscreen = true
        default:
            isLandscapeFullscreen = false
        }
        
        let finalCenter = CGPoint(x: containerView.bounds.midX, y: containerView.bounds.midY)
        let finalBounds = containerView.bounds
        
        UIView.animate(
            withDuration: animationDuration,
            delay: 0,
            options: [.curveEaseInOut]
        ) {
            if isLandscapeFullscreen {
                snapshot.center = finalCenter
                snapshot.bounds = finalBounds
                let angle: CGFloat
                switch self.fullscreenOrientationMask {
                case .landscapeLeft:
                    angle = -.pi / 2
                default:
                    angle = .pi / 2
                }
                snapshot.transform = CGAffineTransform(rotationAngle: angle)
            } else {
                snapshot.frame = finalBounds
            }
            toView.alpha = 1
        } completion: { finished in
            snapshot.removeFromSuperview()
            transitionContext.completeTransition(finished)
        }
    }
}

/// 全屏视频退出动画控制器（全屏 → 小窗或淡出）
final class FullscreenVideoDismissAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    /// 原始视频容器视图，用于计算回到小窗时的目标位置
    private weak var originView: UIView?
    /// 全屏方向掩码，用于确定横竖屏退出策略
    private let fullscreenOrientationMask: UIInterfaceOrientationMask
    /// 转场动画时长
    private let animationDuration: TimeInterval = 0.15
    
    /// 初始化退出动画控制器
    /// - Parameters:
    ///   - originView: 原始小窗视频视图
    ///   - fullscreenOrientationMask: 当前全屏方向配置
    init(originView: UIView?, fullscreenOrientationMask: UIInterfaceOrientationMask) {
        self.originView = originView
        self.fullscreenOrientationMask = fullscreenOrientationMask
        super.init()
    }
    
    /// 返回转场动画时长
    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return animationDuration
    }
    
    /// 执行退出动画：
    /// - 横屏全屏时，进行旋转 + 淡出
    /// - 竖屏全屏时，缩放回原始小窗位置或直接淡出
    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        guard
            let containerView = transitionContext.containerView as UIView?,
            let fromView = transitionContext.view(forKey: .from),
            let toView = transitionContext.view(forKey: .to)
        else {
            transitionContext.completeTransition(false)
            return
        }
        
        let isLandscapeFullscreen: Bool
        switch fullscreenOrientationMask {
        case .landscape, .landscapeLeft, .landscapeRight:
            isLandscapeFullscreen = true
        default:
            isLandscapeFullscreen = false
        }
        
        guard let snapshot = fromView.snapshotView(afterScreenUpdates: false) else {
            UIView.animate(
                withDuration: animationDuration,
                delay: 0,
                options: [.curveEaseInOut]
            ) {
                fromView.alpha = 0
            } completion: { finished in
                fromView.alpha = 1
                transitionContext.completeTransition(finished)
            }
            return
        }
        
        snapshot.frame = fromView.frame
        snapshot.backgroundColor = .clear
        toView.frame = containerView.bounds
        
        containerView.insertSubview(toView, belowSubview: fromView)
        containerView.addSubview(snapshot)
        fromView.isHidden = true
        
        if isLandscapeFullscreen {
            UIView.animate(
                withDuration: animationDuration,
                delay: 0,
                options: [.curveEaseInOut]
            ) {
                let angle: CGFloat
                switch self.fullscreenOrientationMask {
                case .landscapeLeft:
                    angle = .pi / 2
                default:
                    angle = -.pi / 2
                }
                let rotation = CGAffineTransform(rotationAngle: angle)
                snapshot.transform = rotation
                snapshot.alpha = 0
            } completion: { finished in
                fromView.isHidden = false
                snapshot.removeFromSuperview()
                transitionContext.completeTransition(finished && !transitionContext.transitionWasCancelled)
            }
        }
    }
}
