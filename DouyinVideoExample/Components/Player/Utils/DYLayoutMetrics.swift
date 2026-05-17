import UIKit

/// 通用布局度量工具。
/// 统一计算安全区、状态栏、导航栏以及播放器浮层控件的动态位置。
enum DYLayoutMetrics {

    struct ChromeMetrics {
        let safeAreaInsets: UIEdgeInsets
        let statusBarHeight: CGFloat
        let navigationBarHeight: CGFloat

        var topChromeHeight: CGFloat {
            statusBarHeight + navigationBarHeight
        }
    }

    struct FloatingButtonLayout {
        let leading: CGFloat
        let top: CGFloat
        let size: CGFloat
    }

    static func chromeMetrics(for viewController: UIViewController) -> ChromeMetrics {
        let view = viewController.view
        let safeAreaInsets = view?.safeAreaInsets ?? .zero
        let statusBarHeight = view?.window?.windowScene?.statusBarManager?.statusBarFrame.height ?? 0

        let navigationBar = viewController.navigationController?.navigationBar
        let navigationBarHeight: CGFloat
        if let navigationBar = navigationBar, !navigationBar.isHidden {
            navigationBarHeight = navigationBar.frame.height
        } else {
            navigationBarHeight = 0
        }

        return ChromeMetrics(
            safeAreaInsets: safeAreaInsets,
            statusBarHeight: statusBarHeight,
            navigationBarHeight: navigationBarHeight
        )
    }

    static func fullscreenCloseButtonLayout(
        for viewController: UIViewController,
        orientationMask: UIInterfaceOrientationMask,
        horizontalMargin: CGFloat = 16,
        verticalMargin: CGFloat = 16,
        buttonSize: CGFloat = 32
    ) -> FloatingButtonLayout {
        let metrics = chromeMetrics(for: viewController)
        let isLandscape = orientationMask.isDYLandscape

        let leading = metrics.safeAreaInsets.left + horizontalMargin
        let topReference = isLandscape
            ? metrics.safeAreaInsets.top
            : max(metrics.safeAreaInsets.top, metrics.topChromeHeight)

        return FloatingButtonLayout(
            leading: leading,
            top: topReference + verticalMargin,
            size: buttonSize
        )
    }
}

private extension UIInterfaceOrientationMask {
    var isDYLandscape: Bool {
        switch self {
        case .landscape, .landscapeLeft, .landscapeRight:
            return true
        default:
            return false
        }
    }
}
