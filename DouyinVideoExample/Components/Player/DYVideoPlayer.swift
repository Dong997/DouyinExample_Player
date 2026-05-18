import UIKit
import AVFoundation
import SnapKit
import os.log

/// 基于 AVPlayer 封装的短视频播放器组件
/// 负责：
/// 1. 管理 AVPlayer / AVPlayerItem / AVPlayerLayer 生命周期
/// 2. 暴露统一的播放控制接口（播放、暂停、停止、seek、倍速等）
/// 3. 维护播放器状态机，并通过 delegate 将状态、进度等回调给上层
/// 4. 支持在不同承载视图之间无缝迁移（如列表 cell 与全屏页面）
public class DYVideoPlayer: NSObject, DYVideoAdvancedControlInput {
    
    // MARK: - Public Properties
    
    /// 播放器回调代理（向后兼容，设置时自动同步到 multicastDelegate）
    /// 新代码建议直接使用 multicastDelegate.add() 订阅
    public weak var delegate: DYVideoPlayerDelegate? {
        didSet {
            if let delegate = delegate {
                multicastDelegate.add(delegate)
            }
        }
    }

    /// 多播委托中心，允许多个订阅者同时接收播放器事件
    /// 订阅者以弱引用持有，不会造成循环引用
    public let multicastDelegate = DYVideoPlayerMulticastDelegate()
    
    /// 播放器当前状态（只读）
    /// 所有状态变更必须通过内部 updateState 方法触发
    public private(set) var state: DYPlayerState = .idle
    
    /// 当前绑定的承载视图（只读，弱引用）
    /// 通过 play(url:in:) 或 updateContainer(_:) 更新
    public private(set) weak var containerView: UIView?
    
    /// 当前正在播放的视频 URL (play 调用时传入)
    public private(set) var currentURL: URL?
    
    /// 当前播放的原始视频地址（可选，仅作记录，用于外部比对）
    public private(set) var originalURL: URL?
    
    /// 判断当前播放器是否正在播放指定 URL 的视频
    /// 优先匹配 originalURL（缓存代理场景），其次匹配 currentURL
    public func isPlaying(url: URL) -> Bool {
        if let originalURL = originalURL {
            return originalURL == url
        } else if let currentURL = currentURL {
            return currentURL == url
        }
        return false
    }
    
    /// 播放器是否已预加载就绪（首帧已渲染、暂停中、等待 attach 到容器视图）
    /// 用于 PlayerCoordinator 判断是否可以执行无缝切换
    public var isPreloadedAndReady: Bool {
        return currentURL != nil
            && player != nil
            && state == .paused
            && containerView == nil
            && playerItem?.status == .readyToPlay
    }

    /// 当前播放器是否已有可显示的视频画面，用于列表切换时避免封面层重新盖上造成闪烁。
    public var isReadyForDisplay: Bool {
        return player != nil && playerItem?.status == .readyToPlay
    }
    
    /// 是否静音
    public var isMuted: Bool = false {
        didSet {
            assertMainThread()
            player?.isMuted = isMuted
        }
    }
    
    /// 是否循环播放，默认 true，适合抖音风格短视频
    public var isLooping: Bool = true // 默认开启循环播放，符合抖音风格
    
    /// 前向缓冲时长占视频总时长的比例（0~1）。在 `AVPlayerItem` 就绪且能读到有效 `duration` 时映射为 `preferredForwardBufferDuration`；`nil` 表示使用系统默认策略。
    public var preferredForwardBufferFraction: Double?
    
    /// 播放音量（0.0 ~ 1.0）
    public var volume: Float = 1.0 {
        didSet {
            assertMainThread()
            player?.volume = volume
        }
    }
    
    public var playbackRate: Float = 1.0 {
        didSet {
            assertMainThread()
            if let player = player {
                if state == .playing {
                    player.rate = playbackRate
                }
            }
        }
    }
    public var videoGravity: DYVideoGravity = .aspectFit {
        didSet {
            assertMainThread()
            updatePlayerLayerGravity()
        }
    }

