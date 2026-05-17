import UIKit
import Combine

/// 首页视图模型
/// 职责：
/// 1. 管理视频数据源（加载、更新）
/// 2. 维护播放器 UI 状态（播放状态、进度、缓冲等），供 VC 绑定
/// 3. 监听 PlayerCoordinator 事件并转换为 UI 可消费的 Published 属性
/// 4. 管理视频恢复进度
/// 5. 封装播放器控制方法，VC 不再直接访问 PlayerCoordinator
/// 6. 调度视频预加载策略
@MainActor
class HomeViewModel: ObservableObject {

    // MARK: - Data Source

    /// 视频列表数据
    @Published var videos: [VideoModel] = []

    // MARK: - Player UI State

    /// 当前播放器状态（用于更新 Cell 中的控制视图）
    @Published private(set) var playerState: DYPlayerState = .idle

    /// 当前播放进度信息
    @Published private(set) var progressInfo: (progress: Double, currentTime: Double, totalTime: Double) = (0, 0, 0)

    /// 当前缓冲进度
    @Published private(set) var bufferProgress: Double = 0

    /// 当前正在播放的 IndexPath
    @Published private(set) var currentPlayingIndexPath: IndexPath?

    /// 是否正在拖拽进度条
    var isDraggingProgress: Bool = false

    /// 播放器开始播放时的直接回调（绕过 Combine 管道，减少延迟）
    /// 用于封面图淡出等需要即时响应的场景
    var onPlayerStartPlaying: (() -> Void)?

    // MARK: - Dependencies

    /// 播放器协调器（内部依赖，外部不再直接访问）
    private let coordinator: PlayerCoordinator

    /// 播放编排服务，与 PlayerCoordinator 共享同一实例
    private let playback: DYPlaybackCoordinating

    /// 预加载管理器
    private let preloadManager: VideoPreloadManager

    /// 播放恢复时间存储（与 PlayerCoordinator 共享同一实例）
    let resumeTimeStore: ResumeTimeStore

    /// Combine 订阅集合
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    /// 初始化视图模型
    /// - Parameters:
    ///   - coordinator: 播放器协调器
    ///   - playback: 播放编排服务，与 PlayerCoordinator 共享同一实例
    ///   - preloadManager: 预加载管理器
    ///   - resumeTimeStore: 播放恢复时间存储
    init(
        coordinator: PlayerCoordinator? = nil,
        playback: DYPlaybackCoordinating? = nil,
        preloadManager: VideoPreloadManager? = nil,
        resumeTimeStore: ResumeTimeStore = ResumeTimeStore()
    ) {
        let playback = playback ?? DYPlayerManager.shared
        self.playback = playback
        self.coordinator = coordinator ?? PlayerCoordinator(playback: playback, resumeTimeStore: resumeTimeStore)
        self.preloadManager = preloadManager ?? .shared
        self.resumeTimeStore = resumeTimeStore
        bindCoordinator()
        loadData()
    }

    // MARK: - Data Loading

