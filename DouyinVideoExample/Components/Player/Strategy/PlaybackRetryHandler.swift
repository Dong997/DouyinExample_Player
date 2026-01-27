import Foundation

/// 播放重试策略处理器
/// 负责封装播放失败时的重试逻辑 (Strategy Pattern)
public class PlaybackRetryHandler {
    
    public init() {}
    
    /// 检查是否需要重试
    /// - Parameters:
    ///   - error: 播放失败的错误
    ///   - currentURL: 当前播放失败的 URL
    ///   - originalURL: 视频原始 URL
    /// - Returns: 如果需要重试，返回重试使用的 URL；否则返回 nil
    public func shouldRetry(for error: Error?, currentURL: URL, originalURL: URL) -> URL? {
        // 如果当前播放的 URL 与原始 URL 不一致，说明可能是在播放缓存代理链接
        // 当代理链接失效时，降级尝试直接播放原始链接
        if currentURL != originalURL {
            print("[PlaybackRetryHandler] Playback failed for proxy URL: \(currentURL). Downgrading to original URL: \(originalURL)")
            
            // 标记原始 URL 为黑名单，防止后续 VideoCacheManager 再次生成代理 URL
            VideoCacheManager.shared.addToBlacklist(url: originalURL)
            
            return originalURL
        }
        
        // 如果已经是原始 URL 播放失败，则不再重试
        return nil
    }
}