    /// 当前播放器配置。设置该属性会立即应用到播放器实例。
    public var configuration: DYVideoPlayerConfiguration {
        get {
            DYVideoPlayerConfiguration(
                playbackRate: playbackRate,
                videoGravity: videoGravity,
                isMuted: isMuted,
                volume: volume,
                isLooping: isLooping,
                preferredForwardBufferFraction: preferredForwardBufferFraction
            )
        }
        set {
            applyConfiguration(newValue)
        }
    }
    
    public var duration: Double {
        return sanitizedSeconds(playerItem?.duration.seconds)
    }
    
    public var currentTime: Double {
        return sanitizedSeconds(player?.currentTime().seconds)
    }
    
    // MARK: - Private Properties
    
    /// 承载 AVPlayer 的视图 (封装了 AVPlayerLayer)
    private lazy var playerView: DYPlayerView = {
        let view = DYPlayerView()
        view.videoGravity = avGravity(from: videoGravity)
        return view
    }()
    
    private var player: AVPlayer?
    
    /// 用于无缝循环播放的 Looper
    private var playerLooper: AVPlayerLooper?
    
    private var playerItem: AVPlayerItem? {
        didSet {
            // 当 playerItem 变化时，重新绑定监听
            if oldValue !== playerItem {
                removePlayerItemObservers(for: oldValue)
                addPlayerItemObservers(for: playerItem)
            }
        }
    }
    
    private var pendingSeekTime: TimeInterval?
    
    // Observers
    /// 播放进度观察者句柄
    private var timeObserver: Any?
    /// 播放项状态 KVO
    private var statusObserver: NSKeyValueObservation?
    /// 缓冲进度 KVO
    private var bufferObserver: NSKeyValueObservation?
    /// 播放控制状态 KVO（iOS 10+）
    private var timeControlStatusObserver: NSKeyValueObservation?
    /// 当前播放项 KVO (用于 Looper 切换 Item 时更新)
    private var currentItemObserver: NSKeyValueObservation?
    
    /// 首帧渲染标记：prepare 模式下 play→pause 渲染首帧时为 true，
    /// 期间抑制状态回调避免外部误判为正在播放
    private var isRenderingFirstFrame: Bool = false
    
    /// 首帧渲染前的原始静音状态，渲染完成后恢复
    private var wasMutedBeforeFirstFrame: Bool = false

    /// 准备阶段兜底超时，用于暴露 AVAsset/AVPlayerItem 长时间无状态回调的问题
    private var preparationTimeoutWorkItem: DispatchWorkItem?

    /// 正常播放态的进度回调间隔；拖拽进度条时由手势事件即时更新，不依赖此周期 observer。
    private let progressUpdateInterval: TimeInterval = 0.25
    
    // MARK: - Initialization
    
    public override init() {
        super.init()
    }
    
    deinit {
        cleanupPlayerResources(resetState: false)
        AppLog.player.debug("DYVideoPlayer deinit")
    }
    
    // MARK: - Public Methods
    
    /// 预加载视频资源但不自动播放
    /// - Parameters:
    ///   - url: 视频 URL
    ///   - originalURL: 原始 URL
    public func prepare(url: URL, originalURL: URL? = nil) {
        assertMainThread()
        if currentURL == url { return }

        cleanupPlayerResources(resetState: true)

        self.currentURL = url
        self.originalURL = originalURL
        self.updateState(.preparing)

        loadAssetAndCreatePlayer(url: url, autoPlay: false)
    }
    
    /// 重置播放器状态以便复用
    public func reset() {
        assertMainThread()
        preferredForwardBufferFraction = nil
        cleanupPlayerResources(resetState: true)
        containerView = nil
        delegate = nil
        multicastDelegate.removeAll()
        playerView.isHidden = true
    }

