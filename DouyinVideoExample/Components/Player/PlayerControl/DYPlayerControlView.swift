import UIKit
import SnapKit

/// 播放器控制视图 (进度条、暂停按钮、错误覆盖层等)
public class DYPlayerControlView: UIView {
    
    // MARK: - Properties
    
    /// 控制视图的渲染状态快照，通过 Diff 渲染避免重复 UI 更新
    private struct ViewState {
        /// 播放器当前状态 (播放中、暂停、缓冲、错误等)
        var playerState: DYPlayerState = .idle
        /// 是否处于加载中，决定是否展示加载动画
        var isLoading: Bool = false
        /// 视频宽高比 (用于决定是否展示全屏按钮等)
        var aspectRatio: Double?
        /// 是否允许显示“全屏观看”按钮
        var isFullscreenButtonEnabled: Bool = false
        /// 当前是否已经处于全屏播放
        var isFullScreen: Bool = false
    }
    
    /// 控制视图代理，负责接收用户交互事件并转发给外部
    public weak var delegate: DYPlayerControlViewDelegate?
    
    /// 是否正在拖拽进度条，拖拽中时不会自动更新进度条位置
    private var isDragging: Bool = false
    /// 是否处于长按加速播放状态
    private var isFastPlaying: Bool = false
    /// 当前渲染状态
    private var viewState = ViewState()

    private var totalDuration: Double = 0
    /// 延迟隐藏错误覆盖层的任务，用于避免频繁闪烁
    private var errorOverlayPendingWorkItem: DispatchWorkItem?
    /// 长按加速播放时展示的提示视图
    private lazy var speedTipView: ShortPlayerSpeedTipView = {
        let tipView = ShortPlayerSpeedTipView()
        return tipView
    }()
    /// “全屏观看”按钮，仅在竖屏且满足条件时显示
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
    
    /// 浮动时间标签 (拖拽时显示当前/总时长)
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
    
    /// 视频播放进度条，支持拖拽和缓冲进度展示
    private lazy var progressBar: VideoProgressBar = {
        let bar = VideoProgressBar()
        bar.progressColor = .white
        bar.bufferColor = UIColor.white.withAlphaComponent(0.5)
        bar.trackColor = UIColor.white.withAlphaComponent(0.2)
        
        /// 绑定进度条交互回调，将拖拽事件透传给外部代理
        bar.didBeginDragging = { [weak self] in
            guard let self = self else { return }
            self.isDragging = true
            self.showFloatingTime(true)
            self.delegate?.controlViewDidBeginDragging(self)
        }
        
        bar.didChangeProgress = { [weak self] progress in
            guard let self = self else { return }
            let currentTime = Double(progress) * self.totalDuration
            self.updateFloatingTime(currentTime: currentTime, totalTime: self.totalDuration)
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
    
    /// 屏幕中央的播放图标 (暂停或缓冲时显示)
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
    
    /// 初始化并布局子视图，绑定手势与约束
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
    
    /// 点击播放/暂停按钮时回调给外部
    @objc private func playPauseTapped() {
        delegate?.controlViewDidTapPlayPause(self)
    }
    
    /// 处理长按手势：按下开始进入倍速播放，松开恢复
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            if !isFastPlaying {
                isFastPlaying = true
                delegate?.controlViewDidBeginFastPlay(self)
            }
            speedTipView.showSpeedView(tip: "2倍速")
        case .ended, .cancelled, .failed:
            isFastPlaying = false
            delegate?.controlViewDidEndFastPlay(self)
            speedTipView.hideSpeedView()
        default:
            break
        }
    }

    /// 点击“全屏观看”按钮时回调给外部
    @objc private func fullscreenTapped() {
        delegate?.controlViewDidTapFullscreen(self)
    }
    
    // MARK: - Public Methods
    
    /// 更新中央播放按钮展示的播放器状态
    /// - Parameter state: 播放器当前状态
    public func updateCenterBtnState(_ state: DYPlayerState) {
        applyViewState { viewState in
            viewState.playerState = state
        }
    }

    /// 更新加载状态，控制加载动画与错误覆盖层
    /// - Parameter isLoading: 是否正在加载
    public func updateLoading(isLoading: Bool) {
        applyViewState { viewState in
            viewState.isLoading = isLoading
        }
    }
    
