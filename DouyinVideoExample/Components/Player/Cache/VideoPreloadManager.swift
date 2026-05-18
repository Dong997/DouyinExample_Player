import Foundation
import os.log

/// 视频预加载策略管理器
/// 负责计算预加载窗口，调用 VideoCacheManager 执行实际的预加载/取消操作
/// 完全与具体播放器解耦；预加载任务通过注入的 `VideoCacheManager` 执行。
///
/// 线程安全策略：
/// 所有可变状态通过 @MainActor 保护，移除了原有的 stateQueue，
/// 与 VideoCacheManager 保持一致的并发模型，避免跨 actor 调用问题。
/// 内置防抖机制，快速滑动时合并多次 updateStrategy 调用。
@MainActor
public class VideoPreloadManager {

    /// 当前字节级预加载状态快照，便于调试预加载窗口、并发任务和命中率。
    public struct DebugSnapshot: CustomStringConvertible {
        public let preloadNextCount: Int
        public let preloadPreviousCount: Int
        public let preloadSize: Int
        public let maxConcurrentPreloads: Int
        public let allURLCount: Int
        public let lastResolvedIndex: Int?
        public let preloadingURLs: [URL]
        public let runningPreloads: [URL]
        public let priorityOrder: [URL]
        public let totalPreloadRequests: Int
        public let totalPreloadCompleted: Int
        public let totalPreloadFailed: Int
        public let totalPreloadHits: Int
        public let cacheHitRate: Double
        public let preloadSuccessRate: Double

        public var description: String {
            "window=\(shortList(preloadingURLs)), running=\(shortList(runningPreloads)), priority=\(shortList(priorityOrder)), size=\(preloadSize), currentIndex=\(String(describing: lastResolvedIndex)), requests=\(totalPreloadRequests), completed=\(totalPreloadCompleted), failed=\(totalPreloadFailed), hits=\(totalPreloadHits), hitRate=\(String(format: "%.2f", cacheHitRate)), successRate=\(String(format: "%.2f", preloadSuccessRate))"
        }

        private func shortList(_ urls: [URL]) -> String {
            "[" + urls.map { $0.lastPathComponent }.joined(separator: ",") + "]"
        }
    }

    /// 全局单例访问入口（与 `VideoCacheManager.shared` 配对，兼容未走组合根的代码路径）
    public static let shared = VideoPreloadManager(cache: VideoCacheManager.shared)

    /// 是否启用自适应预加载策略预留开关，目前仅作为配置占位
    public var isAdaptivePreloadEnabled: Bool = true

    /// 向后预加载数量
    public var preloadNextCount: Int = 1

    /// 向前预加载数量
    public var preloadPreviousCount: Int = 1

    /// 单个视频预加载大小（字节），默认 2MB
    public var preloadSize: Int = 2 * 1024 * 1024

    public var maxConcurrentPreloads: Int = 3

    private let minPreloadSize = 1 * 1024 * 1024
    private let maxPreloadSize = 5 * 1024 * 1024
    private var requestsSinceLastAdjustment = 0
    private let adjustmentThreshold = 5
    private let adaptiveWindowSize = 20
    private var recentPreloadOutcomes: [PreloadOutcome] = []
    private let cacheReadinessSnapshotTTL: TimeInterval = 1.0
    private var cacheReadinessSnapshots: [URL: CacheReadinessSnapshot] = [:]

    private var preloadingUrls: Set<URL> = []
    private var runningPreloads: Set<URL> = []
    private var preloadURLPriorityOrder: [URL] = []
    private var currentAllURLs: [URL] = []

    /// 上次计算时的当前索引，用于 early return 避免重复计算
    private var lastResolvedIndex: Int?

    /// 防抖工作项，快速滑动时合并多次 updateStrategy 调用
    private var debounceWorkItem: Task<Void, Never>?

