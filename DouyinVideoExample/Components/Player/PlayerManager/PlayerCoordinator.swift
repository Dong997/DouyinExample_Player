import Foundation
import Combine
import UIKit

/// 播放器协调器状态变更事件
/// 用于将播放器内部状态变化以枚举形式通知外部，避免外部直接监听多个 @Published 属性
enum PlayerCoordinatorEvent {
    case stateChanged(DYPlayerState, IndexPath)
    case progressUpdated(progress: Double, currentTime: Double, totalTime: Double, IndexPath)
    case bufferUpdated(Double, IndexPath)
    case error(Error?, IndexPath)
    case finished(IndexPath)
    case videoSizeChanged(CGSize, IndexPath)
}

/// 播放器协调器
/// 从 HomeViewController 中抽取的播放器生命周期管理逻辑
/// 职责：
/// 1. 管理播放器实例池（playerMap）的创建、复用、回收
/// 2. 协调播放/暂停/Seek/倍速等播放控制
/// 3. 处理播放器容器视图迁移（列表 ↔ 全屏）
/// 4. 通过 Combine Publisher 将播放器事件通知外部
///
/// 设计原则：
/// - 所有播放器操作通过注入的 `DYPlaybackCoordinating` 协议执行，不直接访问全局单例
/// - `DYPlayerPool` 仅作为底层对象池，本层在其之上维护索引到播放器的映射关系
/// - 预加载策略调度由上层 `HomeViewModel` 统一管理，本层不参与
@MainActor
class PlayerCoordinator: NSObject {

    // MARK: - Published State

    /// 当前正在播放的 IndexPath
    @Published private(set) var currentPlayingIndexPath: IndexPath?

    /// 当前正在播放的视频唯一标识，用于 ResumeTimeStore 的 key
    private var currentVideoID: String?

    /// 播放器事件流，外部通过 sink 订阅即可收到所有播放器回调
    let eventPublisher = PassthroughSubject<PlayerCoordinatorEvent, Never>()

    // MARK: - Properties

    /// 播放器实例映射表，key 为视频在列表中的索引
    /// 在 DYPlayerPool 之上提供索引级别的播放器追踪能力
    private var playerMap: [Int: DYVideoPlayer] = [:]

    /// 播放编排服务，通过协议注入，不再直接访问 DYPlayerManager.shared
    private let playback: DYPlaybackCoordinating

    /// 重试策略处理器
    private let retryHandler: PlaybackRetryHandler

    /// 播放恢复时间存储（与 HomeViewModel 共享同一实例）
    private let resumeTimeStore: ResumeTimeStore

    /// 网络状态监听器
    private let networkMonitor: NetworkMonitor

    /// Combine 订阅集合
    private var cancellables = Set<AnyCancellable>()

    /// 最近一次播放失败的信息，用于网络恢复后重试
    private var lastFailureInfo: (indexPath: IndexPath, video: VideoModel?, containerView: UIView?, videos: [VideoModel])?

    /// 最近一次成功发起播放的上下文，用于错误时记录重试所需信息
    private var lastPlayContext: (indexPath: IndexPath, video: VideoModel, containerView: UIView, videos: [VideoModel])?

    /// 延迟暂停的旧播放器引用（双播放器交替策略核心）
    /// 新播放器启动前不立即暂停旧播放器，避免切换时出现黑屏
    /// 当新播放器进入 .playing 状态后，再暂停此引用指向的旧播放器
    private var pendingPausePlayer: DYVideoPlayer?

    /// 最近播放过的播放器缓存（暂停但未 stop，回滑时可快速恢复）
    /// 按淘汰顺序排列，最旧的在前、最新在后
    /// 避免回滑 1~2 个位置时需要重新加载视频，实现抖音风格的快速回滑体验
    private var recentlyPlayedCache: [(index: Int, player: DYVideoPlayer)] = []

    /// 最近播放缓存的最大容量（超出时淘汰最旧的，stop+reset 归还对象池）
    private let maxRecentlyPlayedCount = 2