    /// 更新播放进度和拖拽时的浮动时间展示
    /// - Parameters:
    ///   - currentTime: 当前时间
    ///   - totalTime: 总时间
    public func updateProgress(currentTime: Double, totalTime: Double) {
        self.totalDuration = totalTime
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

    /// 更新视频宽高比和是否展示全屏按钮
    /// - Parameters:
    ///   - ratio: 视频宽高比，nil 表示未知
    ///   - shouldShowFullscreenButton: 是否允许显示全屏按钮
    public func updateAspectRatio(_ ratio: Double?, shouldShowFullscreenButton: Bool? = nil) {
        applyViewState { viewState in
            viewState.aspectRatio = ratio
            if let shouldShowFullscreenButton = shouldShowFullscreenButton {
                viewState.isFullscreenButtonEnabled = shouldShowFullscreenButton
            }
        }
    }
    
    /// 更新当前是否处于全屏状态
    /// - Parameter isFullScreen: 是否为全屏
    public func updateFullscreenState(isFullScreen: Bool) {
        applyViewState { viewState in
            viewState.isFullScreen = isFullScreen
        }
    }
    
    // MARK: - Private Helper
    
    /// 更新内部 ViewState 并进行 Diff 渲染
    /// - Parameter update: 对状态的修改闭包
    private func applyViewState(_ update: (inout ViewState) -> Void) {
        let oldState = viewState
        update(&viewState)
        render(old: oldState, new: viewState)
    }
    
    /// 控制浮动时间标签的显隐
    /// - Parameter show: 是否显示
    private func showFloatingTime(_ show: Bool) {
        UIView.animate(withDuration: 0.2) {
            self.floatingTimeLabel.alpha = show ? 1 : 0
        }
    }

    /// 根据新旧 ViewState 渲染 UI，避免不必要的刷新
    /// - Parameters:
    ///   - old: 旧状态
    ///   - new: 新状态
    private func render(old: ViewState, new: ViewState) {
        if new.isLoading != old.isLoading {
            if new.isLoading {
                centerPlayIcon.isHidden = true
                progressBar.startLoading()
                errorOverlayView.isHidden = true
            } else {
                progressBar.finishLoading()
            }
        }
        
        if new.playerState != old.playerState {
            errorOverlayPendingWorkItem?.cancel()
            errorOverlayPendingWorkItem = nil
            
            switch new.playerState {
            case .error:
                centerPlayIcon.isHidden = true
                errorOverlayView.isHidden = false
                fullscreenButton.isHidden = true
            case .playing:
                scheduleHideErrorOverlay()
                UIView.animate(withDuration: 0.2) {
                    self.centerPlayIcon.alpha = 0
                } completion: { _ in
                    self.centerPlayIcon.isHidden = true
                    self.centerPlayIcon.alpha = 1
                }
            case .idle, .preparing, .finished:
                scheduleHideErrorOverlay()
                centerPlayIcon.isHidden = true
            case .buffering, .paused:
                scheduleHideErrorOverlay()
                centerPlayIcon.alpha = 0
                centerPlayIcon.isHidden = false
                UIView.animate(withDuration: 0.2) {
                    self.centerPlayIcon.alpha = 1
                }
            }
        }
        
        let canShowFullscreenButton = new.isFullscreenButtonEnabled && !new.isFullScreen
        let shouldShowFullscreenButton = canShowFullscreenButton && !new.playerState.isError
        
        fullscreenButton.isHidden = !shouldShowFullscreenButton
        if !fullscreenButton.isHidden {
            bringSubviewToFront(fullscreenButton)
        }
    }
    
    /// 延迟隐藏错误覆盖层，防止频繁闪烁
    private func scheduleHideErrorOverlay() {
        errorOverlayPendingWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.errorOverlayView.isHidden = true
        }
        errorOverlayPendingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }
    
    /// 更新拖拽时显示的浮动时间文案
    /// - Parameters:
    ///   - currentTime: 当前时间
    ///   - totalTime: 总时长
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
    
    /// 将秒数格式化为 `mm:ss` 字符串
    /// - Parameter seconds: 秒数
    /// - Returns: 格式化后的时间字符串
    private func formatTime(seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "00:00" }
        let secs = Int(seconds)
        let minutes = secs / 60
        let secondsValue = secs % 60
        return String(format: "%02d:%02d", minutes, secondsValue)
    }

    /// 错误覆盖层视图，用于展示“加载错误”等提示
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
