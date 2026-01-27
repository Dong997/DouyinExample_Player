import UIKit

/// 播放器单例管理器 - 方便在列表滚动中使用同一个播放器实例
public class DYPlayerManager: NSObject {
    
    public static let shared = DYPlayerManager()
    
    /// 核心播放器实例
    public let player = DYVideoPlayer()
    
    public var preloadPercentage: Double = 0.10
    
    private override init() {
        super.init()
        player.isLooping = true
    }
    
    public func play(url: URL, in view: UIView, seekTo: TimeInterval? = nil) {
        player.play(url: url, in: view, seekTo: seekTo)
    }
    
    public func playWithCache(originalURL: URL, in view: UIView, seekTo: TimeInterval? = nil) {
        let proxyURL = VideoCacheManager.shared.getProxyURL(for: originalURL)
        player.playWithCache(originalURL: originalURL, proxyURL: proxyURL, in: view, seekTo: seekTo)
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
