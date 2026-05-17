import Foundation
import AVFoundation
import UIKit

// MARK: - Player State
/// 播放器状态枚举
public enum DYPlayerState: Equatable {
    case idle
    case preparing
    case buffering
    case playing
    case paused
    case finished
    case error(String)
}

public extension DYPlayerState {
    var isError: Bool {
        if case .error = self {
            return true
        }
        return false
    }
}

/// 视频画面填充模式
/// 与系统 AVLayerVideoGravity 保持一一对应关系
public enum DYVideoGravity {
    /// 等比缩放，全部内容可见，可能留黑边
    case aspectFit
    /// 等比填充，铺满视图，可能裁剪部分内容
    case aspectFill
    /// 拉伸填充，不保证比例
    case resize
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
    
    func player(_ player: DYVideoPlayer, didChangeContainerFrom oldContainer: UIView?, to newContainer: UIView?)
}

// MARK: - Optional Implementation
public extension DYVideoPlayerDelegate {
    func player(_ player: DYVideoPlayer, didUpdateProgress progress: Double, currentTime: Double, totalTime: Double) {}
    func player(_ player: DYVideoPlayer, didUpdateBuffer progress: Double) {}
    func player(_ player: DYVideoPlayer, didFailWithError error: Error?) {}
    func playerDidFinishPlaying(_ player: DYVideoPlayer) {}
    func player(_ player: DYVideoPlayer, didUpdateVideoSize size: CGSize) {}
    func player(_ player: DYVideoPlayer, didChangeContainerFrom oldContainer: UIView?, to newContainer: UIView?) {}
}

// MARK: - Player Interface Protocol
/// 播放器功能接口协议 - 定义播放器必须具备的功能
public protocol DYVideoPlayerInput {
    
    var delegate: DYVideoPlayerDelegate? { get set }
    /// 多播委托中心，允许多个订阅者同时接收播放器事件
    var multicastDelegate: DYVideoPlayerMulticastDelegate { get }
    var isMuted: Bool { get set }
    var volume: Float { get set }
    var isLooping: Bool { get set }
    var state: DYPlayerState { get }
    var duration: Double { get }
    var currentTime: Double { get }
    
    /// 播放指定URL的视频
    /// - Parameters:
    ///   - url: 视频URL
    ///   - originalURL: 原始视频URL (可选，用于元数据记录或重试逻辑对比)
    ///   - view: 承载视频画面的父视图
    ///   - seekTo: 起始播放时间
    func play(url: URL, originalURL: URL?, in view: UIView, seekTo: TimeInterval?)
    
    /// 暂停播放
    func pause()
    
    /// 恢复播放
    func resume()
    
    /// 停止播放
    func stop()
    
    /// 跳转到指定时间
    /// - Parameters:
    ///   - time: 目标时间(秒)
    ///   - isPrecise: 是否精确跳转 (默认 true)
    ///   - completion: 完成回调
    func seek(to time: TimeInterval, isPrecise: Bool, completion: ((Bool) -> Void)?)
}

public extension DYVideoPlayerInput {
//    func seek(to time: Double, completion: ((Bool) -> Void)? = nil) {
//        seek(to: time, completion: completion)
//    }
//    
    /// 跳转到指定时间
    /// - Parameter time: 目标时间(秒)
    func seek(to time: TimeInterval, completion: ((Bool) -> Void)? = nil){
        seek(to: time, isPrecise: true, completion: completion)
    }
}

/// 播放器高级控制协议
/// 在基础播放能力之上，扩展倍速与画面填充等控制能力
public protocol DYVideoAdvancedControlInput: DYVideoPlayerInput {
    /// 当前播放速度（1.0 为正常速度）
    var playbackRate: Float { get set }
    /// 当前视频画面填充策略
    var videoGravity: DYVideoGravity { get set }
    /// 设置播放速度
    /// - Parameter rate: 目标倍速 (例如 0.5/1.0/2.0)
    func setPlaybackRate(_ rate: Float)
    /// 设置视频画面填充模式
    /// - Parameter gravity: 目标填充模式
    func setVideoGravity(_ gravity: DYVideoGravity)
}

/// 列表 / 详情等场景下需要在不同容器间迁移播放器 UI 时使用的能力。
/// 由 `DYVideoPlayer` 实现，通过初始化参数注入，避免子页面直接访问全局 `DYPlayerManager`。
public protocol DYVideoPlayerSession: DYVideoAdvancedControlInput {
    var containerView: UIView? { get }
    var originalURL: URL? { get }
    var currentURL: URL? { get }
    func updateContainer(_ view: UIView)
    func isPlaying(url: URL) -> Bool
}

extension DYVideoPlayer: DYVideoPlayerSession {}
