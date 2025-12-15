import UIKit
import AVFoundation

/// 基于 AVPlayer 封装的视频播放器组件
public class DYVideoPlayer: NSObject, DYVideoPlayerInput {
    
    // MARK: - Public Properties
    
    public weak var delegate: DYVideoPlayerDelegate?
    
    public var state: DYPlayerState = .idle {
        didSet {
            guard state != oldValue else { return }
            DispatchQueue.main.async {
                self.delegate?.player(self, didChangeState: self.state)
            }
        }
    }
    
    public var isMuted: Bool = false {
        didSet {
            player?.isMuted = isMuted
        }
    }
    
    public var isLooping: Bool = true // 默认开启循环播放，符合抖音风格
    
    public var volume: Float = 1.0 {
        didSet {
            player?.volume = volume
        }
    }
    
    public var playbackRate: Float = 1.0 {
        didSet {
            if let player = player {
                if state == .playing {
                    player.rate = playbackRate
                }
            }
        }
    }
    public enum DYVideoGravity { case aspectFit, aspectFill, resize }
    public var videoGravity: DYVideoGravity = .aspectFit {
        didSet {
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
    private var pendingSeekTime: Double?
    
    // Observers
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var bufferObserver: NSKeyValueObservation?
    private var timeControlStatusObserver: NSKeyValueObservation?
    
    // MARK: - Initialization
    
    public override init() {
        super.init()
        setupAudioSession()
    }
    
    deinit {
        stop()
        print("DYVideoPlayer deinit")
    }
    
    // MARK: - Public Methods
    
    public func play(url: URL, in view: UIView, seekTo: Double? = nil) {
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
            self.state = .preparing
        }
    }
    
    public func resume() {
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
    
    public func pause() {
        player?.pause()
        state = .paused
    }
    
    public func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerLayer?.removeFromSuperlayer()
        
        player = nil
        playerItem = nil
        playerLayer = nil
        
        state = .idle
    }
    
    public func seek(to time: Double, completion: ((Bool) -> Void)? = nil) {
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
    public func updateContainer(_ view: UIView) {
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
    }

    public func setPlaybackRate(_ rate: Float) {
        playbackRate = max(0.5, min(rate, 3.0))
        guard let player = player else { return }
        if state == .playing {
            player.rate = playbackRate
        } else {
            player.playImmediately(atRate: playbackRate)
            state = .playing
        }
    }
    public func setVideoGravity(_ gravity: DYVideoGravity) {
        videoGravity = gravity
    }
    
    // MARK: - Private Methods
    
    private func setupAudioSession() {
        // 允许在静音模式下播放声音
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AudioSession setup failed: \(error)")
        }
    }
    private func avGravity(from gravity: DYVideoGravity) -> AVLayerVideoGravity {
        switch gravity {
        case .aspectFit: return .resizeAspect
        case .aspectFill: return .resizeAspectFill
        case .resize: return .resize
        }
    }
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
            state = .error(errorMsg)
            DispatchQueue.main.async {
                self.delegate?.player(self, didFailWithError: self.playerItem?.error)
            }
            
        case .unknown:
            break
        @unknown default:
            break
        }
    }
    
    private func handleTimeControlStatus(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .paused:
            // 只有不是播放完成状态时，才切换为 paused
            if state != .finished && state != .idle {
                state = .paused
            }
        case .waitingToPlayAtSpecifiedRate:
            // 缓冲中
            if state != .idle && state != .preparing {
                state = .buffering
            }
        case .playing:
            state = .playing
        @unknown default:
            break
        }
    }
    
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
    
    private func handleTimeUpdate(_ time: CMTime) {
        guard let item = playerItem else { return }
        let current = time.seconds
        let total = item.duration.seconds
        
        if total > 0 {
            let progress = current / total
            self.delegate?.player(self, didUpdateProgress: progress, currentTime: current, totalTime: total)
        }
    }
    
    @objc private func playerDidFinishPlaying() {
        state = .finished
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
