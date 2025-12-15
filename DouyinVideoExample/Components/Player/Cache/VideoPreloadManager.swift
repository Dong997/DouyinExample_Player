import Foundation

/// 视频预加载策略管理器
/// 负责计算预加载窗口，调用 VideoCacheManager 执行实际的预加载/取消操作
/// 完全与具体播放器解耦，只依赖 URL
public class VideoPreloadManager {
    
    public static let shared = VideoPreloadManager()
    
    /// 向后预加载数量
    public var preloadNextCount: Int = 1
    
    /// 向前预加载数量
    public var preloadPreviousCount: Int = 1
    
    /// 单个视频预加载大小（字节），默认 2MB
    public var preloadSize: Int = 2 * 1024 * 1024
    
    /// 当前正在预加载的 URL 集合 (用于避免重复操作)
    private var preloadingUrls: Set<URL> = []
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// 更新预加载策略
    /// 在列表滚动或数据刷新时调用
    /// - Parameters:
    ///   - currentURL: 当前正在播放的视频 URL (可选)
    ///   - allURLs: 当前列表的所有视频 URL 数组
    public func updateStrategy(currentURL: URL?, allURLs: [URL]) {
        guard !allURLs.isEmpty else {
            cancelAll()
            return
        }
        
        // 1. 确定当前播放的索引
        let currentIndex: Int
        if let currentURL = currentURL, let index = allURLs.firstIndex(of: currentURL) {
            currentIndex = index
        } else {
            currentIndex = -1
        }
        
        // 2. 计算需要预加载的 URL 集合
        var targetPreloadURLs: Set<URL> = []
        
        if currentIndex >= 0 {
            // 向前预加载
            let startPrev = max(0, currentIndex - preloadPreviousCount)
            let endPrev = currentIndex
            if startPrev < endPrev {
                targetPreloadURLs.formUnion(allURLs[startPrev..<endPrev])
            }
            
            // 向后预加载
            let startNext = currentIndex + 1
            let endNext = min(startNext + preloadNextCount, allURLs.count)
            if startNext < endNext {
                targetPreloadURLs.formUnion(allURLs[startNext..<endNext])
            }
        } else if currentURL == nil {
            // 如果没有当前播放的 URL (例如刚进入页面)，预加载前几个
            let count = min(preloadNextCount, allURLs.count)
            targetPreloadURLs.formUnion(allURLs[0..<count])
        }
        
        // 3. 执行差异化更新
        
        // 需要取消的：在正在预加载集合中，但不在目标集合中的
        let urlsToCancel = preloadingUrls.subtracting(targetPreloadURLs)
        for url in urlsToCancel {
            VideoCacheManager.shared.cancelPreload(for: url)
        }
        
        // 需要开始的：在目标集合中，但不在正在预加载集合中的
        // 注意：VideoCacheManager 内部也会判重，但这里维护一个 Set 可以减少跨模块调用
        let urlsToStart = targetPreloadURLs.subtracting(preloadingUrls)
        for url in urlsToStart {
            // 如果已经完全缓存了，就不需要预加载了 (VideoCacheManager 可能不暴露这个状态，最好检查一下)
            if !VideoCacheManager.shared.isFullyCached(for: url) {
                VideoCacheManager.shared.preload(url: url, length: preloadSize)
            }
        }
        
        // 更新当前状态
        preloadingUrls = targetPreloadURLs
    }
    
    /// 取消所有预加载任务
    public func cancelAll() {
        VideoCacheManager.shared.cancelAllPreloads()
        preloadingUrls.removeAll()
    }
    
    /// 清理所有磁盘缓存
    public func clearDiskCache() {
        VideoCacheManager.shared.clearAllCache()
    }
    
    /// 清理指定 URL 的缓存
    public func clearCache(for url: URL) {
        VideoCacheManager.shared.clearCache(for: url)
    }
}