    /// 播放器级预热延迟任务。快速滑动时会被新的播放索引取消，只保留字节级预缓存。
    private var pendingPlayerPreloadTask: Task<Void, Never>?

    /// 当前播放稳定多久后再做 AVPlayer/AVPlayerItem 预热。
    private let playerPreloadDelayNanos: UInt64 = 350_000_000

    /// 当前"主"播放器的便捷访问，通过注入的 playback 协议获取
    var currentPlayer: DYVideoPlayer {
        return playback.currentPlayer
    }

    // MARK: - Initialization

    /// 初始化播放器协调器
    /// - Parameters:
    ///   - playback: 播放编排服务，组合对象池与缓存代理能力
    ///   - cache: 缓存黑名单服务，用于重试策略
    ///   - resumeTimeStore: 播放恢复时间存储
    ///   - networkMonitor: 网络状态监听器
    init(
        playback: DYPlaybackCoordinating? = nil,
        cache: VideoCacheBlacklisting? = nil,
        resumeTimeStore: ResumeTimeStore = ResumeTimeStore(),
        networkMonitor: NetworkMonitor? = nil
    ) {
        let playback = playback ?? DYPlayerManager.shared
        let cache = cache ?? VideoCacheManager.shared
        self.playback = playback
        self.retryHandler = PlaybackRetryHandler(cache: cache)
        self.resumeTimeStore = resumeTimeStore
        self.networkMonitor = networkMonitor ?? .shared
        super.init()
        bindNetworkStatus()
    }

    // MARK: - Network Recovery

