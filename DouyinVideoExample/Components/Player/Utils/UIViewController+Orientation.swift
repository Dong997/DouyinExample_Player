import UIKit

/// 屏幕方向配置协议
/// 遵循此协议的 ViewController 可声明自身支持的屏幕方向
/// 默认返回 .portrait（竖屏），全屏等特殊场景覆盖即可
protocol DYOrientationConfigurable: AnyObject {
    /// 当前 VC 支持的屏幕方向，默认 .portrait
    var dySupportedOrientations: UIInterfaceOrientationMask { get }
    /// 是否允许自动旋转，默认根据 dySupportedOrientations 推导
    var dyShouldAutorotate: Bool { get }
}

extension DYOrientationConfigurable {
    var dySupportedOrientations: UIInterfaceOrientationMask { .portrait }
    var dyShouldAutorotate: Bool {
        switch dySupportedOrientations {
        case .portrait:
            return false
        default:
            return true
        }
    }
}

/// 支持屏幕方向转发的导航控制器
/// 将 supportedInterfaceOrientations / shouldAutorotate 转发给 topViewController
/// 未遵循 DYOrientationConfigurable 的 VC 默认按 .portrait 处理
class DYOrientationNavigationController: UINavigationController {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        (topViewController as? DYOrientationConfigurable)?.dySupportedOrientations ?? .portrait
    }

    override var shouldAutorotate: Bool {
        (topViewController as? DYOrientationConfigurable)?.dyShouldAutorotate ?? false
    }
}
