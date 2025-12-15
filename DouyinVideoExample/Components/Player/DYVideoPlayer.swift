import UIKit
import AVFoundation

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
    
    /// 当前播放的原始视频地址（用于缓存失败时降级重试）
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
    
    private var player: AVPlayer?
    
    private var playerItem: AVPlayerItem?
    
    private var playerLayer: AVPlayerLayer?
    
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
        self.pendingSeekTime = seekTo
        var playerItem: AVPlayerItem
        playerItem = AVPlayerItem(url: url)
        self.playerItem = playerItem
        let player = AVPlayer(playerItem: playerItem)
        player.isMuted = isMuted
        player.volume = volume


        if #available(iOS 10.0, *) {
            player.automaticallyWaitsToMinimizeStalling = false
        }
        self.player = player

        DispatchQueue.main.async {
            view.layoutIfNeeded()

            if let existingLayer = self.playerLayer, existingLayer.superlayer == view.layer {
                existingLayer.removeFromSuperlayer()
            }

            let layer = AVPlayerLayer(player: player)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = view.bounds
            CATransaction.commit()
            layer.videoGravity = self.avGravity(from: self.videoGravity)
            layer.isHidden = true

            view.layer.sublayers?.forEach { sublayer in
                if sublayer is AVPlayerLayer && sublayer != layer {
                    sublayer.removeFromSuperlayer()
                }
            }

            view.layer.addSublayer(layer)
            self.playerLayer = layer
            
            self.addObservers()
            self.updateState(.preparing)
            self.containerView = view
            if previousContainer !== view {
                self.delegate?.player(self, didChangeContainerFrom: previousContainer, to: view)
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
    
    public func seek(to time: TimeInterval, completion: ((Bool) -> Void)? = nil) {
        assertMainThread()
        guard let player = player else {
            completion?(false)
            return
        }
        
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            completion?(finished)
        }
    }
    
    /// 更新播放器承载视图 (用于全屏切换)
    /// 会将当前 AVPlayerLayer 从旧 view 移动到新的 view 上
    /// 并通过 delegate 通知 container 变更
    public func updateContainer(_ view: UIView) {
        assertMainThread()
        let previousContainer = containerView
        guard let layer = playerLayer else {
            print("Warning: playerLayer is nil, cannot update container")
            return
        }
        
        // 确保 view 的布局已更新
        view.layoutIfNeeded()
        
        // 如果 layer 已经在目标容器中，只需要更新 frame 和 gravity
        if layer.superlayer == view.layer {
            // 已经在目标容器中，更新 frame 和确保 gravity 正确
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = view.bounds
            layer.videoGravity = avGravity(from: videoGravity)
            CATransaction.commit()
            layer.isHidden = false
            print("Player container frame updated, new frame: \(view.bounds), gravity: \(videoGravity)")
            return
        }
        
        // 移除旧的 layer
        layer.removeFromSuperlayer()
        
        // 添加到新容器
        view.layer.addSublayer(layer)
        
        // 更新 frame 和 gravity（使用 CATransaction 避免动画）
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = view.bounds
        layer.videoGravity = avGravity(from: videoGravity)
        CATransaction.commit()
        
        // 确保 layer 可见
        layer.isHidden = false
        
        // 确保 layer 在最上层（避免被其他视图遮挡）
        if let sublayers = view.layer.sublayers {
            view.layer.insertSublayer(layer, at: UInt32(sublayers.count))
        }
        
        print("Player container updated, new frame: \(view.bounds), gravity: \(videoGravity)")
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
        removeObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerLayer?.removeFromSuperlayer()
        player = nil
        playerItem = nil
        playerLayer = nil
        containerView = nil
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
        guard let layer = playerLayer else { return }
        layer.videoGravity = avGravity(from: videoGravity)
        // 确保在更新 gravity 后，frame 也是正确的
        if let superlayer = layer.superlayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = superlayer.bounds
            CATransaction.commit()
        }
    }
    
    /// 为当前 player / item 添加 KVO、进度和结束通知监听
    private func addObservers() {
        guard let player = player, let item = playerItem else { return }
        
        // 1. 监听 status (准备状态)
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            self?.handleStatusChange(item.status)
        }
        
        // 2. 监听 loadedTimeRanges (缓冲进度)
        bufferObserver = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            self?.handleBufferUpdate(item)
        }
        
        // 3. 监听 timeControlStatus (播放/暂停/卡顿) - iOS 10+
        if #available(iOS 10.0, *) {
            timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                self?.handleTimeControlStatus(player.timeControlStatus)
            }
        }
        
        // 4. 监听播放进度 (每0.1秒回调一次)
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.handleTimeUpdate(time)
        }
        
        // 5. 监听播放结束通知
        NotificationCenter.default.addObserver(self, selector: #selector(playerDidFinishPlaying), name: .AVPlayerItemDidPlayToEndTime, object: item)
    }
    
    /// 移除所有已添加的观察者与通知监听
    private func removeObservers() {
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        
        statusObserver?.invalidate()
        statusObserver = nil
        
        bufferObserver?.invalidate()
        bufferObserver = nil
        
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        
        NotificationCenter.default.removeObserver(self)
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
                    self.playerLayer?.isHidden = false
                }
            } else {
                player?.play()
                player?.rate = playbackRate
                playerLayer?.isHidden = false
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
    /// 负责更新状态、回调 delegate，并在 isLooping 开启时自动循环播放
    @objc private func playerDidFinishPlaying() {
        updateState(.finished)
        DispatchQueue.main.async {
            self.delegate?.playerDidFinishPlaying(self)
        }
        
        // 循环播放逻辑
        if isLooping {
            seek(to: 0) { [weak self] finished in
                if finished {
                    self?.player?.play()
                }
            }
        }
    }
}
