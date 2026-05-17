import UIKit

/// 应用级协调器
/// 职责：管理导航控制器，启动 HomeCoordinator
@MainActor
class AppCoordinator: Coordinator {

    var childCoordinators: [Coordinator] = []

    private let navigationController: UINavigationController

    init(navigationController: UINavigationController) {
        self.navigationController = navigationController
    }

    func start() {
        let homeCoordinator = HomeCoordinator(navigationController: navigationController)
        childCoordinators.append(homeCoordinator)
        homeCoordinator.parentCoordinator = self
        homeCoordinator.start()
    }
}