    public func play(url: URL, originalURL: URL? = nil, in view: UIView, seekTo: TimeInterval? = nil) {
        assertMainThread()

        if currentURL == url, player != nil {
            updateContainer(view)

            if let time = seekTo {
                seek(to: time) { [weak self] _ in
                    self?.resume()
                }
            } else {
                resume()
            }

            playerView.isHidden = false
            return
        }

        let previousContainer = containerView
        stop()
        self.currentURL = url
        self.originalURL = originalURL
        self.pendingSeekTime = seekTo

        view.layoutIfNeeded()
        playerView.removeFromSuperview()
        playerView.player = nil
        playerView.playerLayer.contents = nil
        view.addSubview(playerView)
        playerView.snp.remakeConstraints { make in
            make.edges.equalToSuperview()
        }
        playerView.isHidden = false
        updateState(.preparing)
        containerView = view
        if previousContainer !== view {
            multicastDelegate.player(self, didChangeContainerFrom: previousContainer, to: view)
        }

        loadAssetAndCreatePlayer(url: url, autoPlay: true)
    }
    
    /// 恢复播放
    /// 如果当前状态是 finished，会从头开始播放
    public func resume() {
        assertMainThread()
        if state == .finished {
            seek(to: 0) { [weak self] _ in
                if let player = self?.player {
                    player.play()
                    player.rate = self?.playbackRate ?? 1.0
                }
            }
        } else {
            if let player = player {
                player.play()
                player.rate = playbackRate
            }
        }
    }
    
    /// 暂停播放（保留当前进度）
    public func pause() {
        assertMainThread()
        player?.pause()
        updateState(.paused)
    }
    
    /// 停止播放并释放当前播放器资源
    /// 会重置状态为 idle，移除 layer 和观察者
    public func stop() {
        assertMainThread()
        cleanupPlayerResources(resetState: true)
    }
    
