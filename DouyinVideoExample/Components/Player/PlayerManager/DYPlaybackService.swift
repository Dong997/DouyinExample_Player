import UIKit

/// 播放控制与缓存代理（通过 `VideoCacheManager` 走代理 URL）。
///
/// **线程契约**：所有公开 API 须在主线程调用（`@MainActor`）。
@MainActor
public final class DYPlaybackService {

    public static let shared = DYPlaybackService(pool: .shared)

    private let pool: DYPlayerPool

    /// 全局播放器配置。所有通过 Service 发起的播放和预加载都会先应用该配置。
    public var configuration: DYVideoPlayerConfiguration {
        get { _configuration }
        set {
            _configuration = newValue.normalized()
            player.applyConfiguration(_configuration)
        }
    }

    /// 前向缓冲占整条视频时长的比例（0~1），在 `DYVideoPlayer` 就绪后映射为 `AVPlayerItem.preferredForwardBufferDuration`。
    public var preloadPercentage: Double {
        get { _configuration.preferredForwardBufferFraction ?? 0 }
        set {
            var updated = _configuration
            updated.preferredForwardBufferFraction = Self.clampFraction(newValue)
            configuration = updated
        }
    }

    private var _configuration = DYVideoPlayerConfiguration(preferredForwardBufferFraction: 0.10)

    public init(pool: DYPlayerPool) {
        self.pool = pool
    }

    public var player: DYVideoPlayer {
        pool.player
    }

    public func configure(_ player: DYVideoPlayer) {
        player.applyConfiguration(configuration)
    }

    public func play(url: URL, in view: UIView, seekTo: TimeInterval? = nil) {
        let p = pool.player
        configure(p)
        AppLog.player.info("PlaybackService play direct url=\(url.absoluteString), seek=\(String(describing: seekTo)), playerState=\(String(describing: p.state))")
        p.play(url: url, in: view, seekTo: seekTo)
    }

    public func playWithCache(
        originalURL: URL,
        in view: UIView,
        seekTo: TimeInterval? = nil,
        use targetPlayer: DYVideoPlayer? = nil
    ) {
        let p = targetPlayer ?? player
        configure(p)
        let proxyURL = VideoCacheManager.shared.getProxyURL(for: originalURL)
        AppLog.player.info("PlaybackService playWithCache original=\(originalURL.absoluteString), resolved=\(proxyURL.absoluteString), isProxy=\(proxyURL != originalURL), seek=\(String(describing: seekTo)), playerState=\(String(describing: p.state))")
        p.play(url: proxyURL, originalURL: originalURL, in: view, seekTo: seekTo)
    }

    public func preload(originalURL: URL, use targetPlayer: DYVideoPlayer) {
        configure(targetPlayer)
        let proxyURL = VideoCacheManager.shared.getProxyURL(for: originalURL)
        AppLog.player.info("PlaybackService preload original=\(originalURL.absoluteString), resolved=\(proxyURL.absoluteString), isProxy=\(proxyURL != originalURL), playerState=\(String(describing: targetPlayer.state))")
        targetPlayer.prepare(url: proxyURL, originalURL: originalURL)
    }

    public func pause() {
        player.pause()
    }

    public func resume() {
        player.resume()
    }

    public func stop() {
        player.stop()
    }

    public func seek(to time: TimeInterval, isPrecise: Bool = true, completion: ((Bool) -> Void)? = nil) {
        player.seek(to: time, isPrecise: isPrecise, completion: completion)
    }

    private static func clampFraction(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
