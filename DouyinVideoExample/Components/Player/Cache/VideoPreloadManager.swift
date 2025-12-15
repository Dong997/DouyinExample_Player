import Foundation

/// 视频预加载策略管理器
/// 负责计算预加载窗口，调用 VideoCacheManager 执行实际的预加载/取消操作
/// 完全与具体播放器解耦，只依赖 URL
public class VideoPreloadManager {
    
    /// 全局单例访问入口
    public static let shared = VideoPreloadManager()
    
    /// 是否启用自适应预加载策略预留开关，目前仅作为配置占位
    public var isAdaptivePreloadEnabled: Bool = false
    
    /// 向后预加载数量
    public var preloadNextCount: Int = 1
    
    /// 向前预加载数量
    public var preloadPreviousCount: Int = 1
    
    /// 单个视频预加载大小（字节），默认 2MB
    public var preloadSize: Int = 2 * 1024 * 1024
    
    /// 当前正在预加载的 URL 集合 (用于避免重复操作)
    private var preloadingUrls: Set<URL> = []
    
    /// 发起预加载请求的总次数（不含命中缓存的情况）
    public private(set) var totalPreloadRequests: Int = 0
    /// 预加载完成的总次数
    public private(set) var totalPreloadCompleted: Int = 0
    /// 预加载失败的总次数
    public private(set) var totalPreloadFailed: Int = 0
    /// 命中已缓存资源的次数（无需再次预加载）
    public private(set) var totalPreloadHits: Int = 0
    
    /// 预加载命中率：命中缓存次数 / (命中缓存 + 实际请求)
    public var cacheHitRate: Double {
        let denominator = Double(totalPreloadRequests + totalPreloadHits)
        if denominator == 0 {
            return 0
        }
        return Double(totalPreloadHits) / denominator
    }
    
    /// 预加载成功率：完成次数 / 请求次数
    public var preloadSuccessRate: Double {
        if totalPreloadRequests == 0 {
            return 0
        }
        return Double(totalPreloadCompleted) / Double(totalPreloadRequests)
    }
    
    /// 预加载失败率：失败次数 / 请求次数
    public var preloadFailureRate: Double {
        if totalPreloadRequests == 0 {
            return 0
        }
        return Double(totalPreloadFailed) / Double(totalPreloadRequests)
    }
    
    /// 用于监听 VideoCacheManager 发出的预加载通知
    private let notificationCenter: NotificationCenter
    
    /// 私有化构造函数，确保通过 shared 访问
    /// - Parameter notificationCenter: 注入的通知中心，默认使用系统默认中心
    private init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        notificationCenter.addObserver(self, selector: #selector(handlePreloadFinished(_:)), name: .videoCacheManagerPreloadFinished, object: nil)
        notificationCenter.addObserver(self, selector: #selector(handlePreloadFailed(_:)), name: .videoCacheManagerPreloadFailed, object: nil)
    }
    
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
            if VideoCacheManager.shared.isFullyCached(for: url) {
                totalPreloadHits += 1
            } else {
                totalPreloadRequests += 1
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
    
    /// 处理预加载完成通知，累加成功计数
    @objc private func handlePreloadFinished(_ notification: Notification) {
        totalPreloadCompleted += 1
    }
    
    /// 处理预加载失败通知，累加失败计数
    @objc private func handlePreloadFailed(_ notification: Notification) {
        totalPreloadFailed += 1
    }
}