    /// 跳转到指定时间
    /// - Parameters:
    ///   - time: 目标时间 (秒)
    ///   - isPrecise: 是否精确跳转。
    ///     - true: 精确跳转 (tolerance = zero)，适用于用户停止拖拽后的最终定位。
    ///     - false: 快速跳转 (tolerance = infinity)，适用于用户正在拖拽进度条时的实时预览，性能更好。
    ///   - completion: 完成回调
    public func seek(to time: TimeInterval, isPrecise: Bool = true, completion: ((Bool) -> Void)? = nil) {
        assertMainThread()
        guard let player = player else {
            completion?(false)
            return
        }
        
        let targetTime = normalizedSeekTime(time)
        let cmTime = CMTime(seconds: targetTime, preferredTimescale: 600)
        
        if isPrecise {
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                completion?(finished)
            }
        } else {
            // 使用 positiveInfinity 允许播放器跳转到最近的关键帧，极大提升拖拽流畅度
            player.seek(to: cmTime, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity) { finished in
                completion?(finished)
            }
        }
    }
    
    /// 更新播放器承载视图 (用于全屏切换)
    /// 会将当前 PlayerView 从旧 view 移动到新的 view 上
    /// 并通过 delegate 通知 container 变更
    public func updateContainer(_ view: UIView) {
        assertMainThread()
        let previousContainer = containerView
        
        // 确保 view 的布局已更新
        view.layoutIfNeeded()
        
        // 如果 playerView 已经在目标容器中
        if playerView.superview == view {
            // 更新约束（虽然 SnapKit 的 edges.equalToSuperview 通常自动适应，但重新 ensure 一下也没错）
            playerView.snp.remakeConstraints { make in
                make.edges.equalToSuperview()
            }
            playerView.videoGravity = avGravity(from: videoGravity)
            playerView.isHidden = false
            return
        }
        
        // 移动到新容器
        playerView.removeFromSuperview()
        view.addSubview(playerView)
        
        // 重置约束
        playerView.snp.remakeConstraints { make in
            make.edges.equalToSuperview()
        }
        playerView.videoGravity = avGravity(from: videoGravity)
        
        // 确保可见
        playerView.isHidden = false
        
        // 确保在最下层（背景）或根据需要调整层级
        view.sendSubviewToBack(playerView)
        
        containerView = view
        if previousContainer !== view {
            multicastDelegate.player(self, didChangeContainerFrom: previousContainer, to: view)
        }
    }
    
    /// 设置播放速度（0.5x ~ 3.0x）
    /// 如果当前未播放，会直接以指定倍速开始播放
    public func setPlaybackRate(_ rate: Float) {
        assertMainThread()
        playbackRate = max(0.5, min(rate, 3.0))
        guard let player = player else { return }
        if state == .playing {
            player.rate = playbackRate
        } else {
            player.playImmediately(atRate: playbackRate)
            updateState(.playing)
        }
    }
    
    /// 设置视频画面填充模式
    public func setVideoGravity(_ gravity: DYVideoGravity) {
        assertMainThread()
        videoGravity = gravity
    }

    /// 应用播放器配置。
    /// 对正在播放的播放器，倍速、静音、音量和填充模式会立即生效；循环策略会在下一次创建播放项时生效。
    public func applyConfiguration(_ configuration: DYVideoPlayerConfiguration) {
        assertMainThread()
        let normalized = configuration.normalized()
        playbackRate = normalized.playbackRate
        videoGravity = normalized.videoGravity
        isMuted = normalized.isMuted
        volume = normalized.volume
        isLooping = normalized.isLooping
        preferredForwardBufferFraction = normalized.preferredForwardBufferFraction
        if let item = playerItem {
            applyPreferredForwardBufferIfNeeded(for: item)
        }
    }

    // MARK: - Private Methods

    /// 异步加载 AVAsset 并创建 AVPlayer/AVPlayerItem
    /// 统一 `play` 和 `prepare` 的资源创建逻辑，消除重复代码
    /// - Parameters:
    ///   - url: 视频 URL
    ///   - autoPlay: true 表示播放模式（play 调用），false 表示预加载模式（prepare 调用，初始暂停）
    private func loadAssetAndCreatePlayer(url: URL, autoPlay: Bool) {
        let requestID = UUID().uuidString

        let asset = AVURLAsset(url: url)
        let initialItem = AVPlayerItem(asset: asset)

        if isLooping {
            let queuePlayer = AVQueuePlayer()
            playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: initialItem)
            player = queuePlayer
            playerItem = queuePlayer.currentItem ?? initialItem
        } else {
            player = AVPlayer(playerItem: initialItem)
            playerItem = initialItem
        }

        guard let player = player else { return }
        player.isMuted = isMuted
        player.volume = volume
        if #available(iOS 10.0, *) {
            player.automaticallyWaitsToMinimizeStalling = false
        }
        if !autoPlay {
            player.pause()
        }
        playerView.player = player
        addPlayerObservers()
        schedulePreparationTimeout(for: url, requestID: requestID)

        asset.loadValuesAsynchronously(forKeys: ["tracks"]) { [weak self] in
            var error: NSError?
            let tracksStatus = asset.statusOfValue(forKey: "tracks", error: &error)
            guard tracksStatus == .loaded,
                  let track = asset.tracks(withMediaType: .video).first else {
                let message = error?.localizedDescription ?? "tracks not loaded"
                AppLog.player.warning("DYVideoPlayer tracks load skipped id=\(requestID), status=\(tracksStatus.rawValue), error=\(message)")
                DispatchQueue.main.async {
                    guard let self = self, self.currentURL == url, self.state == .preparing else { return }
                    self.preparationTimeoutWorkItem?.cancel()
                    self.preparationTimeoutWorkItem = nil
                    self.updateState(.error(message))
                    self.multicastDelegate.player(self, didFailWithError: error)
                }
                return
            }

            let size = track.naturalSize.applying(track.preferredTransform)
            let videoSize = CGSize(width: abs(size.width), height: abs(size.height))
            DispatchQueue.main.async {
                guard let self = self, self.currentURL == url else { return }
                self.multicastDelegate.player(self, didUpdateVideoSize: videoSize)
            }
        }
    }

    private func schedulePreparationTimeout(for url: URL, requestID: String) {
        preparationTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.currentURL == url,
                  self.state == .preparing else { return }
            let itemStatus = self.playerItem?.status.rawValue ?? -1
            let playerStatus: Int
            if #available(iOS 10.0, *) {
                playerStatus = self.player?.timeControlStatus.rawValue ?? -1
            } else {
                playerStatus = -1
            }
            AppLog.player.error("DYVideoPlayer preparation timeout id=\(requestID), url=\(url.absoluteString), itemStatus=\(itemStatus), timeControlStatus=\(playerStatus), error=\(String(describing: self.playerItem?.error?.localizedDescription))")
            self.updateState(.error("Playback preparation timed out"))
        }
        preparationTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: workItem)
    }

    /// 断言当前在主线程调用
    /// 仅在 Debug 构建中检查，Release 中优雅降级为日志警告
    private func assertMainThread() {
        assert(Thread.isMainThread, "Player method must be called on main thread")
        if !Thread.isMainThread {
            AppLog.player.warning("Player method called off main thread — this may cause UI issues")
        }
    }
    
    private func applyPreferredForwardBufferIfNeeded(for item: AVPlayerItem) {
        guard let fraction = preferredForwardBufferFraction else {
            item.preferredForwardBufferDuration = 0
            return
        }
        let total = item.duration.seconds
        guard total.isFinite, total > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        item.preferredForwardBufferDuration = max(1, total * clamped)
    }

    private func sanitizedSeconds(_ seconds: Double?) -> Double {
        guard let seconds = seconds, seconds.isFinite, seconds > 0 else { return 0 }
        return seconds
    }

    private func normalizedSeekTime(_ time: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return 0 }
        let nonNegativeTime = max(0, time)
        let totalDuration = duration
        guard totalDuration > 0 else { return nonNegativeTime }
        return min(nonNegativeTime, totalDuration)
    }
    
    /// 更新播放器状态，并在状态变化时通过 delegate 通知外部
    /// - Parameter newState: 新的状态
    private func updateState(_ newState: DYPlayerState) {
        let work = { [weak self] in
            guard let self = self else { return }
            guard self.state != newState else { return }
            self.state = newState
            self.multicastDelegate.player(self, didChangeState: newState)
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
    
    /// 统一清理播放器资源和观察者的内部方法
    /// - Parameter resetState: 是否重置状态为 idle 并触发回调
    private func cleanupPlayerResources(resetState: Bool) {
        // 先移除所有监听
        removePlayerObservers()
        if isRenderingFirstFrame {
            player?.isMuted = wasMutedBeforeFirstFrame
        }
        preparationTimeoutWorkItem?.cancel()
        preparationTimeoutWorkItem = nil
        isRenderingFirstFrame = false
        pendingSeekTime = nil
        playerItem = nil
        
        playerLooper?.disableLooping()
        playerLooper = nil
        
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerView.removeFromSuperview()
        playerView.player = nil
        player = nil
        
        containerView = nil
        currentURL = nil
        originalURL = nil
        if resetState {
            updateState(.idle)
        }
    }
    
    /// 将自定义的 DYVideoGravity 映射为系统 AVLayerVideoGravity
    private func avGravity(from gravity: DYVideoGravity) -> AVLayerVideoGravity {
        switch gravity {
        case .aspectFit: return .resizeAspect
        case .aspectFill: return .resizeAspectFill
        case .resize: return .resize
        }
    }
    
    /// 根据当前 videoGravity 更新 playerLayer 的填充模式和 frame
    private func updatePlayerLayerGravity() {
        playerView.videoGravity = avGravity(from: videoGravity)
    }
    
    /// 为 Player 添加监听（currentItem, timeControlStatus, periodicTime）
    private func addPlayerObservers() {
        guard let player = player else { return }
        
        // 1. 监听 currentItem 变化 (处理 Looper 切换 Item)
        currentItemObserver = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            let currentItem = player.currentItem
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.player === player else { return }
                // 更新 playerItem 属性，这会触发 didSet 并自动重新绑定 Item 级别的 Observer
                self.playerItem = currentItem
            }
        }
        
        // 2. 监听 timeControlStatus (播放/暂停/卡顿) - iOS 10+
        if #available(iOS 10.0, *) {
            timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let status = player.timeControlStatus
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.player === player else { return }
                    self.handleTimeControlStatus(status)
                }
            }
            // 防御性检查：如果 timeControlStatus 在添加观察者前已变更（缓存命中快速就绪场景）
            if player.timeControlStatus == .playing {
                handleTimeControlStatus(.playing)
            }
        }
        
        // 3. 监听播放进度，避免高频回调持续压主线程。
        let interval = CMTime(seconds: progressUpdateInterval, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.handleTimeUpdate(time)
        }
    }
    
    /// 为具体的 PlayerItem 添加监听 (status, loadedTimeRanges, DidPlayToEndTime)
    /// 添加观察者后立即检查 status 是否已就绪：
    /// 当 AVPlayerItem 通过 KTVHTTPCache 代理加载时，asset 数据已在本地，
    /// item.status 可能在 addPlayerItemObservers 调用前就已变为 .readyToPlay，
    /// 此时 KVO (.new) 不会触发，导致 handleStatusChange 永远不被调用、播放器无法自动播放
    private func addPlayerItemObservers(for item: AVPlayerItem?) {
        guard let item = item else { return }
        
        // 1. 监听 status (准备状态)
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.playerItem === item else { return }
                self.handleStatusChange(status)
            }
        }
        
        // 2. 监听 loadedTimeRanges (缓冲进度)
        bufferObserver = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.playerItem === item else { return }
                self.handleBufferUpdate(item)
            }
        }
        
        // 3. 监听播放结束通知
        NotificationCenter.default.addObserver(self, selector: #selector(playerDidFinishPlaying(_:)), name: .AVPlayerItemDidPlayToEndTime, object: item)
    }
    
    /// 移除 Player 级别的监听
    private func removePlayerObservers() {
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        
        currentItemObserver?.invalidate()
        currentItemObserver = nil
        
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
    }
    
    /// 移除 PlayerItem 级别的监听
    private func removePlayerItemObservers(for item: AVPlayerItem?) {
        statusObserver?.invalidate()
        statusObserver = nil
        
        bufferObserver?.invalidate()
        bufferObserver = nil
        
        if let item = item {
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: item)
        }
    }
    
    // MARK: - Event Handlers
    
    /// 处理 AVPlayerItem.status 变化
    /// - Parameter status: 最新的播放项状态
    private func handleStatusChange(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            preparationTimeoutWorkItem?.cancel()
            preparationTimeoutWorkItem = nil
            // 准备好播放了
            if let item = playerItem {
                applyPreferredForwardBufferIfNeeded(for: item)
            }
            
            // 只有当不是在“仅预加载”模式（即 containerView != nil 或明确要求播放）时，才触发自动播放逻辑
            // 如果是 prepare() 触发的 readyToPlay，且此时还没有 attach 到 view，我们只做状态标记，不调 play()
            
            // 无论如何，先确保 playerLayer 已经关联了 player（在 prepare 中已做，这里再次确认无害）
            
            if containerView != nil {
                if let seekTime = pendingSeekTime {
                    let target = seekTime
                    pendingSeekTime = nil
                    seek(to: target) { [weak self] _ in
                        guard let self = self else { return }
                        self.player?.play()
                        self.player?.rate = self.playbackRate
                        self.playerView.isHidden = false
                    }
                } else {
                    // 如果处于暂停状态且不是预加载（有 container），则恢复播放
                    if state != .paused {
                         player?.play()
                         player?.rate = playbackRate
                    }
                    playerView.isHidden = false
                }
            } else {
                player?.pause()
                player?.rate = 0
                isRenderingFirstFrame = false
                updateState(.paused)
            }
            
        case .failed:
            preparationTimeoutWorkItem?.cancel()
            preparationTimeoutWorkItem = nil
            if isRenderingFirstFrame {
                player?.isMuted = wasMutedBeforeFirstFrame
            }
            isRenderingFirstFrame = false
            let errorMsg = playerItem?.error?.localizedDescription ?? "Unknown error"
            // 移除内部自动重试逻辑，直接上报错误
            // 重试策略由外部（如 PlaybackRetryHandler）接管
            updateState(.error(errorMsg))
            DispatchQueue.main.async {
                self.multicastDelegate.player(self, didFailWithError: self.playerItem?.error)
            }
            
        case .unknown:
            break
        @unknown default:
            break
        }
    }
    
    /// 处理 AVPlayer.timeControlStatus 变化（播放、暂停、缓冲）
    /// - Parameter status: 播放控制状态
    private func handleTimeControlStatus(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .paused:
            if isRenderingFirstFrame { return }
            if state != .finished && state != .idle {
                updateState(.paused)
            }
        case .waitingToPlayAtSpecifiedRate:
            if isRenderingFirstFrame { return }
            if state != .idle {
                updateState(.buffering)
            }
        case .playing:
            guard containerView != nil else {
                AppLog.player.warning("DYVideoPlayer preload player entered playing without container, force pause")
                player?.pause()
                player?.rate = 0
                player?.isMuted = wasMutedBeforeFirstFrame
                isRenderingFirstFrame = false
                updateState(.paused)
                return
            }
            if isRenderingFirstFrame {
                player?.pause()
                player?.isMuted = wasMutedBeforeFirstFrame
                isRenderingFirstFrame = false
                updateState(.paused)
            } else {
                updateState(.playing)
            }
        @unknown default:
            break
        }
    }
    
    /// 处理缓冲进度更新
    /// - Parameter item: 当前播放项
    private func handleBufferUpdate(_ item: AVPlayerItem) {
        guard let timeRange = item.loadedTimeRanges.first?.timeRangeValue else { return }
        let start = timeRange.start.seconds
        let duration = timeRange.duration.seconds
        let bufferTime = start + duration
        let totalDuration = item.duration.seconds
        
        guard start.isFinite,
              duration.isFinite,
              bufferTime.isFinite,
              totalDuration.isFinite,
              totalDuration > 0 else { return }

        let progress = min(max(bufferTime / totalDuration, 0), 1)
        self.multicastDelegate.player(self, didUpdateBuffer: progress)
    }
    
    /// 处理播放进度更新
    /// - Parameter time: 当前播放时间（CMTime）
    private func handleTimeUpdate(_ time: CMTime) {
        guard let item = playerItem else { return }
        if isRenderingFirstFrame { return }
        let current = time.seconds
        let total = item.duration.seconds
        
        guard current.isFinite, total.isFinite, total > 0 else { return }
        let progress = min(max(current / total, 0), 1)
        self.multicastDelegate.player(self, didUpdateProgress: progress, currentTime: max(0, current), totalTime: total)
    }
    
    /// 播放完成回调（由通知触发）
    /// 负责更新状态、回调 delegate
    @objc private func playerDidFinishPlaying(_ notification: Notification) {
        if !isLooping {
            guard let finishedItem = notification.object as? AVPlayerItem,
                  finishedItem === playerItem else { return }
        }

        // 如果使用了 Looper，它会自动循环，不需要手动 Seek
        // 但我们仍然需要处理逻辑：比如在循环模式下不一定非要发送 finished 状态，或者只通知一次
        // 这里我们简单处理：如果是 Loop 模式，Looper 会自动重播，我们仅通知播放完成，不改变 state 为 finished (避免 UI 显示重播按钮)
        // 除非 isLooping 为 false
        
        if isLooping {
             // Looper 模式下，单次播放结束
             // 可以在这里做播放次数统计等
             // 注意：AVPlayerLooper 可能会预加载下一个 Item，导致通知时机可能略有不同，但通常是准确的
             DispatchQueue.main.async {
                 self.multicastDelegate.playerDidFinishPlaying(self)
             }
        } else {
            // 非 Looper 模式，正常结束
            updateState(.finished)
            DispatchQueue.main.async {
                self.multicastDelegate.playerDidFinishPlaying(self)
            }
        }
    }
}
