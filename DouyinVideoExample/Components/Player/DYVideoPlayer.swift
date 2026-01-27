import UIKit
import AVFoundation
import SnapKit

/// 基于 AVPlayer 封装的短视频播放器组件
/// 负责：
/// 1. 管理 AVPlayer / AVPlayerItem / AVPlayerLayer 生命周期
/// 2. 暴露统一的播放控制接口（播放、暂停、停止、seek、倍速等）
/// 3. 维护播放器状态机，并通过 delegate 将状态、进度等回调给上层
/// 4. 支持在不同承载视图之间无缝迁移（如列表 cell 与全屏页面）
public class DYVideoPlayer: NSObject, DYVideoAdvancedControlInput {
    
    // MARK: - Public Properties
    
    /// 播放器回调代理
    /// 用于接收状态变化、进度、缓冲、错误等事件
    public weak var delegate: DYVideoPlayerDelegate?
    
    /// 播放器当前状态（只读）
    /// 所有状态变更必须通过内部 updateState 方法触发
    public private(set) var state: DYPlayerState = .idle
    
    /// 当前绑定的承载视图（只读，弱引用）
    /// 通过 play(url:in:) 或 updateContainer(_:) 更新
    public private(set) weak var containerView: UIView?
    
    /// 当前正在播放的视频 URL (play 调用时传入)
    public private(set) var currentURL: URL?
    
    /// 当前播放的原始视频地址（用于缓存失败时降级重试）
    public var originalURL: URL? { return originalURLForRetry }
    private var originalURLForRetry: URL?
    
    /// 当前播放的代理视频地址（由缓存代理生成）
    private var proxyURLForRetry: URL?
    
    /// 是否已经从代理 URL 降级为原始 URL 进行过一次重试
    private var hasRetriedWithOriginalURL: Bool = false
    
    /// 是否静音
    public var isMuted: Bool = false {
        didSet {
            assertMainThread()
            player?.isMuted = isMuted
        }
    }
    
    /// 是否循环播放，默认 true，适合抖音风格短视频
    public var isLooping: Bool = true // 默认开启循环播放，符合抖音风格
    
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
    
    public var duration: Double {
        return playerItem?.duration.seconds ?? 0
    }
    
