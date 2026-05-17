import UIKit

/// 管理 `DYVideoPlayer` 实例的创建、复用与回收（对象池）。
///
/// **线程契约**：所有公开 API 须在主线程调用（`@MainActor`）。
@MainActor
public final class DYPlayerPool {

    public static let shared = DYPlayerPool()

    /// 当前用于 UI 展示的主播放器。
    public var player: DYVideoPlayer {
        currentPlayer
    }

    /// 池中最多保留的播放器实例数量（含当前正在使用的一个）。
    public let maxPoolSize: Int

    private var currentPlayer: DYVideoPlayer
    private var playerPool: [DYVideoPlayer] = []

    public init(maxPoolSize: Int = 3) {
        precondition(maxPoolSize >= 1, "DYPlayerPool maxPoolSize must be >= 1")
        self.maxPoolSize = maxPoolSize
        let initial = DYVideoPlayer()
        initial.isLooping = true
        currentPlayer = initial
        playerPool.append(initial)
    }

    /// 获取一个**与当前主播放器不同实例**的预加载槽位；若池已满且无法安全腾出槽位则返回 `nil`（调用方应跳过预加载或改用 `player` 直接播放当前实例）。
    public func acquirePreloadPlayer() -> DYVideoPlayer? {
        if let idle = playerPool.first(where: {
            $0 !== currentPlayer && ($0.state == .idle || $0.state == .finished || isErrorState($0.state))
        }) {
            idle.reset()
            markAsRecentlyUsed(idle)
            return idle
        }

        if playerPool.count < maxPoolSize {
            let newPlayer = DYVideoPlayer()
            newPlayer.isLooping = true
            playerPool.append(newPlayer)
            return newPlayer
        }

        let candidates = playerPool.filter { $0 !== currentPlayer }

        if let pausedVictim = candidates.first(where: { $0.state == .paused }) {
            pausedVictim.stop()
            pausedVictim.reset()
            markAsRecentlyUsed(pausedVictim)
            return pausedVictim
        }

        if let victim = candidates.first {
            victim.stop()
            victim.reset()
            markAsRecentlyUsed(victim)
            return victim
        }

        // 无法提供与 `currentPlayer` 分离的实例；勿用于「并行预加载另一条 index」。
        return nil
    }

    /// 将配置应用到池内所有播放器实例。
    public func applyConfigurationToAll(_ configuration: DYVideoPlayerConfiguration) {
        playerPool.forEach { $0.applyConfiguration(configuration) }
    }

    /// 将指定播放器提升为当前主播放器；若该实例不在池中则会先**收养**入池（必要时按 LRU 腾出名额）。
    public func promoteToCurrent(_ player: DYVideoPlayer) {
        ensurePooled(player)
        if player !== currentPlayer {
            currentPlayer = player
            markAsRecentlyUsed(player)
        }
    }

    private func ensurePooled(_ player: DYVideoPlayer) {
        guard !playerPool.contains(where: { $0 === player }) else { return }

        while playerPool.count >= maxPoolSize {
            guard let idx = playerPool.firstIndex(where: { $0 !== currentPlayer && $0 !== player }) else {
                #if DEBUG
                assertionFailure("DYPlayerPool: pool at capacity and cannot evict; check maxPoolSize / ownership.")
                #endif
                break
            }
            let victim = playerPool.remove(at: idx)
            victim.stop()
            victim.reset()
        }

        if !playerPool.contains(where: { $0 === player }) {
            playerPool.append(player)
        }
    }

    private func markAsRecentlyUsed(_ player: DYVideoPlayer) {
        if let index = playerPool.firstIndex(of: player) {
            playerPool.remove(at: index)
            playerPool.append(player)
        }
    }

    private func isErrorState(_ state: DYPlayerState) -> Bool {
        if case .error = state { return true }
        return false
    }
}