    /// 防抖间隔（纳秒），在间隔内的多次调用只执行最后一次
    private let debounceIntervalNanos: UInt64 = 150_000_000

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
        if denominator == 0 { return 0 }
        return Double(totalPreloadHits) / denominator
    }

    /// 预加载成功率：完成次数 / 请求次数
    public var preloadSuccessRate: Double {
        if totalPreloadRequests == 0 { return 0 }
        return Double(totalPreloadCompleted) / Double(totalPreloadRequests)
    }

    /// 预加载失败率：失败次数 / 请求次数
    public var preloadFailureRate: Double {
        if totalPreloadRequests == 0 { return 0 }
        return Double(totalPreloadFailed) / Double(totalPreloadRequests)
    }

    public var debugSnapshot: DebugSnapshot {
        DebugSnapshot(
            preloadNextCount: preloadNextCount,
            preloadPreviousCount: preloadPreviousCount,
            preloadSize: preloadSize,
            maxConcurrentPreloads: maxConcurrentPreloads,
            allURLCount: currentAllURLs.count,
            lastResolvedIndex: lastResolvedIndex,
            preloadingURLs: Array(preloadingUrls),
            runningPreloads: Array(runningPreloads),
            priorityOrder: preloadURLPriorityOrder,
            totalPreloadRequests: totalPreloadRequests,
            totalPreloadCompleted: totalPreloadCompleted,
            totalPreloadFailed: totalPreloadFailed,
            totalPreloadHits: totalPreloadHits,
            cacheHitRate: cacheHitRate,
            preloadSuccessRate: preloadSuccessRate
        )
    }

    private let cache: VideoCacheManager
    private let notificationCenter: NotificationCenter

    private enum PreloadOutcome {
        case success
        case failure
    }

    private struct CacheReadinessSnapshot {
        let requiredLength: Int
        let isReady: Bool
        let checkedAt: Date
    }

    /// - Parameters:
    ///   - cache: 执行实际预加载 / 取消 / 查询缓存的实例，应与播放链路使用同一 `VideoCacheManager`。
    ///   - notificationCenter: 注入的通知中心，默认使用系统默认中心
    public init(cache: VideoCacheManager? = nil, notificationCenter: NotificationCenter = .default) {
        self.cache = cache ?? .shared
        self.notificationCenter = notificationCenter
        notificationCenter.addObserver(self, selector: #selector(handlePreloadFinished(_:)), name: .videoCacheManagerPreloadFinished, object: nil)
        notificationCenter.addObserver(self, selector: #selector(handlePreloadFailed(_:)), name: .videoCacheManagerPreloadFailed, object: nil)
    }

    // MARK: - Public Methods

    /// 更新预加载策略
    /// 在列表滚动或数据刷新时调用
    /// 内置防抖机制：快速滑动时合并多次调用，仅执行最后一次
    /// - Parameters:
    ///   - currentURL: 当前正在播放的视频 URL (可选)
    ///   - allURLs: 当前列表的所有视频 URL 数组
    ///   - currentIndex: 当前播放项在列表中的位置；传入后优先用于处理重复 URL 场景
    public func updateStrategy(currentURL: URL?, allURLs: [URL], currentIndex: Int? = nil) {
        debounceWorkItem?.cancel()
        AppLog.preload.debug("Preload update requested currentIndex=\(String(describing: currentIndex)), current=\(currentURL?.lastPathComponent ?? "nil"), allCount=\(allURLs.count)")

        debounceWorkItem = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceIntervalNanos ?? 150_000_000)
            guard !Task.isCancelled else { return }
            self?.performStrategyUpdate(currentURL: currentURL, allURLs: allURLs, currentIndex: currentIndex)
        }
    }

    /// 实际执行策略计算（由防抖调度）
    private func performStrategyUpdate(currentURL: URL?, allURLs: [URL], currentIndex: Int?) {
        self.currentAllURLs = allURLs
        self.pruneCacheReadinessSnapshots(keeping: Set(allURLs))

        guard !allURLs.isEmpty else {
            self.cancelAllInternal()
            self.lastResolvedIndex = nil
            return
        }

        let resolvedCurrentIndex = self.resolveCurrentIndex(
            currentURL: currentURL,
            allURLs: allURLs,
            currentIndex: currentIndex
        )

        if resolvedCurrentIndex == lastResolvedIndex {
            return
        }
        lastResolvedIndex = resolvedCurrentIndex

        let previousWindow = self.preloadingUrls

        var urlSet = Set<URL>()
        var orderedPreloadURLs: [URL] = []

        func appendUnique(_ url: URL) {
            guard !urlSet.contains(url) else { return }
            urlSet.insert(url)
            orderedPreloadURLs.append(url)
        }

        if let currentIndex = resolvedCurrentIndex {
            let startNext = currentIndex + 1
            let endNext = min(startNext + self.preloadNextCount, allURLs.count)
            if startNext < endNext {
                for url in allURLs[startNext..<endNext] {
                    appendUnique(url)
                }
            }

            let startPrev = max(0, currentIndex - self.preloadPreviousCount)
            let endPrev = currentIndex
            if startPrev < endPrev {
                for index in (startPrev..<endPrev).reversed() {
                    appendUnique(allURLs[index])
                }
            }
        } else if currentURL == nil {
            self.appendInitialPreloadWindow(from: allURLs, append: appendUnique)
        } else {
            self.appendInitialPreloadWindow(from: allURLs, append: appendUnique)
        }

        let newInWindow = urlSet.subtracting(previousWindow)
        for url in newInWindow {
            if self.isCacheReadyForCurrentPreload(url) {
                self.totalPreloadHits += 1
            }
        }

        self.preloadingUrls = urlSet
        self.preloadURLPriorityOrder = orderedPreloadURLs
        #if DEBUG
        AppLog.preload.info("Preload window resolved currentIndex=\(String(describing: resolvedCurrentIndex)), current=\(currentURL?.lastPathComponent ?? "nil"), window=\(self.shortURLList(orderedPreloadURLs)), new=\(self.shortURLList(Array(newInWindow))), snapshot=\(self.debugSnapshot.description)")
        #else
        AppLog.preload.info("Preload window resolved currentIndex=\(String(describing: resolvedCurrentIndex)), current=\(currentURL?.lastPathComponent ?? "nil"), window=\(self.shortURLList(orderedPreloadURLs)), new=\(self.shortURLList(Array(newInWindow)))")
        #endif
        self.schedulePreloads()
    }

    private func resolveCurrentIndex(currentURL: URL?, allURLs: [URL], currentIndex: Int?) -> Int? {
        if let currentIndex = currentIndex, allURLs.indices.contains(currentIndex) {
            if let currentURL = currentURL, allURLs[currentIndex] != currentURL {
                return nearestIndex(of: currentURL, in: allURLs, around: currentIndex) ?? currentIndex
            }
            return currentIndex
        }

        guard let currentURL = currentURL else { return nil }
        return allURLs.firstIndex(of: currentURL)
    }

    private func nearestIndex(of url: URL, in urls: [URL], around preferredIndex: Int) -> Int? {
        urls.indices
            .filter { urls[$0] == url }
            .min { abs($0 - preferredIndex) < abs($1 - preferredIndex) }
    }

    private func appendInitialPreloadWindow(from allURLs: [URL], append: (URL) -> Void) {
        let count = min(preloadNextCount, allURLs.count)
        guard count > 0 else { return }

        for url in allURLs[0..<count] {
            append(url)
        }
    }

    /// 调度预加载任务：取消越界的，启动窗口内的，遵守并发限制
    private func schedulePreloads() {
        let toCancel = runningPreloads.subtracting(preloadingUrls)
        for url in toCancel {
            cache.cancelPreload(for: url)
            runningPreloads.remove(url)
            #if DEBUG
            AppLog.preload.info("Preload cancel outOfWindow url=\(url.lastPathComponent), snapshot=\(self.debugSnapshot.description)")
            #else
            AppLog.preload.info("Preload cancel outOfWindow url=\(url.lastPathComponent)")
            #endif
        }

        let candidates = preloadURLPriorityOrder.filter { url in
            preloadingUrls.contains(url) &&
            !runningPreloads.contains(url) &&
            !isCacheReadyForCurrentPreload(url)
        }

        AppLog.preload.debug("Preload schedule candidates=\(self.shortURLList(candidates)), running=\(self.shortURLList(Array(self.runningPreloads))), maxConcurrent=\(self.maxConcurrentPreloads)")

        for url in candidates {
            if runningPreloads.count >= maxConcurrentPreloads {
                break
            }

            if cache.preload(url: url, length: preloadSize) {
                totalPreloadRequests += 1
                runningPreloads.insert(url)
                AppLog.preload.info("Preload start url=\(url.lastPathComponent), size=\(self.preloadSize), running=\(self.shortURLList(Array(self.runningPreloads)))")
            }
        }
    }

    /// 取消所有预加载任务
    public func cancelAll() {
        cancelAllInternal()
    }

    private func cancelAllInternal() {
        cache.cancelAllPreloads()
        preloadingUrls.removeAll()
        runningPreloads.removeAll()
        preloadURLPriorityOrder.removeAll()
        currentAllURLs.removeAll()
        cacheReadinessSnapshots.removeAll()
        lastResolvedIndex = nil
        AppLog.preload.info("Preload cancel all")
    }

    /// 清理所有磁盘缓存
    public func clearDiskCache() {
        cache.clearAllCache()
        cacheReadinessSnapshots.removeAll()
    }

    /// 清理指定 URL 的缓存
    public func clearCache(for url: URL) {
        cache.clearCache(for: url)
        cacheReadinessSnapshots.removeValue(forKey: url)
    }

    private func isCacheReadyForCurrentPreload(_ url: URL) -> Bool {
        let now = Date()
        if let snapshot = cacheReadinessSnapshots[url],
           snapshot.requiredLength == preloadSize,
           now.timeIntervalSince(snapshot.checkedAt) <= cacheReadinessSnapshotTTL {
            return snapshot.isReady
        }

        let isReady = cache.hasCachedData(for: url, minimumLength: preloadSize) || cache.isFullyCached(for: url)
        cacheReadinessSnapshots[url] = CacheReadinessSnapshot(
            requiredLength: preloadSize,
            isReady: isReady,
            checkedAt: now
        )
        return isReady
    }

    private func markCacheReadyForCurrentPreload(_ url: URL) {
        cacheReadinessSnapshots[url] = CacheReadinessSnapshot(
            requiredLength: preloadSize,
            isReady: true,
            checkedAt: Date()
        )
    }

    private func invalidateCacheReadinessSnapshot(for url: URL) {
        cacheReadinessSnapshots.removeValue(forKey: url)
    }

    private func pruneCacheReadinessSnapshots(keeping urls: Set<URL>) {
        cacheReadinessSnapshots = cacheReadinessSnapshots.filter { urls.contains($0.key) }
    }

    /// 处理预加载完成通知，累加成功计数
    @objc private func handlePreloadFinished(_ notification: Notification) {
        Task { @MainActor in
            self.totalPreloadCompleted += 1
            self.recordPreloadOutcome(.success)
            if let userInfo = notification.userInfo, let url = userInfo["url"] as? URL {
                self.runningPreloads.remove(url)
                self.markCacheReadyForCurrentPreload(url)
                #if DEBUG
                AppLog.preload.info("Preload finished url=\(url.lastPathComponent), snapshot=\(self.debugSnapshot.description)")
                #else
                AppLog.preload.info("Preload finished url=\(url.lastPathComponent)")
                #endif
            }
            self.schedulePreloads()
            self.checkAndAdjustPreloadSize()
        }
    }

    /// 处理预加载失败通知，累加失败计数
    @objc private func handlePreloadFailed(_ notification: Notification) {
        Task { @MainActor in
            self.totalPreloadFailed += 1
            self.recordPreloadOutcome(.failure)
            if let userInfo = notification.userInfo, let url = userInfo["url"] as? URL {
                self.runningPreloads.remove(url)
                self.invalidateCacheReadinessSnapshot(for: url)
                #if DEBUG
                AppLog.preload.warning("Preload failed url=\(url.lastPathComponent), snapshot=\(self.debugSnapshot.description)")
                #else
                AppLog.preload.warning("Preload failed url=\(url.lastPathComponent)")
                #endif
            }
            self.schedulePreloads()
            self.checkAndAdjustPreloadSize()
        }
    }

    private func recordPreloadOutcome(_ outcome: PreloadOutcome) {
        recentPreloadOutcomes.append(outcome)
        if recentPreloadOutcomes.count > adaptiveWindowSize {
            recentPreloadOutcomes.removeFirst(recentPreloadOutcomes.count - adaptiveWindowSize)
        }
    }

    private func shortURLList(_ urls: [URL]) -> String {
        "[" + urls.map { $0.lastPathComponent }.joined(separator: ",") + "]"
    }

    /// 根据成功/失败率动态调整预加载大小
    private func checkAndAdjustPreloadSize() {
        guard isAdaptivePreloadEnabled else { return }

        requestsSinceLastAdjustment += 1
        if requestsSinceLastAdjustment < adjustmentThreshold {
            return
        }
        requestsSinceLastAdjustment = 0

        let windowCount = recentPreloadOutcomes.count
        guard windowCount >= adjustmentThreshold else { return }

        let recentFailures = recentPreloadOutcomes.filter { $0 == .failure }.count
        let recentSuccesses = recentPreloadOutcomes.filter { $0 == .success }.count
        let recentFailureRate = Double(recentFailures) / Double(windowCount)
        let recentSuccessRate = Double(recentSuccesses) / Double(windowCount)

        if recentFailureRate > 0.2 {
            let newSize = max(minPreloadSize, preloadSize - 512 * 1024)
            if newSize != preloadSize {
                preloadSize = newSize
                AppLog.preload.info("Adaptive: Decreased preload size to \(self.preloadSize / 1024 / 1024)MB")
            }
        } else if recentSuccessRate > 0.8 {
            let newSize = min(maxPreloadSize, preloadSize + 512 * 1024)
            if newSize != preloadSize {
                preloadSize = newSize
                AppLog.preload.info("Adaptive: Increased preload size to \(self.preloadSize / 1024 / 1024)MB")
            }
        }
    }
}
