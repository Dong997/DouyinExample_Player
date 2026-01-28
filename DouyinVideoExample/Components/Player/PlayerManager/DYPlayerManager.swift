import UIKit

/// 播放器单例管理器 - 方便在列表滚动中使用同一个播放器实例
public class DYPlayerManager: NSObject {
    
    public static let shared = DYPlayerManager()
    
    /// 当前“主”播放器（UI 正在展示的那个）
    public var player: DYVideoPlayer {
        return currentPlayer
    }
    
    private var currentPlayer: DYVideoPlayer
    private var playerPool: [DYVideoPlayer] = []
    private let maxPoolSize = 3
    
    public var preloadPercentage: Double = 0.10
    
    private override init() {
        let initial = DYVideoPlayer()
        initial.isLooping = true
        currentPlayer = initial
        playerPool.append(initial)
        super.init()
    }
    
    /// 获取一个用于预加载的播放器（不改变 currentPlayer）
    public func acquirePreloadPlayer() -> DYVideoPlayer {
        if let idle = playerPool.first(where: { 
            $0 !== currentPlayer && ($0.state == .idle || $0.state == .finished || isErrorState($0.state))
        }) {
            idle.reset()
            markAsRecentlyUsed(idle)
            return idle
        }
        
        if playerPool.count < maxPoolSize {
            let newPlayer = DYVideoPlayer()
            newPlayer.isLooping = true
            playerPool.append(newPlayer)
            return newPlayer
        }

        let candidates = playerPool.filter { $0 !== currentPlayer }
        
        if let pausedVictim = candidates.first(where: { $0.state == .paused }) {
            pausedVictim.stop()
            pausedVictim.reset()
            markAsRecentlyUsed(pausedVictim)
            return pausedVictim
        }
        
        if let victim = candidates.first {
            victim.stop()
            victim.reset()
            markAsRecentlyUsed(victim)
            return victim
        }
        
        return currentPlayer
    }
    
    private func markAsRecentlyUsed(_ player: DYVideoPlayer) {
        if let index = playerPool.firstIndex(of: player) {
            playerPool.remove(at: index)
            playerPool.append(player)
        }
    }
    
    private func isErrorState(_ state: DYPlayerState) -> Bool {
        if case .error = state { return true }
        return false
    }
    
    /// 将某个预加载播放器提升为当前主播放器
    public func promoteToCurrent(_ player: DYVideoPlayer) {
        if player !== currentPlayer {
            currentPlayer = player
            markAsRecentlyUsed(player)
        }
    }
    
    public func play(url: URL, in view: UIView, seekTo: TimeInterval? = nil) {
        player.play(url: url, in: view, seekTo: seekTo)
    }
    
    public func playWithCache(originalURL: URL, in view: UIView, seekTo: TimeInterval? = nil, use targetPlayer: DYVideoPlayer? = nil) {
        let p = targetPlayer ?? self.player
        let proxyURL = VideoCacheManager.shared.getProxyURL(for: originalURL)
        // 传递 originalURL 以便后续重试逻辑使用
        p.play(url: proxyURL, originalURL: originalURL, in: view, seekTo: seekTo)
    }
    
    /// 预加载指定视频（不自动播放）
    public func preload(originalURL: URL, use targetPlayer: DYVideoPlayer) {
        let proxyURL = VideoCacheManager.shared.getProxyURL(for: originalURL)
        targetPlayer.prepare(url: proxyURL, originalURL: originalURL)
    }
    
    /// 暂停
    public func pause() {
        player.pause()
    }
    
    /// 恢复
    public func resume() {
        player.resume()
    }
    
    /// 停止
    public func stop() {
        player.stop()
    }
    
    /// 跳转到指定时间
    /// - Parameters:
    ///   - time: 目标时间 (秒)
    ///   - isPrecise: 是否精确跳转。
    ///     - true: 精确跳转 (tolerance = zero)，适用于用户停止拖拽后的最终定位。
    ///     - false: 快速跳转 (tolerance = infinity)，适用于用户正在拖拽进度条时的实时预览，性能更好。
    ///   - completion: 完成回调
    public func seek(to time: TimeInterval, isPrecise: Bool = true, completion: ((Bool) -> Void)? = nil) {
        player.seek(to: time, isPrecise: isPrecise, completion: completion)
    }
}
