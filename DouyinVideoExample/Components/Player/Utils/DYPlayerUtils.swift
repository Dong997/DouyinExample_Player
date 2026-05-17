import Foundation

/// 播放器工具类
/// 提供播放器相关的通用工具方法，避免在多个组件中重复实现
enum DYPlayerUtils {

    /// 将秒数格式化为 mm:ss 形式的字符串
    /// - Parameter seconds: 时间秒数
    /// - Returns: 格式化后的时间字符串，NaN/Infinite 返回 "00:00"
    static func formatTime(seconds: Double) -> String {
        guard !seconds.isNaN, !seconds.isInfinite else { return "00:00" }
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