    /// 绑定网络状态监听，网络恢复后自动重试失败的播放
    private func bindNetworkStatus() {
        networkMonitor.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                if case .connected = status {
                    self.retryOnNetworkRecovery()
                }
            }
            .store(in: &cancellables)
    }

    /// 网络恢复后重试最近一次失败的播放
    private func retryOnNetworkRecovery() {
        guard let failure = lastFailureInfo else { return }
        lastFailureInfo = nil

        guard failure.indexPath == currentPlayingIndexPath,
              let video = failure.video,
              let containerView = failure.containerView else { return }

        AppLog.player.info("Network recovered, retrying playback at index \(failure.indexPath.item)")
        playVideo(at: failure.indexPath, video: video, containerView: containerView, videos: failure.videos)
    }

    deinit {
        pendingPlayerPreloadTask?.cancel()
        recentlyPlayedCache.forEach {
            $0.player.multicastDelegate.remove(self)
            $0.player.stop()
            $0.player.reset()
        }
        recentlyPlayedCache.removeAll()
        playerMap.values.forEach {
            $0.multicastDelegate.remove(self)
            $0.stop()
            $0.reset()
        }
        playerMap.removeAll()
    }

    // MARK: - Play Control

    /// 在指定容器视图中播放视频
    /// - Parameters:
    ///   - indexPath: 视频在列表中的位置
    ///   - video: 视频模型
    ///   - containerView: 承载播放器画面的视图
    ///   - videos: 完整视频列表（用于预加载播放器管理）
    func playVideo(at indexPath: IndexPath, video: VideoModel, containerView: UIView, videos: [VideoModel]) {
        let index = indexPath.item
        AppLog.flicker.info("[FlickerTrace] Coordinator playVideo begin index=\(index), currentIndex=\(String(describing: self.currentPlayingIndexPath)), currentPlayer=\(self.playerIdentity(self.currentPlayer)), currentPlayerState=\(String(describing: self.currentPlayer.state)), currentContainerSet=\(self.currentPlayer.containerView != nil), targetContainer=\(String(ObjectIdentifier(containerView).hashValue, radix: 16)), url=\(video.videoURL.lastPathComponent)")

        // 双播放器交替策略：先暂停上一次延迟暂停的旧播放器（快速连续滑动场景）
        if let pendingPausePlayer = pendingPausePlayer {
            AppLog.flicker.info("[FlickerTrace] Coordinator pause previous pending player before switch player=\(self.playerIdentity(pendingPausePlayer)), state=\(String(describing: pendingPausePlayer.state))")
            pendingPausePlayer.pause()
        }
        pendingPausePlayer = nil

        // 记录旧播放器引用，但不立即暂停 —— 等新播放器启动后再停旧
        let previousIndex = currentPlayingIndexPath?.item
        let previousPlayer: DYVideoPlayer? = (currentPlayingIndexPath != indexPath) ? currentPlayer : nil
        if let current = currentPlayingIndexPath, current != indexPath {
            saveResumeTime(for: current)
        }

        currentPlayingIndexPath = indexPath
        currentVideoID = video.id
        lastPlayContext = (indexPath, video, containerView, videos)
        lastFailureInfo = nil
        retryHandler.reset()

        let player: DYVideoPlayer
        if let existing = playerMap[index] {
            player = existing
            AppLog.flicker.info("[FlickerTrace] Coordinator use existing player index=\(index), player=\(self.playerIdentity(player)), state=\(String(describing: player.state)), currentURL=\(String(describing: player.currentURL?.absoluteString)), readyForDisplay=\(player.isReadyForDisplay), preloadedReady=\(player.isPreloadedAndReady)")
        } else if let cached = takeFromRecentlyPlayedCache(index: index) {
            // 缓存命中：播放器已加载该视频，直接复用（回滑快速恢复）
            player = cached
            playerMap[index] = player
            AppLog.flicker.info("[FlickerTrace] Coordinator use recently cached player index=\(index), player=\(self.playerIdentity(player)), state=\(String(describing: player.state)), currentURL=\(String(describing: player.currentURL?.absoluteString)), readyForDisplay=\(player.isReadyForDisplay), preloadedReady=\(player.isPreloadedAndReady)")
        } else if let acquired = playback.acquirePreloadPlayer() {
            // 池可能回收了 recentlyPlayedCache 中的播放器，清理悬垂引用防止后续误杀
            removeStaleCacheEntries(for: acquired)
            player = acquired
            playerMap[index] = player
            AppLog.flicker.info("[FlickerTrace] Coordinator acquired pool player index=\(index), player=\(self.playerIdentity(player)), state=\(String(describing: player.state)), readyForDisplay=\(player.isReadyForDisplay), preloadedReady=\(player.isPreloadedAndReady)")
        } else {
            player = currentPlayer
            playerMap[index] = player
            AppLog.flicker.warning("[FlickerTrace] Coordinator fallback to currentPlayer index=\(index), player=\(self.playerIdentity(player)), state=\(String(describing: player.state)), readyForDisplay=\(player.isReadyForDisplay), preloadedReady=\(player.isPreloadedAndReady)")
        }

        playback.promoteToCurrent(player)
        player.multicastDelegate.add(self)

        if player.isPlaying(url: video.videoURL), player.containerView !== containerView {
            AppLog.flicker.info("[FlickerTrace] Coordinator update container before play index=\(index), player=\(self.playerIdentity(player)), oldContainerSet=\(player.containerView != nil), targetContainer=\(String(ObjectIdentifier(containerView).hashValue, radix: 16))")
            player.updateContainer(containerView)
        }

        // 仅当新旧播放器是不同实例时才启用延迟暂停
        // 同一实例复用时 play() 内部会 stop() 旧资源，无需延迟
        let isSeamlessSwitch = previousPlayer != nil && previousPlayer !== player
        if isSeamlessSwitch {
            AppLog.flicker.info("[FlickerTrace] Coordinator defer previous pause previousIndex=\(String(describing: previousIndex)), oldPlayer=\(previousPlayer.map { self.playerIdentity($0) } ?? "nil"), newPlayer=\(self.playerIdentity(player))")
            pendingPausePlayer = previousPlayer
        } else {
            if let previousPlayer = previousPlayer {
                AppLog.flicker.info("[FlickerTrace] Coordinator immediate previous pause previousIndex=\(String(describing: previousIndex)), oldPlayer=\(self.playerIdentity(previousPlayer)), newPlayer=\(self.playerIdentity(player))")
            }
            previousPlayer?.pause()
        }

        let resumeTime = resumeTimeStore.resumeTime(for: video.id)
        if resumeTime > 0 {
            AppLog.player.info("Coordinator request play index=\(index), resumeTime=\(resumeTime)")
            playback.playWithCache(originalURL: video.videoURL, in: containerView, seekTo: resumeTime, use: player)
        } else {
            AppLog.player.info("Coordinator request play index=\(index), resumeTime=nil")
            playback.playWithCache(originalURL: video.videoURL, in: containerView, seekTo: nil, use: player)
        }

        // 预加载就绪的播放器已渲染首帧，attach 后画面立即可见
        // 此时可以安全地立即暂停旧播放器（新画面已展示，不会黑屏）
        if isSeamlessSwitch, player.isPreloadedAndReady {
            AppLog.flicker.info("[FlickerTrace] Coordinator preloaded player ready, pause pending immediately index=\(index), player=\(self.playerIdentity(player))")
            pendingPausePlayer?.pause()
            pendingPausePlayer = nil
        }

        managePreloadPlayers(currentIndex: index, previousIndex: previousIndex, videos: videos)
    }

    /// 暂停当前播放器
    func pauseCurrent() {
        currentPlayer.pause()
    }

    /// 恢复当前播放器
    func resumeCurrent() {
        currentPlayer.resume()
    }

    /// 当前播放器 Seek
    func seekCurrent(to time: TimeInterval, isPrecise: Bool = true, completion: ((Bool) -> Void)? = nil) {
        currentPlayer.seek(to: time, isPrecise: isPrecise, completion: completion)
    }

    /// 设置当前播放器倍速
    func setCurrentPlaybackRate(_ rate: Float) {
        var configuration = playback.configuration
        configuration.playbackRate = rate
        playback.applyConfiguration(configuration)
    }

    /// 设置当前播放器画面填充模式
    func setCurrentVideoGravity(_ gravity: DYVideoGravity) {
        var configuration = playback.configuration
        configuration.videoGravity = gravity
        playback.applyConfiguration(configuration)
    }

    /// 应用播放器配置到当前播放编排层
    func applyConfiguration(_ configuration: DYVideoPlayerConfiguration) {
        playback.applyConfiguration(configuration)
    }

    /// 切换当前播放器播放/暂停
    func togglePlayPause() {
        if currentPlayer.state == .playing {
            currentPlayer.pause()
        } else {
            currentPlayer.resume()
        }
    }

    /// 保存当前播放进度（用于页面切换时记录恢复点）
    /// 使用视频唯一 ID 而非列表索引，列表插入/删除/排序后仍能正确恢复
    func saveResumeTime(for indexPath: IndexPath?) {
        guard let indexPath = indexPath, let videoID = currentVideoID else { return }
        let time = currentPlayer.currentTime
        resumeTimeStore.update(videoID: videoID, time: time)
    }

    // MARK: - Player Restoration

    /// 检查并恢复播放器到指定容器（从详情页/全屏返回时调用）
    /// - Parameters:
    ///   - indexPath: 目标位置
    ///   - containerView: 承载视图
    ///   - video: 视频模型
    func restorePlayer(at indexPath: IndexPath, containerView: UIView, video: VideoModel) {
        let player = currentPlayer
        player.multicastDelegate.add(self)

        if player.containerView !== containerView {
            if player.isPlaying(url: video.videoURL) {
                player.updateContainer(containerView)
                if player.state != .playing {
                    player.resume()
                }
            } else {
                playback.playWithCache(originalURL: video.videoURL, in: containerView, seekTo: nil, use: nil)
            }
        } else {
            if player.state != .playing {
                player.resume()
            }
        }
    }

    /// 全屏退出后恢复播放器到指定容器
    /// - Parameters:
    ///   - indexPath: 目标位置
    ///   - containerView: 承载视图
    ///   - video: 视频模型
    func restoreAfterFullscreen(at indexPath: IndexPath, containerView: UIView, video: VideoModel) {
        let player = currentPlayer
        let currentTime = player.currentTime
        player.multicastDelegate.add(self)
        if player.isPlaying(url: video.videoURL) {
            player.updateContainer(containerView)
            if player.state != .playing {
                player.resume()
            }
        } else {
            playback.playWithCache(originalURL: video.videoURL, in: containerView, seekTo: currentTime, use: nil)
        }
        currentPlayingIndexPath = indexPath
        currentVideoID = video.id
    }

    // MARK: - Preload Management

    /// 管理播放器级预热：保留当前索引与滑动方向上的下一屏，超出范围的移入最近播放缓存（暂停不销毁）。
    ///
    /// 字节级预缓存由 `VideoPreloadManager` 负责当前前后窗口；这里仅对“最可能马上切到”的一条做
    /// AVPlayer/AVPlayerItem 预热，避免前后两条同时走播放器 prepare 与缓存 Range 预拉造成重复资源占用。
    /// 回滑已播放过的视频时优先命中最近播放缓存，未命中时仍可受益于字节级预缓存。
    /// - Parameters:
    ///   - currentIndex: 当前播放索引
    ///   - previousIndex: 上一次播放索引，用于判断滑动方向；首次播放默认预热下一条
    ///   - videos: 完整视频列表
    func managePreloadPlayers(currentIndex: Int, previousIndex: Int?, videos: [VideoModel]) {
        var keepIndices = Set([currentIndex])
        let predictedIndex = predictedPreloadIndex(currentIndex: currentIndex, previousIndex: previousIndex, videos: videos)
        if let predictedIndex = predictedIndex {
            keepIndices.insert(predictedIndex)
        }

        let keysToRemove = playerMap.keys.filter { !keepIndices.contains($0) }
        for key in keysToRemove {
            if let p = playerMap.removeValue(forKey: key) {
                if p !== currentPlayer {
                    p.multicastDelegate.remove(self)
                    p.pause()
                    // 移入最近播放缓存而非 stop+reset，回滑时可直接复用
                    recentlyPlayedCache.removeAll { $0.index == key }
                    recentlyPlayedCache.append((index: key, player: p))
                    AppLog.player.info("Coordinator move player to recentCache index=\(key), player=\(self.playerIdentity(p)), recent=\(self.recentCacheDebugDescription())")
                }
            }
        }

        // 淘汰超出容量的缓存条目，stop+reset 归还对象池
        trimRecentlyPlayedCache()

        AppLog.player.info("Coordinator preload policy currentIndex=\(currentIndex), previousIndex=\(String(describing: previousIndex)), predicted=\(String(describing: predictedIndex)), keep=\(self.indexSetDescription(keepIndices)), map=\(self.playerMapDebugDescription()), recent=\(self.recentCacheDebugDescription())")

        schedulePlayerPreloadIfNeeded(predictedIndex: predictedIndex, currentIndex: currentIndex, videos: videos)
    }

    /// 根据播放索引变化推断下一次最可能进入的页面：下滑/首次播放预热后一条，上滑预热前一条。
    private func predictedPreloadIndex(currentIndex: Int, previousIndex: Int?, videos: [VideoModel]) -> Int? {
        let direction: Int
        if let previousIndex = previousIndex, currentIndex < previousIndex {
            direction = -1
        } else {
            direction = 1
        }

        let candidate = currentIndex + direction
        guard videos.indices.contains(candidate) else { return nil }
        return candidate
    }

    private func schedulePlayerPreloadIfNeeded(predictedIndex: Int?, currentIndex: Int, videos: [VideoModel]) {
        pendingPlayerPreloadTask?.cancel()

        guard let predictedIndex = predictedIndex else {
            AppLog.player.debug("Coordinator player preload skipped: no predicted index")
            return
        }

        let snapshotVideos = videos
        pendingPlayerPreloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.playerPreloadDelayNanos ?? 350_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self = self,
                      self.currentPlayingIndexPath?.item == currentIndex,
                      snapshotVideos.indices.contains(predictedIndex) else { return }
                AppLog.player.info("Coordinator delayed player preload fire currentIndex=\(currentIndex), predicted=\(predictedIndex)")
                self.preloadVideo(at: predictedIndex, videos: snapshotVideos)
                self.pendingPlayerPreloadTask = nil
            }
        }
        AppLog.player.info("Coordinator delayed player preload scheduled currentIndex=\(currentIndex), predicted=\(predictedIndex)")
    }

    /// 淘汰最近播放缓存中超出容量的旧条目
    /// 被淘汰的播放器执行 stop+reset，归还给 DYPlayerPool 作为空闲实例复用
    /// 安全检查：跳过仍在 playerMap 中或为 currentPlayer 的条目（防止悬垂引用导致误杀）
    private func trimRecentlyPlayedCache() {
        var i = 0
        while i < recentlyPlayedCache.count && recentlyPlayedCache.count > maxRecentlyPlayedCount {
            let entry = recentlyPlayedCache[i]
            if isPlayerInUse(entry.player) {
                // 播放器已被复用，从缓存中移除条目但不 stop（避免杀死在用播放器）
                recentlyPlayedCache.remove(at: i)
            } else {
                AppLog.player.info("Coordinator evict recentCache index=\(entry.index), player=\(self.playerIdentity(entry.player))")
                entry.player.stop()
                entry.player.reset()
                recentlyPlayedCache.remove(at: i)
            }
        }
    }

    /// 检查播放器是否正在使用中（在 playerMap 中或为当前播放器）
    /// - Parameter player: 待检查的播放器实例
    /// - Returns: 是否正在使用
    private func isPlayerInUse(_ player: DYVideoPlayer) -> Bool {
        if player === currentPlayer { return true }
        return playerMap.values.contains(where: { $0 === player })
    }

    /// 清理 recentlyPlayedCache 中指向指定播放器实例的所有条目
    /// 在 acquirePreloadPlayer() 返回播放器后调用，防止池回收的播放器仍在 cache 中留下悬垂引用
    /// - Parameter player: 需要清理的播放器实例
    private func removeStaleCacheEntries(for player: DYVideoPlayer) {
        recentlyPlayedCache.removeAll { $0.player === player }
    }

    /// 从最近播放缓存中取出指定索引的播放器（命中则移除，未命中返回 nil）
    /// - Parameter index: 视频索引
    /// - Returns: 缓存命中的播放器，或 nil
    private func takeFromRecentlyPlayedCache(index: Int) -> DYVideoPlayer? {
        guard let idx = recentlyPlayedCache.firstIndex(where: { $0.index == index }) else { return nil }
        return recentlyPlayedCache.remove(at: idx).player
    }

    /// 预加载指定位置的视频
    /// 优先从最近播放缓存复用（回滑场景），其次从对象池获取
    /// - Parameters:
    ///   - index: 视频索引
    ///   - videos: 完整视频列表
    func preloadVideo(at index: Int, videos: [VideoModel]) {
        guard videos.indices.contains(index) else { return }
        if playerMap[index] != nil { return }

        // 缓存命中：播放器已加载该视频，直接移回 playerMap（无需重新加载）
        if let cached = takeFromRecentlyPlayedCache(index: index) {
            playerMap[index] = cached
            cached.multicastDelegate.add(self)
            AppLog.player.info("Coordinator preload hit recentCache index=\(index), player=\(self.playerIdentity(cached)), map=\(self.playerMapDebugDescription())")
            return
        }

        // 缓存未命中：从对象池获取播放器实例
        // acquirePreloadPlayer 内部会按 LRU 淘汰池中暂停/空闲的播放器
        guard let player = playback.acquirePreloadPlayer() else { return }

        // 池可能回收了 recentlyPlayedCache 中的播放器，清理悬垂引用防止后续误杀
        removeStaleCacheEntries(for: player)

        playerMap[index] = player

        let video = videos[index]
        AppLog.player.info("Coordinator preload prepare index=\(index), url=\(video.videoURL.lastPathComponent), player=\(self.playerIdentity(player)), playerState=\(String(describing: player.state)), map=\(self.playerMapDebugDescription())")
        playback.preload(originalURL: video.videoURL, use: player)
    }

    private func playerMapDebugDescription() -> String {
        let entries = playerMap.keys.sorted().compactMap { index -> String? in
            guard let player = playerMap[index] else { return nil }
            let marker = player === currentPlayer ? "*" : ""
            return "\(index):\(marker)\(playerIdentity(player)):\(String(describing: player.state))"
        }
        return "[" + entries.joined(separator: ",") + "]"
    }

    private func recentCacheDebugDescription() -> String {
        let entries = recentlyPlayedCache.map { entry in
            "\(entry.index):\(playerIdentity(entry.player)):\(String(describing: entry.player.state))"
        }
        return "[" + entries.joined(separator: ",") + "]"
    }

    private func indexSetDescription(_ indices: Set<Int>) -> String {
        "[" + indices.sorted().map(String.init).joined(separator: ",") + "]"
    }

    private func playerIdentity(_ player: DYVideoPlayerSession) -> String {
        String(ObjectIdentifier(player).hashValue, radix: 16)
    }

    /// 当 Cell 即将显示时，检查是否有已预加载的播放器需要绑定容器
    /// - Parameters:
    ///   - index: 视频索引
    ///   - containerView: 承载视图
    ///   - video: 视频模型
    /// - Returns: 如果有预加载播放器返回该播放器，否则返回 nil
    func bindPreloadedPlayerIfNeeded(at index: Int, containerView: UIView, video: VideoModel) -> DYVideoPlayer? {
        guard let player = playerMap[index] else { return nil }
        AppLog.flicker.info("[FlickerTrace] Coordinator bindPreloadedIfNeeded index=\(index), player=\(self.playerIdentity(player)), state=\(String(describing: player.state)), isPlayingURL=\(player.isPlaying(url: video.videoURL)), readyForDisplay=\(player.isReadyForDisplay), preloadedReady=\(player.isPreloadedAndReady), currentContainerSet=\(player.containerView != nil), targetContainer=\(String(ObjectIdentifier(containerView).hashValue, radix: 16))")
        if player.isPlaying(url: video.videoURL), player.containerView !== containerView {
            player.updateContainer(containerView)
        }
        return player
    }

    /// 当 Cell 结束显示时，如果是当前播放的视频则暂停
    /// - Parameter indexPath: 视频位置
    func didEndDisplaying(at indexPath: IndexPath) {
        AppLog.flicker.info("[FlickerTrace] Coordinator didEndDisplaying index=\(indexPath.item), currentIndex=\(String(describing: self.currentPlayingIndexPath)), currentPlayer=\(self.playerIdentity(self.currentPlayer)), currentState=\(String(describing: self.currentPlayer.state)), currentContainerSet=\(self.currentPlayer.containerView != nil)")
        if currentPlayingIndexPath == indexPath {
            pendingPlayerPreloadTask?.cancel()
            pendingPlayerPreloadTask = nil
            saveResumeTime(for: indexPath)
            AppLog.flicker.info("[FlickerTrace] Coordinator didEndDisplaying pauses current index=\(indexPath.item), player=\(self.playerIdentity(self.currentPlayer))")
            currentPlayer.pause()
            pendingPausePlayer = nil
            currentPlayingIndexPath = nil
            currentVideoID = nil
        }
        // 清理该索引的缓存条目（Cell 已滚出屏幕）
        // 安全检查：仅当播放器不在 playerMap 中且非 currentPlayer 时才 stop+reset
        if let idx = recentlyPlayedCache.firstIndex(where: { $0.index == indexPath.item }) {
            let entry = recentlyPlayedCache.remove(at: idx)
            if !isPlayerInUse(entry.player) {
                entry.player.stop()
                entry.player.reset()
            }
        }
    }

    /// 停止并清理所有播放器
    func stopAll() {
        pendingPlayerPreloadTask?.cancel()
        pendingPlayerPreloadTask = nil
        pendingPausePlayer = nil
        recentlyPlayedCache.forEach { $0.player.stop(); $0.player.reset() }
        recentlyPlayedCache.removeAll()
        playerMap.values.forEach {
            $0.multicastDelegate.remove(self)
            $0.stop()
            $0.reset()
        }
        playerMap.removeAll()
        currentPlayingIndexPath = nil
        currentVideoID = nil
    }
}