    public var currentTime: Double {
        return player?.currentTime().seconds ?? 0
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
    
    // MARK: - Initialization
    
    public override init() {
        super.init()
        setupAudioSession()
    }
    
    deinit {
        cleanupPlayerResources(resetState: false)
        print("DYVideoPlayer deinit")
    }
    
    // MARK: - Public Methods
    
    public func playWithCache(originalURL: URL, proxyURL: URL, in view: UIView, seekTo: TimeInterval? = nil) {
        assertMainThread()
        originalURLForRetry = originalURL
        proxyURLForRetry = proxyURL
        hasRetriedWithOriginalURL = false
        play(url: proxyURL, in: view, seekTo: seekTo)
    }
    
    public func play(url: URL, in view: UIView, seekTo: TimeInterval? = nil) {
        assertMainThread()
        let previousContainer = containerView
        stop()
        self.currentURL = url
        self.pendingSeekTime = seekTo
        
        DispatchQueue.main.async {
            view.layoutIfNeeded()
            self.playerView.removeFromSuperview()
            view.addSubview(self.playerView)
            self.playerView.snp.remakeConstraints { make in
                make.edges.equalToSuperview()
            }
            self.playerView.isHidden = true
            self.updateState(.preparing)
            self.containerView = view
            if previousContainer !== view {
                self.delegate?.player(self, didChangeContainerFrom: previousContainer, to: view)
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVURLAsset(url: url)
            let keys = ["playable"]
            asset.loadValuesAsynchronously(forKeys: keys) { [weak self] in
                guard let self = self else { return }
                var error: NSError?
                let status = asset.statusOfValue(forKey: "playable", error: &error)
                if status == .loaded && asset.isPlayable {
                    let initialItem = AVPlayerItem(asset: asset)
                    DispatchQueue.main.async {
                        if self.isLooping {
                            let queuePlayer = AVQueuePlayer(playerItem: initialItem)
                            self.playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: initialItem)
                            self.player = queuePlayer
                        } else {
                            self.player = AVPlayer(playerItem: initialItem)
                        }
                        self.playerItem = initialItem
                        guard let player = self.player else { return }
                        player.isMuted = self.isMuted
                        player.volume = self.volume
                        if #available(iOS 10.0, *) {
                            player.automaticallyWaitsToMinimizeStalling = false
                        }
                        self.playerView.player = player
                        self.addPlayerObservers()
                    }
                } else {
                    DispatchQueue.main.async {
                        let message = error?.localizedDescription ?? "Asset not playable"
                        self.updateState(.error(message))
                        self.delegate?.player(self, didFailWithError: error)
                    }
                }
            }
        }
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
        
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        
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
            delegate?.player(self, didChangeContainerFrom: previousContainer, to: view)
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

    public func updatePlayerFrame(_ frame: CGRect) {
        assertMainThread()
        // 使用 PlayerView + SnapKit 后，通常不再手动设置 frame
        // 如果确实需要更新 frame，建议更新约束
        // 这里为了兼容接口，如果 playerView 没有使用约束（autoresizing），可以直接设置 frame
        // 但我们在 play 中使用了 SnapKit，所以这里应该更新约束
        // 暂时假设外部不再调用此方法，或者此方法意图是更新约束的 offset/size
        // 鉴于 SnapKit edges.equalToSuperview 的特性，此方法可能已废弃
        playerView.frame = frame
    }
    
    // MARK: - Private Methods
    
    /// 断言当前在主线程调用（仅在 Debug 下生效）
    /// 用于约束外部所有公开 API 必须在主线程使用
    private func assertMainThread() {
        assert(Thread.isMainThread, "DYVideoPlayer public APIs must be called on main thread")
    }
    
    /// 更新播放器状态，并在状态变化时通过 delegate 通知外部
    /// - Parameter newState: 新的状态
    private func updateState(_ newState: DYPlayerState) {
        let work = { [weak self] in
            guard let self = self else { return }
            guard self.state != newState else { return }
            self.state = newState
            self.delegate?.player(self, didChangeState: newState)
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
        // playerItem = nil 会触发 didSet 移除 Item 的监听
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
        originalURLForRetry = nil
        proxyURLForRetry = nil
        hasRetriedWithOriginalURL = false
        if resetState {
            updateState(.idle)
        }
    }
    
    /// 配置音频会话，保证在静音模式下也能播放
    private func setupAudioSession() {
        // 允许在静音模式下播放声音
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AudioSession setup failed: \(error)")
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
        currentItemObserver = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            guard let self = self else { return }
            // 更新 playerItem 属性，这会触发 didSet 并自动重新绑定 Item 级别的 Observer
            self.playerItem = player.currentItem
        }
        
        // 2. 监听 timeControlStatus (播放/暂停/卡顿) - iOS 10+
        if #available(iOS 10.0, *) {
            timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                self?.handleTimeControlStatus(player.timeControlStatus)
            }
        }
        
