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
    private let animationDuration: TimeInterval = 0.28
    
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

        let dimmingView = UIView(frame: containerView.bounds)
        dimmingView.backgroundColor = .black
        dimmingView.alpha = 0

        let originView = self.originView
        let originSnapshot = originView?.snapshotView(afterScreenUpdates: false)
        if let originView, let originSnapshot {
            originSnapshot.frame = originView.convert(originView.bounds, to: containerView)
            originSnapshot.layer.masksToBounds = true
            originSnapshot.layer.cornerCurve = .continuous
        }

        /// 全屏目标视图填满容器，先设置为透明，待动画结束显示
        toView.frame = containerView.bounds
        toView.alpha = 0
        toView.transform = CGAffineTransform(scaleX: 0.985, y: 0.985)

        containerView.addSubview(dimmingView)
        containerView.addSubview(toView)
        if let originSnapshot {
            containerView.addSubview(originSnapshot)
        }

        let animator = UIViewPropertyAnimator(duration: animationDuration, curve: .easeOut) {
            dimmingView.alpha = 0.55
            toView.alpha = 1
            toView.transform = .identity
        }
        animator.addAnimations({
            originSnapshot?.alpha = 0
        }, delayFactor: 0.35)
        animator.addCompletion { position in
            let didComplete = position == .end && !transitionContext.transitionWasCancelled
            originSnapshot?.removeFromSuperview()
            dimmingView.removeFromSuperview()
            toView.alpha = 1
            toView.transform = .identity
            transitionContext.completeTransition(didComplete)
        }
        animator.startAnimation()
    }
}

/// 全屏视频退出动画控制器（全屏 → 小窗或淡出）
final class FullscreenVideoDismissAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    /// 原始视频容器视图，用于计算回到小窗时的目标位置
    private weak var originView: UIView?
    /// 全屏方向掩码，用于确定横竖屏退出策略
    private let fullscreenOrientationMask: UIInterfaceOrientationMask
    /// 转场动画时长
    private let animationDuration: TimeInterval = 0.24
    
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
        
        toView.frame = containerView.bounds
        toView.alpha = 1

        let dimmingView = UIView(frame: containerView.bounds)
        dimmingView.backgroundColor = .black
        dimmingView.alpha = 1

        containerView.insertSubview(toView, belowSubview: fromView)
        containerView.insertSubview(dimmingView, belowSubview: fromView)

        UIView.animate(
            withDuration: animationDuration,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            dimmingView.alpha = 0
            fromView.alpha = 0
            fromView.transform = CGAffineTransform(scaleX: 0.985, y: 0.985)
        } completion: { finished in
            dimmingView.removeFromSuperview()
            fromView.alpha = 1
            fromView.transform = .identity
            transitionContext.completeTransition(finished && !transitionContext.transitionWasCancelled)
        }
    }
}
