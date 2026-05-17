/// @file PlaybackRetryHandler.swift
/// @brief 播放重试策略处理器 — 封装播放失败时的重试逻辑，支持最大重试次数和指数退避
/// @author jscn-app
/// @date 2025-05-14
import Foundation
import os.log

/// 播放失败时将 URL 加入缓存黑名单的能力（由 `VideoCacheManager` 实现，便于测试注入 mock）。
/// 标注 @MainActor 与 VideoCacheManager 的并发模型保持一致
@MainActor
public protocol VideoCacheBlacklisting: AnyObject {
    func addToBlacklist(url: URL)
}

extension VideoCacheManager: VideoCacheBlacklisting {}

/// 播放重试策略处理器
/// 负责封装播放失败时的重试逻辑 (Strategy Pattern)
/// 支持：
/// 1. 代理 URL 降级到原始 URL
/// 2. 原始 URL 重试（最大重试次数限制）
/// 3. 指数退避间隔，避免在 URL 永久失效时无限重试
///
/// 标注 @MainActor 因为持有 @MainActor 隔离的 cache 引用
@MainActor
public class PlaybackRetryHandler {

    /// 最大重试次数（含降级重试）
    public let maxRetryCount: Int

    /// 基础退避间隔（秒），实际间隔 = baseDelay * 2^(retryCount-1)
    public let baseBackoffDelay: TimeInterval

    private let cache: VideoCacheBlacklisting

    /// 当前已重试次数
    private var retryCount: Int = 0

    /// 初始化重试策略处理器
    /// - Parameters:
    ///   - cache: 缓存黑名单服务
    ///   - maxRetryCount: 最大重试次数，默认 2
    ///   - baseBackoffDelay: 基础退避间隔（秒），默认 1.0
    public init(
        cache: VideoCacheBlacklisting,
        maxRetryCount: Int = 2,
        baseBackoffDelay: TimeInterval = 1.0
    ) {
        self.cache = cache
        self.maxRetryCount = maxRetryCount
        self.baseBackoffDelay = baseBackoffDelay
    }

    /// 检查是否需要重试，并返回重试策略
    /// - Parameters:
    ///   - error: 播放失败的错误
    ///   - currentURL: 当前播放失败的 URL
    ///   - originalURL: 视频原始 URL
    /// - Returns: 如果需要重试，返回重试使用的 URL；否则返回 nil
    public func shouldRetry(for error: Error?, currentURL: URL, originalURL: URL) -> URL? {
        guard retryCount < maxRetryCount else {
            AppLog.retry.warning("Max retry count (\(self.maxRetryCount)) reached, giving up for: \(originalURL)")
            reset()
            return nil
        }

        retryCount += 1
        let backoffDelay = baseBackoffDelay * pow(2.0, Double(retryCount - 1))

        if currentURL != originalURL {
            AppLog.retry.warning("Retry \(self.retryCount)/\(self.maxRetryCount): Proxy URL failed, downgrading to original: \(originalURL), backoff: \(backoffDelay)s")
            cache.addToBlacklist(url: originalURL)
            return originalURL
        }

        AppLog.retry.info("Retry \(self.retryCount)/\(self.maxRetryCount): Retrying original URL: \(originalURL), backoff: \(backoffDelay)s")
        return originalURL
    }

    /// 计算当前重试的退避间隔
    /// - Returns: 退避等待时间（秒）
    public func currentBackoffDelay() -> TimeInterval {
        guard retryCount > 0 else { return 0 }
        return baseBackoffDelay * pow(2.0, Double(retryCount - 1))
    }

    /// 重置重试计数（播放成功或切换视频时调用）
    public func reset() {
        retryCount = 0
    }
}