        // 3. 监听播放进度 (每0.1秒回调一次)
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.handleTimeUpdate(time)
        }
    }
    
    /// 为具体的 PlayerItem 添加监听 (status, loadedTimeRanges, DidPlayToEndTime)
    private func addPlayerItemObservers(for item: AVPlayerItem?) {
        guard let item = item else { return }
        
        // 1. 监听 status (准备状态)
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            self?.handleStatusChange(item.status)
        }
        
        // 2. 监听 loadedTimeRanges (缓冲进度)
        bufferObserver = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            self?.handleBufferUpdate(item)
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
            // 准备好播放了
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
                player?.play()
                player?.rate = playbackRate
                playerView.isHidden = false
            }
            
            // 获取视频尺寸 - 异步加载 tracks 防止阻塞主线程
            // Fix: Main thread blocked by synchronous property query on not-yet-loaded property (NaturalSize)
            let asset = playerItem?.asset
            let keys = ["tracks"]
            asset?.loadValuesAsynchronously(forKeys: keys) { [weak self] in
                guard let self = self, let asset = asset else { return }
                
                var error: NSError? = nil
                let status = asset.statusOfValue(forKey: "tracks", error: &error)
                
                if status == .loaded {
                    // Force processing to background if not already
                    DispatchQueue.global(qos: .userInitiated).async {
                        if let track = asset.tracks(withMediaType: .video).first {
                            // These properties can still block if not fully ready, so we access them in background
                            let size = track.naturalSize.applying(track.preferredTransform)
                            let videoSize = CGSize(width: abs(size.width), height: abs(size.height))
                            DispatchQueue.main.async {
                                self.delegate?.player(self, didUpdateVideoSize: videoSize)
                            }
                        }
                    }
                } else {
                    print("Failed to load tracks: \(String(describing: error))")
                }
            }
            
        case .failed:
            let errorMsg = playerItem?.error?.localizedDescription ?? "Unknown error"
            if let originalURL = originalURLForRetry,
               hasRetriedWithOriginalURL == false {
                hasRetriedWithOriginalURL = true
                let currentTime = self.currentTime
                let targetContainer = self.containerView
                DispatchQueue.main.async {
                    VideoCacheManager.shared.addToBlacklist(url: originalURL)
                    if let container = targetContainer {
                        self.play(url: originalURL, in: container, seekTo: currentTime)
                    } else {
                        self.updateState(.error(errorMsg))
                        self.delegate?.player(self, didFailWithError: self.playerItem?.error)
                    }
                }
            } else {
                updateState(.error(errorMsg))
                DispatchQueue.main.async {
                    self.delegate?.player(self, didFailWithError: self.playerItem?.error)
                }
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
            // 只有不是播放完成状态时，才切换为 paused
            if state != .finished && state != .idle {
                updateState(.paused)
            }
        case .waitingToPlayAtSpecifiedRate:
            // 缓冲中
            if state != .idle && state != .preparing {
                updateState(.buffering)
            }
        case .playing:
            updateState(.playing)
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
        
        if totalDuration > 0 {
            let progress = bufferTime / totalDuration
            DispatchQueue.main.async {
                self.delegate?.player(self, didUpdateBuffer: progress)
            }
        }
    }
    
    /// 处理播放进度更新
    /// - Parameter time: 当前播放时间（CMTime）
    private func handleTimeUpdate(_ time: CMTime) {
        guard let item = playerItem else { return }
        let current = time.seconds
        let total = item.duration.seconds
        
        if total > 0 {
            let progress = current / total
            self.delegate?.player(self, didUpdateProgress: progress, currentTime: current, totalTime: total)
        }
    }
    
    /// 播放完成回调（由通知触发）
    /// 负责更新状态、回调 delegate
    @objc private func playerDidFinishPlaying(_ notification: Notification) {
        // 如果使用了 Looper，它会自动循环，不需要手动 Seek
        // 但我们仍然需要处理逻辑：比如在循环模式下不一定非要发送 finished 状态，或者只通知一次
        // 这里我们简单处理：如果是 Loop 模式，Looper 会自动重播，我们仅通知播放完成，不改变 state 为 finished (避免 UI 显示重播按钮)
        // 除非 isLooping 为 false
        
        if isLooping {
             // Looper 模式下，单次播放结束
             // 可以在这里做播放次数统计等
             // 注意：AVPlayerLooper 可能会预加载下一个 Item，导致通知时机可能略有不同，但通常是准确的
             DispatchQueue.main.async {
                 self.delegate?.playerDidFinishPlaying(self)
             }
        } else {
            // 非 Looper 模式，正常结束
            updateState(.finished)
            DispatchQueue.main.async {
                self.delegate?.playerDidFinishPlaying(self)
            }
        }
    }
}
