import UIKit
import SnapKit

/// 播放器控制视图代理
public protocol DYPlayerControlViewDelegate: AnyObject {
    /// 进度条拖拽开始
    func controlViewDidBeginDragging(_ controlView: DYPlayerControlView)
    /// 进度条拖拽结束
    func controlView(_ controlView: DYPlayerControlView, didEndDragging value: Double)
    /// 进度条值改变
    func controlView(_ controlView: DYPlayerControlView, didChangeValue value: Double)
    /// 点击暂停/播放按钮
    func controlViewDidTapPlayPause(_ controlView: DYPlayerControlView)
    /// 点击全屏观看
    func controlViewDidTapFullscreen(_ controlView: DYPlayerControlView)
}

public extension DYPlayerControlViewDelegate {
    func controlViewDidBeginDragging(_ controlView: DYPlayerControlView) {}
    func controlView(_ controlView: DYPlayerControlView, didChangeValue value: Double) {}
    func controlViewDidTapFullscreen(_ controlView: DYPlayerControlView) {}
}

/// 播放器控制视图 (进度条、暂停按钮等)
public class DYPlayerControlView: UIView {
    
    // MARK: - Properties
    
    public weak var delegate: DYPlayerControlViewDelegate?
    
    private var isDragging: Bool = false
    private var isLoading: Bool = false
    public enum DYControlPlayState { case preparing, playing, notPlaying, error }
    private var currentState: DYControlPlayState = .notPlaying
    private var isFastPlaying: Bool = false
    private var aspectRatio: Double?
    private var isFullscreenButtonEnabled: Bool = false
    private lazy var speedTipView: ShortPlayerSpeedTipView = {
        let tipView = ShortPlayerSpeedTipView()
        return tipView
    }()
    private lazy var fullscreenButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("全屏观看", for: .normal)
        button.tintColor = .white
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        button.layer.cornerRadius = 22
        button.isHidden = true
        button.addTarget(self, action: #selector(fullscreenTapped), for: .touchUpInside)
        return button
    }()
    
    // MARK: - UI Components
    
