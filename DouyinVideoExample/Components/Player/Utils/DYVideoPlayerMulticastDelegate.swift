import Foundation
import UIKit

/// 播放器多播委托中心
/// 替代单一 delegate 模式，允许多个订阅者同时接收播放器事件
/// 订阅者以弱引用持有，不会造成循环引用
/// 线程安全：所有操作在主线程执行
public class DYVideoPlayerMulticastDelegate: DYVideoPlayerDelegate {

    /// 弱引用订阅者包装，避免循环引用
    private class WeakWrapper {
        weak var subscriber: AnyObject?
        init(_ subscriber: AnyObject) {
            self.subscriber = subscriber
        }
    }

    /// 订阅者列表（有序，先添加的先收到回调）
    private var wrappers: [WeakWrapper] = []

    public init() {}

    // MARK: - Subscribe / Unsubscribe

    /// 添加订阅者
    /// 如果该订阅者已存在，不会重复添加
    /// - Parameter subscriber: 遵循 DYVideoPlayerDelegate 的订阅者
    public func add(_ subscriber: DYVideoPlayerDelegate) {
        purgeDeallocated()
        guard !contains(subscriber) else { return }
        wrappers.append(WeakWrapper(subscriber))
    }

    /// 移除订阅者
    /// - Parameter subscriber: 要移除的订阅者
    public func remove(_ subscriber: DYVideoPlayerDelegate) {
        wrappers.removeAll { $0.subscriber === subscriber }
    }

    /// 移除所有订阅者
    public func removeAll() {
        wrappers.removeAll()
    }

    // MARK: - DYVideoPlayerDelegate

    public func player(_ player: DYVideoPlayerSession, didChangeState state: DYPlayerState) {
        forEach { $0.player(player, didChangeState: state) }
    }

    public func player(_ player: DYVideoPlayerSession, didUpdateProgress progress: Double, currentTime: Double, totalTime: Double) {
        forEach { $0.player(player, didUpdateProgress: progress, currentTime: currentTime, totalTime: totalTime) }
    }

    public func player(_ player: DYVideoPlayerSession, didUpdateBuffer progress: Double) {
        forEach { $0.player(player, didUpdateBuffer: progress) }
    }

    public func player(_ player: DYVideoPlayerSession, didFailWithError error: Error?) {
        forEach { $0.player(player, didFailWithError: error) }
    }

    public func playerDidFinishPlaying(_ player: DYVideoPlayerSession) {
        forEach { $0.playerDidFinishPlaying(player) }
    }

    public func player(_ player: DYVideoPlayerSession, didUpdateVideoSize size: CGSize) {
        forEach { $0.player(player, didUpdateVideoSize: size) }
    }

    public func playerReadyForDisplay(_ player: DYVideoPlayerSession) {
        forEach { $0.playerReadyForDisplay(player) }
    }

    public func player(_ player: DYVideoPlayerSession, didChangeContainerFrom oldContainer: UIView?, to newContainer: UIView?) {
        forEach { $0.player(player, didChangeContainerFrom: oldContainer, to: newContainer) }
    }

    // MARK: - Private

    /// 遍历所有存活的订阅者并执行闭包
    private func forEach(_ body: (DYVideoPlayerDelegate) -> Void) {
        purgeDeallocated()
        for wrapper in wrappers {
            if let subscriber = wrapper.subscriber as? DYVideoPlayerDelegate {
                body(subscriber)
            }
        }
    }

    /// 检查是否已包含指定订阅者
    private func contains(_ subscriber: AnyObject) -> Bool {
        return wrappers.contains { $0.subscriber === subscriber }
    }

    /// 清理已被释放的弱引用包装
    private func purgeDeallocated() {
        wrappers.removeAll { $0.subscriber == nil }
    }
}
