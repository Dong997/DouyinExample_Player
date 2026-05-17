import Foundation
import KTVHTTPCache
import os.log

/// 视频缓存管理器的预加载回调协议
/// 提供预加载进度、完成与失败三类事件
public protocol VideoCacheManagerDelegate: AnyObject {
    /// 预加载进度变更回调
    /// - Parameters:
    ///   - manager: 缓存管理器实例
    ///   - progress: 当前预加载进度 (0.0 ~ 1.0)
    ///   - url: 正在预加载的资源 URL
    func videoCacheManager(_ manager: VideoCacheManager, didUpdatePreloadProgress progress: Double, for url: URL)

    /// 单个资源预加载完成回调
    /// - Parameters:
    ///   - manager: 缓存管理器实例
    ///   - url: 预加载完成的资源 URL
    func videoCacheManager(_ manager: VideoCacheManager, didFinishPreloadFor url: URL)

    /// 单个资源预加载失败回调
    /// - Parameters:
    ///   - manager: 缓存管理器实例
    ///   - url: 预加载失败的资源 URL
    ///   - error: 具体错误信息
    func videoCacheManager(_ manager: VideoCacheManager, didFailPreloadFor url: URL, error: Error)
}

public extension VideoCacheManagerDelegate {
    func videoCacheManager(_ manager: VideoCacheManager, didUpdatePreloadProgress progress: Double, for url: URL) {}
    func videoCacheManager(_ manager: VideoCacheManager, didFinishPreloadFor url: URL) {}
    func videoCacheManager(_ manager: VideoCacheManager, didFailPreloadFor url: URL, error: Error) {}
}

public extension Notification.Name {
    /// 预加载进度通知，userInfo: ["url": URL, "progress": Double]
    static let videoCacheManagerPreloadProgress = Notification.Name("VideoCacheManagerPreloadProgress")
    /// 预加载完成通知，userInfo: ["url": URL]
    static let videoCacheManagerPreloadFinished = Notification.Name("VideoCacheManagerPreloadFinished")
    /// 预加载失败通知，userInfo: ["url": URL, "error": Error]
    static let videoCacheManagerPreloadFailed = Notification.Name("VideoCacheManagerPreloadFailed")
}

/// 视频缓存管理器 - 基于 KTVHTTPCache 封装
/// 负责视频资源的缓存、预加载、代理 URL 生成等
///
/// 线程安全策略：
/// 所有可变状态（黑名单、预加载 loader）均通过 @MainActor 保护，
/// 移除了原有的 stateQueue，避免 sync 调用可能导致的死锁风险。
/// KTVHCDataLoaderDelegate 回调可能来自后台线程，统一 dispatch 到主线程处理。
@MainActor
public class VideoCacheManager: NSObject {

    /// 全局单例访问入口
    public static let shared = VideoCacheManager()

    /// 当前正在预加载的 loader 列表，key 为 URL 字符串
    private var preloadLoaders: [String: KTVHCDataLoader] = [:]

    /// 手动加入的黑名单 URL 集合（业务层通过 addToBlacklist 管理）
    private var manualBlacklistedURLs: Set<URL> = []
    /// 自动记录的黑名单 URL 集合（由预加载失败自动维护）
    private var autoBlacklistedURLs: Set<URL> = []
    /// 自动黑名单的时间戳，用于计算 TTL 是否过期
    private var autoBlacklistTimestamps: [URL: Date] = [:]

    /// 是否启用自动黑名单逻辑，默认 true
    public var isAutoBlacklistEnabled: Bool = true
    /// 自动黑名单有效期，nil 表示永久有效
    public var autoBlacklistTTL: TimeInterval?

    /// 外部 delegate，用于接收预加载进度和结果回调
    public weak var delegate: VideoCacheManagerDelegate?

    private override init() {
        super.init()
        setupConfiguration()
    }

    // MARK: - Blacklist Management

    /// 手动将 URL 加入黑名单 (通常用于播放器报错时)
    public func addToBlacklist(url: URL) {
        manualBlacklistedURLs.insert(url)
        AppLog.cache.info("URL added to blacklist manually: \(url.lastPathComponent)")
    }