    /// 底部控制栏容器
    private lazy var bottomContainerView: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        return view
    }()
    
    /// 浮动时间标签 (拖拽时显示)
    private lazy var floatingTimeLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 24, weight: .semibold)
        label.textAlignment = .center
        label.alpha = 0 // 默认隐藏
        // 添加阴影增加可读性
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
        label.layer.shadowOpacity = 0.5
        label.layer.shadowRadius = 2
        return label
    }()
    
    /// 进度条
    private lazy var progressBar: VideoProgressBar = {
        let bar = VideoProgressBar()
        bar.progressColor = .white
        bar.bufferColor = UIColor.white.withAlphaComponent(0.5)
        bar.trackColor = UIColor.white.withAlphaComponent(0.2)
        
        // 绑定回调
        bar.didBeginDragging = { [weak self] in
            guard let self = self else { return }
            self.isDragging = true
            self.showFloatingTime(true)
            self.delegate?.controlViewDidBeginDragging(self)
        }
        
        bar.didChangeProgress = { [weak self] progress in
            guard let self = self else { return }
            self.delegate?.controlView(self, didChangeValue: Double(progress))
        }
        
        bar.didEndDragging = { [weak self] progress in
            guard let self = self else { return }
            self.isDragging = false
            self.showFloatingTime(false)
            self.delegate?.controlView(self, didEndDragging: Double(progress))
        }
        
        return bar
    }()
    
    /// 屏幕中央的播放图标 (暂停时显示)
    private lazy var centerPlayIcon: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "play.fill"))
        imageView.contentMode = .scaleAspectFit
        imageView.isHidden = true
        imageView.tintColor = UIColor.white.withAlphaComponent(0.8)
        imageView.isHidden = true // 默认隐藏
        return imageView
    }()
    
    // MARK: - Initialization
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - UI Setup
    
    private func setupUI() {
        addSubview(bottomContainerView)
        addSubview(centerPlayIcon)
        addSubview(floatingTimeLabel)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.3
        addGestureRecognizer(longPress)
        addSubview(errorOverlayView)
        addSubview(speedTipView)
        addSubview(fullscreenButton)
        bringSubviewToFront(fullscreenButton)
        
        bottomContainerView.addSubview(progressBar)
        
        // Center Play Icon - 居中显示
        centerPlayIcon.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.size.equalTo(CGSize(width: 60, height: 60))
        }
        fullscreenButton.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(bottomContainerView.snp.top).offset(-56)
            make.size.equalTo(CGSize(width: 160, height: 44))
        }
        
        // Floating Time Label - 进度条上方显示
        floatingTimeLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(progressBar.snp.top).offset(-40)
        }
        
        // Bottom Container - 底部布局
        bottomContainerView.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.height.equalTo(60) // 高度
        }
        
        // ProgressBar - 进度条 (全宽，带内边距)
        progressBar.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(15)
            make.bottom.equalToSuperview().offset(-2)
            make.height.equalTo(2) // 进度条高度
        }
        errorOverlayView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        speedTipView.snp.makeConstraints { make in
            make.size.equalTo(CGSize(width: ShortPlayerSpeedTipView.viewWidth, height: ShortPlayerSpeedTipView.viewHeight))
            make.centerX.equalToSuperview()
            make.bottom.equalTo(progressBar.snp.top).offset(-20)
        }
    }
    
    // MARK: - Actions
    
    @objc private func playPauseTapped() {
        delegate?.controlViewDidTapPlayPause(self)
    }
    
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let player = DYPlayerManager.shared.player
        switch gesture.state {
        case .began, .changed:
            if !isFastPlaying {
                if player.state != .playing {
                    player.resume()
                }
                player.setPlaybackRate(2.0)
                isFastPlaying = true
            }
            speedTipView.showSpeedView(tip: "2倍速")
        case .ended, .cancelled, .failed:
            player.setPlaybackRate(1.0)
            isFastPlaying = false
            speedTipView.hideSpeedView()
        default:
            break
        }
    }

    @objc private func fullscreenTapped() {
        delegate?.controlViewDidTapFullscreen(self)
    }
    
    // MARK: - Public Methods
    
    /// 更新播放播放按钮状态 (UI)
    /// - Parameter isPlaying: 是否正在播放

    public func updateCenterBtnState(_ state: DYControlPlayState) {
        currentState = state
        switch state {
            //页面刚加载时候
        case .preparing:
            errorOverlayView.isHidden = true
            centerPlayIcon.isHidden = true
            updateFullscreenVisibility()
        case .playing:
            errorOverlayView.isHidden = true
            UIView.animate(withDuration: 0.2) {
                self.centerPlayIcon.alpha = 0
            } completion: { _ in
                self.centerPlayIcon.isHidden = true
                self.centerPlayIcon.alpha = 1
            }
        case .notPlaying:
            errorOverlayView.isHidden = true
            centerPlayIcon.alpha = 0
            centerPlayIcon.isHidden = false
            UIView.animate(withDuration: 0.2) {
                self.centerPlayIcon.alpha = 1
            }
            updateFullscreenVisibility()
        case .error:
            centerPlayIcon.isHidden = true
            errorOverlayView.isHidden = false
            fullscreenButton.isHidden = true
        }
    }

    public func updateLoading(isLoading: Bool) {
        self.isLoading = isLoading
        if isLoading {
            centerPlayIcon.isHidden = true
            progressBar.startLoading()
            errorOverlayView.isHidden = true
        } else {
            progressBar.finishLoading()
        }
    }
    
    /// 更新进度
    /// - Parameters:
    ///   - currentTime: 当前时间
    ///   - totalTime: 总时间
    public func updateProgress(currentTime: Double, totalTime: Double) {
        // 如果正在拖拽，不更新进度条位置，以免跳动
        if !isDragging {
            if totalTime > 0 {
                progressBar.updateProgress(to: CGFloat(currentTime / totalTime))
            } else {
                progressBar.updateProgress(to: 0)
            }
        } else {
            // 拖拽时仅更新浮动时间显示，不更新进度条位置（因为进度条位置由手势控制）
            updateFloatingTime(currentTime: currentTime, totalTime: totalTime)
        }
    }
    
    /// 更新缓冲进度
    /// - Parameter progress: 缓冲进度 (0.0 - 1.0)
    public func updateBuffer(progress: Double) {
        progressBar.updateBuffer(to: CGFloat(progress))
    }

    public func updateAspectRatio(_ ratio: Double?, shouldShowFullscreenButton: Bool? = nil) {
        aspectRatio = ratio
        if let shouldShowFullscreenButton = shouldShowFullscreenButton {
            isFullscreenButtonEnabled = shouldShowFullscreenButton
        }
        updateFullscreenVisibility()
    }
    
    public func updateFullscreenState(isFullScreen: Bool) {
        fullscreenButton.isHidden = isFullScreen
        if !isFullScreen {
            updateFullscreenVisibility()
        }
    }
    
    // MARK: - Private Helper
    
    private func showFloatingTime(_ show: Bool) {
        UIView.animate(withDuration: 0.2) {
            self.floatingTimeLabel.alpha = show ? 1 : 0
        }
    }

    private func updateFullscreenVisibility() {
        guard isFullscreenButtonEnabled else {
            fullscreenButton.isHidden = true
            return
        }
        fullscreenButton.isHidden = currentState == .playing
        if !fullscreenButton.isHidden { bringSubviewToFront(fullscreenButton) }
    }
    
    private func updateFloatingTime(currentTime: Double, totalTime: Double) {
        let currentStr = formatTime(seconds: currentTime)
        let totalStr = formatTime(seconds: totalTime)
        
        // 创建富文本，设置不同颜色
        let fullText = "\(currentStr) / \(totalStr)"
        let attributedString = NSMutableAttributedString(string: fullText)
        
        // 设置 totalStr 为灰色
        if let range = fullText.range(of: "/ \(totalStr)") {
            let nsRange = NSRange(range, in: fullText)
            attributedString.addAttribute(.foregroundColor, value: UIColor.white.withAlphaComponent(0.5), range: nsRange)
        }
        
        floatingTimeLabel.attributedText = attributedString
    }
    
    private func formatTime(seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "00:00" }
        let secs = Int(seconds)
        let minutes = secs / 60
        let secondsValue = secs % 60
        return String(format: "%02d:%02d", minutes, secondsValue)
    }

    private lazy var errorOverlayView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.isHidden = true
        let label = UILabel()
        label.text = "加载错误"
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        view.addSubview(label)
        label.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        return view
    }()
}
