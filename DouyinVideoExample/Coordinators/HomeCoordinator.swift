import UIKit

/// 首页协调器
/// 职责：
/// 1. 创建并配置 HomeViewController + HomeViewModel
/// 2. 处理首页到详情页的导航（push）
/// 3. 处理首页到全屏播放的导航（present）
@MainActor
class HomeCoordinator: Coordinator {

    var childCoordinators: [Coordinator] = []
    weak var parentCoordinator: Coordinator?

    private let navigationController: UINavigationController
    private let viewModel: HomeViewModel
    private let playback: DYPlaybackCoordinating

    private var fullscreenTransitioningDelegate: FullscreenVideoTransitioningDelegate?

    init(
        navigationController: UINavigationController,
        viewModel: HomeViewModel? = nil,
        playback: DYPlaybackCoordinating = DYPlayerManager.shared
    ) {
        self.navigationController = navigationController
        self.viewModel = viewModel ?? HomeViewModel(playback: playback)
        self.playback = playback
    }

    func start() {
        let homeVC = HomeViewController(viewModel: viewModel, playback: playback)
        homeVC.coordinator = self
        navigationController.viewControllers = [homeVC]
    }

    /// 导航到详情页
    /// - Parameters:
    ///   - videoURL: 视频地址
    ///   - seekTime: 跳转时间
    ///   - player: 播放器会话
    func showDetail(videoURL: URL, seekTime: TimeInterval, player: DYVideoPlayerSession) {
        let detailCoordinator = DetailCoordinator(
            navigationController: navigationController,
            videoURL: videoURL,
            seekTime: seekTime,
            player: player,
            playback: playback
        )
        detailCoordinator.parentCoordinator = self
        detailCoordinator.onPlayRecommended = { [weak self] in
            self?.handlePlayRecommended()
        }
        childCoordinators.append(detailCoordinator)
        detailCoordinator.start()
    }

    /// 处理推荐视频播放：通知 HomeViewController 加载更多数据并播放
    private func handlePlayRecommended() {
        guard let homeVC = navigationController.viewControllers.first as? HomeViewController else { return }
        homeVC.playRecommendedVideo()
    }

    /// 呈现全屏播放
    /// - Parameters:
    ///   - videoURL: 视频地址
    ///   - currentTime: 当前播放时间
    ///   - aspectRatio: 视频宽高比
    ///   - orientationMask: 全屏方向
    ///   - player: 播放器会话
    ///   - originView: 转场动画原始视图
    ///   - onDismiss: 退出全屏回调
    func presentFullscreen(
        videoURL: URL,
        currentTime: TimeInterval,
        aspectRatio: Double?,
        orientationMask: UIInterfaceOrientationMask,
        player: DYVideoPlayerSession,
        originView: UIView,
        onDismiss: @escaping () -> Void
    ) {
        let fullscreenVC = FullscreenVideoViewController(
            videoURL: videoURL,
            currentTime: currentTime,
            aspectRatio: aspectRatio,
            fullscreenOrientationMask: orientationMask,
            player: player,
            playback: playback
        )
        fullscreenVC.onDismiss = { [weak self] in
            self?.fullscreenTransitioningDelegate = nil
            onDismiss()
        }

        let transitionDelegate = FullscreenVideoTransitioningDelegate(
            originView: originView,
            fullscreenOrientationMask: orientationMask
        )
        fullscreenTransitioningDelegate = transitionDelegate
        fullscreenVC.transitioningDelegate = transitionDelegate
        fullscreenVC.modalPresentationStyle = .fullScreen

        navigationController.present(fullscreenVC, animated: true, completion: nil)
    }
}
