import Foundation
import KTVHTTPCache

/// 视频缓存管理器 - 基于 KTVHTTPCache 封装
/// 负责视频资源的缓存、预加载、代理URL生成等
public class VideoCacheManager: NSObject {
    
    public static let shared = VideoCacheManager()
    
    // 用于持有预加载的 loader，防止被释放
    // Key: URL absolute string
    private var preloadLoaders: [String: KTVHCDataLoader] = [:]
    
    // 记录预加载/缓存失败的 URL，遇到这些 URL 时降级使用原始 URL 播放
    private var blacklistedURLs: Set<URL> = []
    
    private override init() {
        super.init()
        setupConfiguration()
    }
    
    // MARK: - Blacklist Management
    
    /// 手动将 URL 加入黑名单 (通常用于播放器报错时)
    public func addToBlacklist(url: URL) {
        blacklistedURLs.insert(url)
        print("[VideoCacheManager] URL added to blacklist manually: \(url.lastPathComponent)")
    }
    
    // MARK: - Configuration
    
    /// 初始化配置
    private func setupConfiguration() {
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
            "binary/octet-stream"
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
        // 1. 如果该 URL 在黑名单中（之前报错过），直接返回原始 URL
        if blacklistedURLs.contains(originalURL) {
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
        }
    }
    
    public func ktv_loader(_ loader: KTVHCDataLoader, didFailWithError error: Error) {
        if let url = loader.request.url {
            print("[VideoCacheManager] Preload failed: \(url.lastPathComponent), error: \(error.localizedDescription)")
            preloadLoaders.removeValue(forKey: url.absoluteString)
            
            // 记录失败的 URL
            blacklistedURLs.insert(url)
        }
    }
    
    public func ktv_loader(_ loader: KTVHCDataLoader, didChangeProgress progress: Double) {
        // 可以在这里广播进度，如果需要的话
    }
}
