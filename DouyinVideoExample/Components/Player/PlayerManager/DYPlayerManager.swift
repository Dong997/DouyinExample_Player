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
    
    /// 播放视频
    /// - Parameters:
    ///   - url: 视频地址
    ///   - view: 承载视图
    ///   - seekTo: 起始播放时间
    public func play(url: URL, in view: UIView, seekTo: Double? = nil) {
        player.play(url: url, in: view, seekTo: seekTo)
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
}
