/// @file AppLog.swift
/// @brief 统一日志工具 — 基于 OSLog 封装，按 subsystem/category 分类，Release 构建自动降级
/// @author jscn-app
/// @date 2025-05-13
import os.log

/// 应用统一日志入口
/// 基于 OSLog 封装，提供按模块分类的日志输出
///
/// 特性：
/// - 按 subsystem + category 分类，便于 Console.app 过滤
/// - Release 构建中 .debug 级别自动降级（OSLog 内置行为）
/// - 提供便捷的模块级 Logger 访问
///
/// 使用示例：
/// ```swift
/// AppLog.cache.info("Preload finished: \(url.lastPathComponent)")
/// AppLog.player.error("Playback failed: \(error.localizedDescription)")
/// AppLog.cache.debug("Cache hit for: \(url)")
/// ```
public enum AppLog {

    /// 应用 subsystem 标识
    private static let subsystem = "com.douyin.video"

    /// 缓存模块日志
    public static let cache = Logger(subsystem: subsystem, category: "Cache")

    /// 播放器模块日志
    public static let player = Logger(subsystem: subsystem, category: "Player")

    /// 预加载模块日志
    public static let preload = Logger(subsystem: subsystem, category: "Preload")

    /// 重试策略模块日志
    public static let retry = Logger(subsystem: subsystem, category: "Retry")

    /// 应用生命周期日志
    public static let app = Logger(subsystem: subsystem, category: "App")

    /// UI 模块日志
    public static let ui = Logger(subsystem: subsystem, category: "UI")

    /// 网络模块日志
    public static let network = Logger(subsystem: subsystem, category: "Network")

    /// 临时闪烁问题排查日志
    public static let flicker = Logger(subsystem: subsystem, category: "FlickerTrace")
}