    /// 检查 URL 是否在黑名单中（含手动和自动黑名单，支持 TTL 过期清理）
    /// - Parameter url: 待检查的 URL
    /// - Returns: 是否在黑名单中
    private func isURLInBlacklist(_ url: URL) -> Bool {
        if manualBlacklistedURLs.contains(url) {
            return true
        }
        if !isAutoBlacklistEnabled {
            return false
        }
        if let ttl = autoBlacklistTTL {
            if let createdAt = autoBlacklistTimestamps[url] {
                let interval = Date().timeIntervalSince(createdAt)
                if interval > ttl {
                    autoBlacklistedURLs.remove(url)
                    autoBlacklistTimestamps.removeValue(forKey: url)
                    return false
                }
            } else if autoBlacklistedURLs.contains(url) {
                autoBlacklistTimestamps[url] = Date()
            }
        }
        return autoBlacklistedURLs.contains(url)
    }

    // MARK: - Configuration

    /// 初始化配置
    private func setupConfiguration() {
        KTVHTTPCache.cacheSetMaxCacheLength(500 * 1024 * 1024)
        KTVHTTPCache.downloadSetTimeoutInterval(30)

        let contentTypes = [
            "video/mp4",
            "video/mpeg",
            "video/quicktime",
            "video/x-m4v",
            "video/x-flv",
            "video/x-msvideo",
            "audio/mpeg",
            "audio/x-wav",
            "application/octet-stream",
            "binary/octet-stream",
            "application/x-www-form-urlencoded"
        ]
        KTVHTTPCache.downloadSetAcceptableContentTypes(contentTypes)

        KTVHTTPCache.downloadSetUnacceptableContentTypeDisposer { url, contentType in
            AppLog.cache.warning("Unacceptable Content-Type: \(contentType ?? "nil") for URL: \(url?.lastPathComponent ?? "nil")")
            return true
        }
    }

    /// 启动本地代理服务
    @discardableResult
    public func start() -> Bool {
        if KTVHTTPCache.proxyIsRunning() {
            return true
        }

        do {
            try KTVHTTPCache.proxyStart()
            AppLog.cache.info("Proxy started successfully")
            return true
        } catch {
            AppLog.cache.error("Proxy start failed: \(error)")
            return false
        }
    }

    // MARK: - URL Handling

    /// 获取代理 URL
    /// - Parameter originalURL: 原始视频 URL
    /// - Returns: 代理后的 URL，如果生成失败返回原始 URL
    public func getProxyURL(for originalURL: URL) -> URL {
        if isURLInBlacklist(originalURL) {
            AppLog.cache.info("URL is in blacklist, using original URL: \(originalURL.lastPathComponent)")
            return originalURL
        }

        if !start() {
            AppLog.cache.warning("Proxy unavailable, using original URL: \(originalURL.lastPathComponent)")
            return originalURL
        }

        guard let proxyURL = KTVHTTPCache.proxyURL(withOriginalURL: originalURL) else {
            AppLog.cache.warning("Proxy URL generation failed, using original URL: \(originalURL.lastPathComponent)")
            return originalURL
        }

        AppLog.cache.info("Proxy URL resolved original=\(originalURL.absoluteString), proxy=\(proxyURL.absoluteString)")
        return proxyURL
    }

    // MARK: - Cache Management

    /// 获取当前缓存总大小 (字节)
    public func calculateCacheSize() -> Int64 {
        return KTVHTTPCache.cacheTotalCacheLength()
    }

    /// 清除所有缓存
    public func clearAllCache() {
        cancelAllPreloads()
        KTVHTTPCache.cacheDeleteAllCaches()
        AppLog.cache.info("All caches deleted")
    }

    /// 删除指定 URL 的缓存
    public func clearCache(for url: URL) {
        KTVHTTPCache.cacheDelete(with: url)
    }

    // MARK: - Cache Status

    /// 判断是否已完全缓存
    public func isFullyCached(for url: URL) -> Bool {
        return KTVHTTPCache.cacheCompleteFileURL(with: url) != nil
    }

    /// 获取缓存的本地文件路径 (仅当完全缓存时可用)
    public func getCacheFileURL(for url: URL) -> URL? {
        return KTVHTTPCache.cacheCompleteFileURL(with: url)
    }

    /// 获取缓存状态 (已缓存大小, 总大小)
    public func getCacheState(for url: URL) -> (cached: Int64, total: Int64) {
        guard let item = KTVHTTPCache.cacheCacheItem(with: url) else {
            return (0, 0)
        }
        return (item.cacheLength, item.totalLength)
    }

