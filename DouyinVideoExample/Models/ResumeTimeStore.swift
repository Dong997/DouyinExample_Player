import Foundation

/// 播放恢复时间存储
/// 将 resumeTime 从 VideoModel 中独立出来，实现数据模型与播放状态的分离：
/// 1. VideoModel 保持纯数据、不可变，不再承载可变播放状态
/// 2. PlayerCoordinator 直接读写 store，消除通知传递链路
/// 3. 使用视频唯一 ID（VideoModel.id）为 key，列表插入/删除/排序后仍能正确恢复
@MainActor
class ResumeTimeStore {

    /// 存储表，key 为视频唯一标识（VideoModel.id），value 为恢复时间（秒）
    private var store: [String: Double] = [:]

    nonisolated init() {}

    /// 更新指定视频的恢复时间
    /// - Parameters:
    ///   - videoID: 视频唯一标识
    ///   - time: 恢复播放时间（秒）
    func update(videoID: String, time: Double) {
        guard time > 0 else { return }
        store[videoID] = time
    }

    /// 获取指定视频的恢复时间
    /// - Parameter videoID: 视频唯一标识
    /// - Returns: 恢复时间（秒），未记录时返回 0
    func resumeTime(for videoID: String) -> Double {
        return store[videoID] ?? 0
    }

    /// 移除指定视频的恢复时间记录
    /// - Parameter videoID: 视频唯一标识
    func remove(for videoID: String) {
        store.removeValue(forKey: videoID)
    }

    /// 清除所有恢复时间记录
    func clearAll() {
        store.removeAll()
    }
}
