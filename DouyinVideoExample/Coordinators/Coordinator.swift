import UIKit

/// 导航协调器协议
/// 统一管理导航流，将导航逻辑从 ViewController 中解耦
@MainActor
protocol Coordinator: AnyObject {
    /// 子协调器列表
    var childCoordinators: [Coordinator] { get set }
    /// 启动协调器
    func start()
    /// 清理子协调器
    func childDidFinish(_ child: Coordinator?)
}

extension Coordinator {
    func childDidFinish(_ child: Coordinator?) {
        guard let child = child else { return }
        childCoordinators.removeAll { $0 === child }
    }
}
