import Foundation
import KTVHTTPCache

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
        print("[VideoCacheManager] URL added to blacklist manually: \(url.lastPathComponent)")
    }

    private func isURLInBlacklist(_ url: URL) -> Bool {
        if manualBlacklistedURLs.contains(url) {
            return true
        }
        if isAutoBlacklistEnabled == false {
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
        // 设置缓存限制 (最大 500MB)
        KTVHTTPCache.cacheSetMaxCacheLength(500 * 1024 * 1024)
        
        // 设置超时时间
        KTVHTTPCache.downloadSetTimeoutInterval(30)
        
        // 添加更多 Content-Type 支持
        // 默认只支持部分类型，如果遇到 -192704 错误，通常是因为 Content-Type 不匹配
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
        
        // 设置未被接受的 Content-Type 处理器，允许所有类型通过 (作为兜底)
        // 注意：这可能会导致缓存一些非媒体文件，生产环境建议严格控制
        KTVHTTPCache.downloadSetUnacceptableContentTypeDisposer { url, contentType in
            print("[VideoCacheManager] Warning: Unacceptable Content-Type: \(contentType ?? "nil") for URL: \(url?.lastPathComponent ?? "nil")")
            return true // 返回 true 表示强制接受
        }
    }
    
    /// 启动本地代理服务
    /// 建议在 App 启动时调用
    public func start() {
        do {
            try KTVHTTPCache.proxyStart()
            print("[VideoCacheManager] Proxy started successfully")
        } catch {
            print("[VideoCacheManager] Proxy start failed: \(error)")
        }
        
    }
    
    // MARK: - URL Handling
    
    /// 获取代理 URL
    /// - Parameter originalURL: 原始视频 URL
    /// - Returns: 代理后的 URL，如果生成失败返回原始 URL
    public func getProxyURL(for originalURL: URL) -> URL {
        if isURLInBlacklist(originalURL) {
            print("[VideoCacheManager] URL is in blacklist, using original URL: \(originalURL.lastPathComponent)")
            return originalURL
        }
        
        // 2. 如果代理服务没有运行，尝试启动
        if !KTVHTTPCache.proxyIsRunning() {
            start()
        }
        
        // 3. 生成代理 URL
        guard let proxyURL = KTVHTTPCache.proxyURL(withOriginalURL: originalURL) else {
            return originalURL
        }
        
        return proxyURL
    }
    
    // MARK: - Cache Management
    
    /// 获取当前缓存总大小 (字节)
    public func calculateCacheSize() -> Int64 {
        return KTVHTTPCache.cacheTotalCacheLength()
    }
    
    /// 清除所有缓存
    public func clearAllCache() {
        KTVHTTPCache.cacheDeleteAllCaches()
        print("[VideoCacheManager] All caches deleted")
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
    
    // MARK: - Preloading
    
    /// 预加载视频
    /// - Parameter url: 视频 URL
    /// - Parameter length: 预加载长度 (默认 2MB)
    public func preload(url: URL, length: Int = 2 * 1024 * 1024) {
        if isURLInBlacklist(url) {
            print("[VideoCacheManager] URL is in blacklist, skip preloading: \(url.lastPathComponent)")
            return
        }
        
        guard KTVHTTPCache.proxyIsRunning() else { return }
        
        let urlString = url.absoluteString
        
        // 如果已经在预加载，则忽略
        if preloadLoaders[urlString] != nil {
            return
        }
        
        // 构造带 Range 的请求头，控制预加载大小
        let rangeHeader = "bytes=0-\(length - 1)"
        let headers = ["Range": rangeHeader]
        let request = KTVHCDataRequest(url: url, headers: headers)
        
        guard let loader = KTVHTTPCache.cacheLoader(with: request) else {
            return
        }
        
        loader.delegate = self
        loader.prepare()
        
        preloadLoaders[urlString] = loader
        print("[VideoCacheManager] Start preloading: \(url.lastPathComponent)")
    }
    
    /// 取消预加载
    public func cancelPreload(for url: URL) {
        let urlString = url.absoluteString
        if let loader = preloadLoaders[urlString] {
            loader.close()
            preloadLoaders.removeValue(forKey: urlString)
            print("[VideoCacheManager] Cancel preloading: \(url.lastPathComponent)")
        }
    }
    
    /// 取消所有预加载
    public func cancelAllPreloads() {
        for (_, loader) in preloadLoaders {
            loader.close()
        }
        preloadLoaders.removeAll()
    }
}

// MARK: - KTVHCDataLoaderDelegate
extension VideoCacheManager: KTVHCDataLoaderDelegate {
    public func ktv_loaderDidFinish(_ loader: KTVHCDataLoader) {
        if let url = loader.request.url {
            print("[VideoCacheManager] Preload finished: \(url.lastPathComponent)")
            preloadLoaders.removeValue(forKey: url.absoluteString)
            delegate?.videoCacheManager(self, didFinishPreloadFor: url)
            let userInfo: [AnyHashable: Any] = ["url": url]
            NotificationCenter.default.post(name: .videoCacheManagerPreloadFinished, object: self, userInfo: userInfo)
        }
    }
    
    public func ktv_loader(_ loader: KTVHCDataLoader, didFailWithError error: Error) {
        if let url = loader.request.url {
            print("[VideoCacheManager] Preload failed: \(url.lastPathComponent), error: \(error.localizedDescription)")
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
        if let url = loader.request.url {
            delegate?.videoCacheManager(self, didUpdatePreloadProgress: progress, for: url)
            let userInfo: [AnyHashable: Any] = ["url": url, "progress": progress]
            NotificationCenter.default.post(name: .videoCacheManagerPreloadProgress, object: self, userInfo: userInfo)
        }
    }
}