// MARK: - DYVideoPlayerDelegate

extension PlayerCoordinator: DYVideoPlayerDelegate {

    func player(_ player: DYVideoPlayerSession, didChangeState state: DYPlayerState) {
        AppLog.player.info("Coordinator didChangeState state=\(String(describing: state)), isCurrent=\(player === self.currentPlayer), currentIndex=\(String(describing: self.currentPlayingIndexPath)), playerURL=\(String(describing: player.currentURL?.absoluteString))")
        // 双播放器交替策略：新播放器进入 .playing 后，安全暂停旧播放器
        // 此时新画面已渲染，暂停旧播放器不会造成黑屏
        if state == .playing, let old = pendingPausePlayer, old !== player {
            old.pause()
            pendingPausePlayer = nil
        }
        guard player === currentPlayer, let indexPath = currentPlayingIndexPath else { return }
        eventPublisher.send(.stateChanged(state, indexPath))
    }

    func player(_ player: DYVideoPlayerSession, didUpdateProgress progress: Double, currentTime: Double, totalTime: Double) {
        guard player === currentPlayer, let indexPath = currentPlayingIndexPath else { return }
        eventPublisher.send(.progressUpdated(progress: progress, currentTime: currentTime, totalTime: totalTime, indexPath))
    }

    func player(_ player: DYVideoPlayerSession, didUpdateBuffer progress: Double) {
        guard player === currentPlayer, let indexPath = currentPlayingIndexPath else { return }
        eventPublisher.send(.bufferUpdated(progress, indexPath))
    }