    /// 判断是否已缓存足够的预加载数据
    /// - Parameters:
    ///   - url: 视频 URL
    ///   - length: 期望已缓存的最小字节数
    /// - Returns: 是否已满足预加载字节要求
    public func hasCachedData(for url: URL, minimumLength length: Int) -> Bool {
        guard length > 0 else { return true }
        let cacheState = getCacheState(for: url)
        return cacheState.cached >= Int64(length)
    }

    // MARK: - Preloading

    /// 预加载视频
    /// - Parameter url: 视频 URL
    /// - Parameter length: 预加载长度 (默认 2MB)
    @discardableResult
    public func preload(url: URL, length: Int = 2 * 1024 * 1024) -> Bool {
        if isURLInBlacklist(url) {
            AppLog.cache.debug("URL is in blacklist, skip preloading: \(url.lastPathComponent)")
            return false
        }

        guard start() else {
            AppLog.cache.warning("Proxy unavailable, skip preloading: \(url.lastPathComponent)")
            return false
        }

        let urlString = url.absoluteString
        guard preloadLoaders[urlString] == nil else { return true }

        let rangeHeader = "bytes=0-\(length - 1)"
        let headers = ["Range": rangeHeader]
        let request = KTVHCDataRequest(url: url, headers: headers)

        guard let loader = KTVHTTPCache.cacheLoader(with: request) else {
            AppLog.cache.warning("Preload loader creation failed: \(url.lastPathComponent)")
            return false
        }
        loader.delegate = self
        loader.prepare()
        preloadLoaders[urlString] = loader
        AppLog.cache.debug("Start preloading: \(url.lastPathComponent)")
        return true
    }

    /// 取消预加载
    public func cancelPreload(for url: URL) {
        let urlString = url.absoluteString
        if let loader = preloadLoaders.removeValue(forKey: urlString) {
            loader.close()
            AppLog.cache.debug("Cancel preloading: \(url.lastPathComponent)")
        }
    }

    /// 取消所有预加载
    public func cancelAllPreloads() {
        for loader in preloadLoaders.values {
            loader.close()
        }
        preloadLoaders.removeAll()
    }
}

// MARK: - KTVHCDataLoaderDelegate

/// KTVHCDataLoaderDelegate 回调可能来自后台线程，
/// 统一通过 MainActor.run 调度到主线程处理可变状态
extension VideoCacheManager: KTVHCDataLoaderDelegate {
    public func ktv_loaderDidFinish(_ loader: KTVHCDataLoader) {
        guard let url = loader.request.url else { return }
        Task { @MainActor in
            AppLog.cache.info("Preload finished: \(url.lastPathComponent)")
            preloadLoaders.removeValue(forKey: url.absoluteString)
            delegate?.videoCacheManager(self, didFinishPreloadFor: url)
            let userInfo: [AnyHashable: Any] = ["url": url]
            NotificationCenter.default.post(name: .videoCacheManagerPreloadFinished, object: self, userInfo: userInfo)
        }
    }

    public func ktv_loader(_ loader: KTVHCDataLoader, didFailWithError error: Error) {
        guard let url = loader.request.url else { return }
        Task { @MainActor in
            AppLog.cache.error("Preload failed: \(url.lastPathComponent), error: \(error.localizedDescription)")
            preloadLoaders.removeValue(forKey: url.absoluteString)
            if isAutoBlacklistEnabled {
                autoBlacklistedURLs.insert(url)
                autoBlacklistTimestamps[url] = Date()
            }
            delegate?.videoCacheManager(self, didFailPreloadFor: url, error: error)
            let userInfo: [AnyHashable: Any] = ["url": url, "error": error]
            NotificationCenter.default.post(name: .videoCacheManagerPreloadFailed, object: self, userInfo: userInfo)
        }
    }

    public func ktv_loader(_ loader: KTVHCDataLoader, didChangeProgress progress: Double) {
        guard let url = loader.request.url else { return }
        Task { @MainActor in
            delegate?.videoCacheManager(self, didUpdatePreloadProgress: progress, for: url)
            let userInfo: [AnyHashable: Any] = ["url": url, "progress": progress]
            NotificationCenter.default.post(name: .videoCacheManagerPreloadProgress, object: self, userInfo: userInfo)
        }
    }
}
