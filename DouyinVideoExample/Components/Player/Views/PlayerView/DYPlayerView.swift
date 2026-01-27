import UIKit
import AVFoundation

/// 封装 AVPlayerLayer 的视图
/// 使用 layerClass 将底层 Layer 指定为 AVPlayerLayer
/// 从而利用系统机制自动管理 Layer 的 Frame 和动画行为
public class DYPlayerView: UIView {
    
    public override class var layerClass: AnyClass {
        return AVPlayerLayer.self
    }
    
    public var playerLayer: AVPlayerLayer {
        return layer as! AVPlayerLayer
    }
    
    public var player: AVPlayer? {
        get { return playerLayer.player }
        set { playerLayer.player = newValue }
    }
    
    public var videoGravity: AVLayerVideoGravity {
        get { return playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black // 默认黑色背景
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
    }
}