    func player(_ player: DYVideoPlayerSession, didFailWithError error: Error?) {
        guard player === currentPlayer, let indexPath = currentPlayingIndexPath else { return }
        AppLog.player.error("Playback failed at index \(indexPath.item): \(String(describing: error))")

        if let context = lastPlayContext, context.indexPath == indexPath {
            lastFailureInfo = (indexPath: indexPath, video: context.video, containerView: context.containerView, videos: context.videos)

            let currentURL = player.currentURL ?? context.video.videoURL
            let originalURL = player.originalURL ?? context.video.videoURL

            if let retryURL = retryHandler.shouldRetry(for: error, currentURL: currentURL, originalURL: originalURL) {
                let delay = retryHandler.currentBackoffDelay()
                AppLog.player.info("Scheduling retry in \(delay)s with URL: \(retryURL)")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self,
                          self.currentPlayingIndexPath == indexPath else { return }
                    self.playback.playWithCache(
                        originalURL: retryURL,
                        in: context.containerView,
                        seekTo: nil,
                        use: player
                    )
                }
                return
            }
        }

        eventPublisher.send(.error(error, indexPath))
    }

    func playerDidFinishPlaying(_ player: DYVideoPlayerSession) {
        guard player === currentPlayer, let indexPath = currentPlayingIndexPath else { return }
        eventPublisher.send(.finished(indexPath))
    }

    func player(_ player: DYVideoPlayerSession, didUpdateVideoSize size: CGSize) {
        guard player === currentPlayer, let indexPath = currentPlayingIndexPath else { return }
        eventPublisher.send(.videoSizeChanged(size, indexPath))
    }

    func player(_ player: DYVideoPlayerSession, didChangeContainerFrom oldContainer: UIView?, to newContainer: UIView?) {}
}
