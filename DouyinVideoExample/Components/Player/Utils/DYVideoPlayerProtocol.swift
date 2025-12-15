import Foundation
import AVFoundation
import UIKit

// MARK: - Player State
/// 播放器状态枚举
public enum DYPlayerState: Equatable {
    case idle           // 闲置/未初始化
    case preparing      // 准备中(加载资源)
    case buffering      // 缓冲中
    case playing        // 播放中
    case paused         // 暂停
    case finished       // 播放完成
    case error(String)  // 出错(包含错误信息)
    
    public static func == (lhs: DYPlayerState, rhs: DYPlayerState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.preparing, .preparing),
             (.buffering, .buffering),
             (.playing, .playing),
             (.paused, .paused),
             (.finished, .finished):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Player Delegate Protocol
/// 播放器代理协议 - 所有的回调事件
public protocol DYVideoPlayerDelegate: AnyObject {
    
    /// 播放器状态发生改变
    /// - Parameters:
    ///   - player: 播放器实例
    ///   - state: 新的状态
    func player(_ player: DYVideoPlayer, didChangeState state: DYPlayerState)
    
    /// 播放进度更新 (常用于更新进度条)
    /// - Parameters:
    ///   - player: 播放器实例
    ///   - progress: 播放进度 (0.0 - 1.0)
    ///   - currentTime: 当前播放时间(秒)
    ///   - totalTime: 视频总时长(秒)
    func player(_ player: DYVideoPlayer, didUpdateProgress progress: Double, currentTime: Double, totalTime: Double)
    
    /// 缓冲进度更新
    /// - Parameters:
    ///   - player: 播放器实例
    ///   - progress: 缓冲进度 (0.0 - 1.0)
    func player(_ player: DYVideoPlayer, didUpdateBuffer progress: Double)
    
    /// 播放出错
    /// - Parameters:
    ///   - player: 播放器实例
    ///   - error: 错误对象
    func player(_ player: DYVideoPlayer, didFailWithError error: Error?)
    
    /// 视频播放完成 (如果是循环播放，每次循环结束都会调用)
    func playerDidFinishPlaying(_ player: DYVideoPlayer)
    
    /// 视频尺寸信息回调 (可用于调整UI比例)
    func player(_ player: DYVideoPlayer, didUpdateVideoSize size: CGSize)
}

// MARK: - Optional Implementation
public extension DYVideoPlayerDelegate {
    func player(_ player: DYVideoPlayer, didUpdateProgress progress: Double, currentTime: Double, totalTime: Double) {}
    func player(_ player: DYVideoPlayer, didUpdateBuffer progress: Double) {}
    func player(_ player: DYVideoPlayer, didFailWithError error: Error?) {}
    func playerDidFinishPlaying(_ player: DYVideoPlayer) {}
    func player(_ player: DYVideoPlayer, didUpdateVideoSize size: CGSize) {}
}

// MARK: - Player Interface Protocol
/// 播放器功能接口协议 - 定义播放器必须具备的功能
public protocol DYVideoPlayerInput {
    
    var delegate: DYVideoPlayerDelegate? { get set }
    var isMuted: Bool { get set }
    var volume: Float { get set }
    var isLooping: Bool { get set }
    var state: DYPlayerState { get }
    var duration: Double { get }
    var currentTime: Double { get }
    
    /// 播放指定URL的视频
    /// - Parameters:
    ///   - url: 视频URL
    ///   - view: 承载视频画面的父视图
    ///   - seekTo: 起始播放时间
    func play(url: URL, in view: UIView, seekTo: Double?)
    
    /// 暂停
    func pause()
    
    /// 恢复播放
    func resume()
    
    /// 停止播放
    func stop()
    
    /// 跳转到指定时间
    /// - Parameters:
    ///   - time: 目标时间(秒)
    ///   - completion: 完成回调
    func seek(to time: TimeInterval, completion: ((Bool) -> Void)?)
}

public extension DYVideoPlayerInput {
//    func seek(to time: Double, completion: ((Bool) -> Void)? = nil) {
//        seek(to: time, completion: completion)
//    }
//    
    /// 跳转到指定时间
    /// - Parameter time: 目标时间(秒)
    func seek(to time: TimeInterval, completion: ((Bool) -> Void)? = nil){
        seek(to: time, completion: completion)
    }
}

