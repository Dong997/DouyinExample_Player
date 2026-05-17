import UIKit

/// 播放编排边界：列表（Home）持有实现并向下注入，详情 / 全屏只依赖协议，不读全局单例。
@MainActor
public protocol DYPlaybackCoordinating: AnyObject {
    /// 当前作为主 UI 绑定的播放器实例（与 `DYPlayerPool` 中的 current 一致）。
    var currentPlayer: DYVideoPlayer { get }
    var preloadPercentage: Double { get set }

    func acquirePreloadPlayer() -> DYVideoPlayer?
    func promoteToCurrent(_ player: DYVideoPlayer)

    func play(url: URL, in view: UIView, seekTo: TimeInterval?)
    func playWithCache(originalURL: URL, in view: UIView, seekTo: TimeInterval?, use targetPlayer: DYVideoPlayer?)
    func preload(originalURL: URL, use targetPlayer: DYVideoPlayer)
    func pause()
    func resume()
    func stop()
    func seek(to time: TimeInterval, isPrecise: Bool, completion: ((Bool) -> Void)?)
}

extension DYPlayerManager: DYPlaybackCoordinating {
    public var currentPlayer: DYVideoPlayer { player }
}

/// 对外统一入口：组合「对象池」与「播放 / 缓存服务」。
///
/// **线程契约**：须在主线程使用（`@MainActor`）。新代码可直接使用 `DYPlayerPool.shared` 与 `DYPlaybackService.shared`。
@MainActor
public final class DYPlayerManager {

    public static let shared = DYPlayerManager()

    private let pool = DYPlayerPool.shared
    private let playback = DYPlaybackService.shared

    public var player: DYVideoPlayer {
        pool.player
    }

    public var preloadPercentage: Double {
        get { playback.preloadPercentage }
        set { playback.preloadPercentage = newValue }
    }

    private init() {}

    // MARK: - Pool

    /// 若返回 `nil`，表示没有独立预加载槽位，仅适合跳过预加载；若要立刻播放入口请使用 `player` 或 `acquirePreloadPlayer() ?? player`。
    public func acquirePreloadPlayer() -> DYVideoPlayer? {
        pool.acquirePreloadPlayer()
    }

    public func promoteToCurrent(_ player: DYVideoPlayer) {
        pool.promoteToCurrent(player)
    }

    // MARK: - Playback

    public func play(url: URL, in view: UIView, seekTo: TimeInterval? = nil) {
        playback.play(url: url, in: view, seekTo: seekTo)
    }

    public func playWithCache(
        originalURL: URL,
        in view: UIView,
        seekTo: TimeInterval? = nil,
        use targetPlayer: DYVideoPlayer? = nil
    ) {
        playback.playWithCache(originalURL: originalURL, in: view, seekTo: seekTo, use: targetPlayer)
    }

    /// 使用指定播放器实例对资源做 `prepare`（会走缓存代理）。列表邻条预取应优先用 `VideoPreloadManager` + `VideoCacheManager.preload`，避免与 HTTP Range 预拉重复；本方法保留给需要「播放器已就绪」的场景。
    public func preload(originalURL: URL, use targetPlayer: DYVideoPlayer) {
        playback.preload(originalURL: originalURL, use: targetPlayer)
    }

    public func pause() {
        playback.pause()
    }

    public func resume() {
        playback.resume()
    }

    public func stop() {
        playback.stop()
    }

    public func seek(to time: TimeInterval, isPrecise: Bool = true, completion: ((Bool) -> Void)? = nil) {
        playback.seek(to: time, isPrecise: isPrecise, completion: completion)
    }
}
