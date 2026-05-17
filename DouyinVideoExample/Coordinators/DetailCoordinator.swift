/// @file DetailCoordinator.swift
/// @brief 详情页协调器 — 管理详情页导航与推荐视频切换
/// @author jscn-app
/// @date 2025-05-14
import UIKit

/// 详情页协调器
/// 职责：
/// 1. 创建并配置 DetailViewController
/// 2. 处理详情页的返回导航
/// 3. 处理推荐视频导航（通过 onPlayRecommended 回调通知 HomeCoordinator）
@MainActor
class DetailCoordinator: Coordinator {

    var childCoordinators: [Coordinator] = []
    weak var parentCoordinator: Coordinator?

    private let navigationController: UINavigationController
    private let videoURL: URL
    private let seekTime: TimeInterval
    private let player: DYVideoPlayerSession
    private let playback: DYPlaybackCoordinating

    /// 推荐视频播放回调，由 HomeCoordinator 设置
    /// 返回首页后触发加载更多数据并播放推荐视频
    var onPlayRecommended: (() -> Void)?

    init(
        navigationController: UINavigationController,
        videoURL: URL,
        seekTime: TimeInterval,
        player: DYVideoPlayerSession,
        playback: DYPlaybackCoordinating
    ) {
        self.navigationController = navigationController
        self.videoURL = videoURL
        self.seekTime = seekTime
        self.player = player
        self.playback = playback
    }

    func start() {
        let detailVC = DetailViewController(
            videoURL: videoURL,
            seekTime: seekTime,
            player: player,
            playback: playback
        )
        detailVC.coordinator = self
        navigationController.pushViewController(detailVC, animated: true)
    }

    /// 返回首页
    func navigateBack() {
        navigationController.popViewController(animated: true)
        parentCoordinator?.childDidFinish(self)
    }

    /// 播放推荐视频
    /// 返回首页后通过 onPlayRecommended 回调通知 HomeCoordinator 加载更多数据并播放
    func playRecommendedVideo() {
        let onPlayRecommended = self.onPlayRecommended
        navigationController.popViewController(animated: true)
        parentCoordinator?.childDidFinish(self)
        DispatchQueue.main.async {
            onPlayRecommended?()
        }
    }
}