    /// 加载视频数据（模拟网络请求）
    func loadData() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let data = VideoModel.mockData()
            DispatchQueue.main.async {
                self.videos = data
            }
        }
    }

    // MARK: - Player Control（封装 PlayerCoordinator，VC 不再直接访问 coordinator）

    /// 当前播放器实例的便捷访问
    var currentPlayer: DYVideoPlayer {
        return coordinator.currentPlayer
    }

    /// 在指定容器视图中播放视频
    /// - Parameters:
    ///   - indexPath: 视频在列表中的位置
    ///   - containerView: 承载播放器画面的视图
    func playVideo(at indexPath: IndexPath, containerView: UIView) {
        let index = indexPath.item
        guard videos.indices.contains(index) else { return }
        let video = videos[index]
        coordinator.playVideo(
            at: indexPath,
            video: video,
            containerView: containerView,
            videos: videos
        )
        updatePreloadStrategy(currentURL: video.videoURL, currentIndex: index)
    }

    /// 暂停当前播放器
    func pauseCurrent() {
        coordinator.pauseCurrent()
    }

    /// 恢复当前播放器
    func resumeCurrent() {
        coordinator.resumeCurrent()
    }

    /// 当前播放器 Seek
    func seekCurrent(to time: TimeInterval, isPrecise: Bool = true, completion: ((Bool) -> Void)? = nil) {
        coordinator.seekCurrent(to: time, isPrecise: isPrecise, completion: completion)
    }

    /// 设置当前播放器倍速
    func setCurrentPlaybackRate(_ rate: Float) {
        coordinator.setCurrentPlaybackRate(rate)
    }

    /// 设置当前播放器画面填充模式
    func setCurrentVideoGravity(_ gravity: DYVideoGravity) {
        coordinator.setCurrentVideoGravity(gravity)
    }

    /// 应用播放器配置
    func applyPlayerConfiguration(_ configuration: DYVideoPlayerConfiguration) {
        coordinator.applyConfiguration(configuration)
    }

    /// 切换当前播放器播放/暂停
    func togglePlayPause() {
        coordinator.togglePlayPause()
    }

    /// 保存当前播放进度
    func saveResumeTime(for indexPath: IndexPath?) {
        coordinator.saveResumeTime(for: indexPath)
    }

    /// 恢复播放器到指定容器（从详情页/全屏返回时调用）
    func restorePlayer(at indexPath: IndexPath, containerView: UIView) {
        guard videos.indices.contains(indexPath.item) else { return }
        let video = videos[indexPath.item]
        coordinator.restorePlayer(at: indexPath, containerView: containerView, video: video)
    }

    /// 全屏退出后恢复播放器到指定容器
    func restoreAfterFullscreen(at indexPath: IndexPath, containerView: UIView) {
        guard videos.indices.contains(indexPath.item) else { return }
        let video = videos[indexPath.item]
        coordinator.restoreAfterFullscreen(at: indexPath, containerView: containerView, video: video)
    }

    /// 当 Cell 即将显示时，检查是否有已预加载的播放器需要绑定容器
    func bindPreloadedPlayerIfNeeded(at index: Int, containerView: UIView) -> DYVideoPlayer? {
        guard videos.indices.contains(index) else { return nil }
        let video = videos[index]
        return coordinator.bindPreloadedPlayerIfNeeded(at: index, containerView: containerView, video: video)
    }

    /// 当 Cell 结束显示时，如果是当前播放的视频则暂停
    func didEndDisplaying(at indexPath: IndexPath) {
        coordinator.didEndDisplaying(at: indexPath)
    }

    // MARK: - Preload Dispatch

    /// 更新预加载策略（在列表滚动或数据刷新时调用）
    /// - Parameters:
    ///   - currentURL: 当前正在播放的视频 URL
    ///   - currentIndex: 当前播放项在列表中的位置
    func updatePreloadStrategy(currentURL: URL?, currentIndex: Int?) {
        let allURLs = videos.map { $0.videoURL }
        preloadManager.updateStrategy(
            currentURL: currentURL,
            allURLs: allURLs,
            currentIndex: currentIndex
        )
    }

    // MARK: - Private Methods

    /// 绑定 PlayerCoordinator 的事件流，将播放器状态映射为 UI 状态
    private func bindCoordinator() {
        coordinator.$currentPlayingIndexPath
            .receive(on: DispatchQueue.main)
            .sink { [weak self] indexPath in
                self?.currentPlayingIndexPath = indexPath
            }
            .store(in: &cancellables)

        coordinator.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleCoordinatorEvent(event)
            }
            .store(in: &cancellables)
    }

    /// 处理 PlayerCoordinator 发出的事件，更新对应的 Published 属性
    /// - Parameter event: 播放器协调器事件
    private func handleCoordinatorEvent(_ event: PlayerCoordinatorEvent) {
        switch event {
        case .stateChanged(let state, _):
            playerState = state
            if state == .playing {
                onPlayerStartPlaying?()
            }
        case .progressUpdated(let progress, let currentTime, let totalTime, _):
            if !isDraggingProgress {
                progressInfo = (progress, currentTime, totalTime)
            }
        case .bufferUpdated(let progress, _):
            bufferProgress = progress
        case .error, .finished, .videoSizeChanged:
            break
        }
    }
}
