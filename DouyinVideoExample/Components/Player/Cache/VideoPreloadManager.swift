import Foundation

/// 视频预加载策略管理器
/// 负责计算预加载窗口，调用 VideoCacheManager 执行实际的预加载/取消操作
/// 完全与具体播放器解耦，只依赖 URL
public class VideoPreloadManager {
    
    /// 全局单例访问入口
    public static let shared = VideoPreloadManager()
    
    /// 是否启用自适应预加载策略预留开关，目前仅作为配置占位
    public var isAdaptivePreloadEnabled: Bool = true
    
    /// 向后预加载数量
    public var preloadNextCount: Int = 1
    
    /// 向前预加载数量
    public var preloadPreviousCount: Int = 1
    
    /// 单个视频预加载大小（字节），默认 2MB
    public var preloadSize: Int = 2 * 1024 * 1024
    
    public var maxConcurrentPreloads: Int = 3
    
    private let minPreloadSize = 1 * 1024 * 1024 // 1MB
    private let maxPreloadSize = 5 * 1024 * 1024 // 5MB
    private var requestsSinceLastAdjustment = 0
    private let adjustmentThreshold = 5 // 每 5 次请求尝试调整一次
    
    private var preloadingUrls: Set<URL> = []

    private var runningPreloads: Set<URL> = []

    private var currentAllURLs: [URL] = []
    
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
    
    private let stateQueue = DispatchQueue(label: "com.douyin.videoPreloadManager.state")
    
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
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            self.currentAllURLs = allURLs
            
            guard !allURLs.isEmpty else {
                self.cancelAllOnQueue()
                return
            }
            
            let currentIndex: Int
            if let currentURL = currentURL, let index = allURLs.firstIndex(of: currentURL) {
                currentIndex = index
            } else {
                currentIndex = -1
            }
            
            var targetPreloadURLs: Set<URL> = []
            
            if currentIndex >= 0 {
                let startPrev = max(0, currentIndex - self.preloadPreviousCount)
                let endPrev = currentIndex
                if startPrev < endPrev {
                    targetPreloadURLs.formUnion(allURLs[startPrev..<endPrev])
                }
                
                let startNext = currentIndex + 1
                let endNext = min(startNext + self.preloadNextCount, allURLs.count)
                if startNext < endNext {
                    targetPreloadURLs.formUnion(allURLs[startNext..<endNext])
                }
            } else if currentURL == nil {
                let count = min(self.preloadNextCount, allURLs.count)
                targetPreloadURLs.formUnion(allURLs[0..<count])
            }
            
            let newInWindow = targetPreloadURLs.subtracting(self.preloadingUrls)
            for url in newInWindow {
                if VideoCacheManager.shared.isFullyCached(for: url) {
                    self.totalPreloadHits += 1
                }
            }
            
            self.preloadingUrls = targetPreloadURLs
            self.schedulePreloads()
        }
    }
    
    /// 调度预加载任务：取消越界的，启动窗口内的，遵守并发限制
    private func schedulePreloads() {
        let toCancel = runningPreloads.subtracting(preloadingUrls)
        for url in toCancel {
            VideoCacheManager.shared.cancelPreload(for: url)
            runningPreloads.remove(url)
        }

        let candidates = currentAllURLs.filter { url in
            preloadingUrls.contains(url) &&
            !runningPreloads.contains(url) &&
            !VideoCacheManager.shared.isFullyCached(for: url)
        }
        
        for url in candidates {
            if runningPreloads.count >= maxConcurrentPreloads {
                break
            }
            
            VideoCacheManager.shared.preload(url: url, length: preloadSize)
            totalPreloadRequests += 1
            runningPreloads.insert(url)
        }
    }
    
    /// 取消所有预加载任务
    public func cancelAll() {
        stateQueue.async { [weak self] in
            self?.cancelAllOnQueue()
        }
    }
    
    private func cancelAllOnQueue() {
        VideoCacheManager.shared.cancelAllPreloads()
        preloadingUrls.removeAll()
        runningPreloads.removeAll()
        currentAllURLs.removeAll()
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
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            self.totalPreloadCompleted += 1
            if let userInfo = notification.userInfo, let url = userInfo["url"] as? URL {
                self.runningPreloads.remove(url)
            }
            self.schedulePreloads()
            self.checkAndAdjustPreloadSize()
        }
    }
    
    /// 处理预加载失败通知，累加失败计数
    @objc private func handlePreloadFailed(_ notification: Notification) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            self.totalPreloadFailed += 1
            if let userInfo = notification.userInfo, let url = userInfo["url"] as? URL {
                self.runningPreloads.remove(url)
            }
            self.schedulePreloads()
            self.checkAndAdjustPreloadSize()
        }
    }
    
    /// 根据成功/失败率动态调整预加载大小
    private func checkAndAdjustPreloadSize() {
        guard isAdaptivePreloadEnabled else { return }
        
        requestsSinceLastAdjustment += 1
        if requestsSinceLastAdjustment < adjustmentThreshold {
            return
        }
        requestsSinceLastAdjustment = 0
        
        // 简单策略：失败率高则减小，成功率高则增加
        // 注意：这里仅考虑最近的趋势可能会更好，但为了简单，先使用全局概率参考
        // 实际生产中建议使用滑动窗口计算最近 N 次的成功率
        
        if preloadFailureRate > 0.2 {
            // 失败率 > 20%，网络可能较差，减少预加载量
            let newSize = max(minPreloadSize, preloadSize - 512 * 1024)
            if newSize != preloadSize {
                preloadSize = newSize
                print("[VideoPreloadManager] Adaptive: Decreased preload size to \(preloadSize / 1024 / 1024)MB")
            }
        } else if preloadSuccessRate > 0.8 {
            // 成功率 > 80%，网络状况良好，尝试增加预加载量
            let newSize = min(maxPreloadSize, preloadSize + 512 * 1024)
            if newSize != preloadSize {
                preloadSize = newSize
                print("[VideoPreloadManager] Adaptive: Increased preload size to \(preloadSize / 1024 / 1024)MB")
            }
        }
    }
}
