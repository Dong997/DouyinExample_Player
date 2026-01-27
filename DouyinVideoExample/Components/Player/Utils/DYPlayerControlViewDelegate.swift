import UIKit

/// 播放器控制视图代理，负责向外暴露进度拖拽、播放控制等交互事件
public protocol DYPlayerControlViewDelegate: AnyObject {
    /// 进度条拖拽开始
    func controlViewDidBeginDragging(_ controlView: DYPlayerControlView)
    /// 用户 Seek 视频进度
    func controlView(_ controlView: DYPlayerControlView, didSeekTo time: Double, isPrecise: Bool)
    /// 进度条值改变
    func controlView(_ controlView: DYPlayerControlView, didChangeValue value: Double)
    /// 点击暂停/播放按钮
    func controlViewDidTapPlayPause(_ controlView: DYPlayerControlView)
    /// 点击全屏观看
    func controlViewDidTapFullscreen(_ controlView: DYPlayerControlView)
    /// 长按开始加速播放
    func controlViewDidBeginFastPlay(_ controlView: DYPlayerControlView)
    /// 长按结束加速播放
    func controlViewDidEndFastPlay(_ controlView: DYPlayerControlView)
}

/// 提供可选实现的默认空实现，使调用方只需实现关心的方法
public extension DYPlayerControlViewDelegate {
    /// 默认空实现：进度条拖拽开始
    func controlViewDidBeginDragging(_ controlView: DYPlayerControlView) {}
    /// 默认空实现：用户 Seek 视频进度
    func controlView(_ controlView: DYPlayerControlView, didSeekTo time: Double, isPrecise: Bool) {}
    /// 默认空实现：进度条拖拽过程中的值变化
    func controlView(_ controlView: DYPlayerControlView, didChangeValue value: Double) {}
    /// 默认空实现：点击全屏观看按钮
    func controlViewDidTapFullscreen(_ controlView: DYPlayerControlView) {}
    /// 默认空实现：长按开始倍速播放
    func controlViewDidBeginFastPlay(_ controlView: DYPlayerControlView) {}
    /// 默认空实现：长按结束恢复正常播放
    func controlViewDidEndFastPlay(_ controlView: DYPlayerControlView) {}
}
