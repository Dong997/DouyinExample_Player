import UIKit
import SnapKit

/// 全屏视频播放控制器，负责承载系统播放器并管理交互控制
class FullscreenVideoViewController: UIViewController {

    // MARK: - Properties
    
    /// 当前播放的视频地址
    private let videoURL: URL
    /// 进入全屏时的视频起始时间，单位秒
    private let currentTime: TimeInterval
    /// 视频宽高比，用于按比例扩展布局
    private let aspectRatio: Double?
    /// 播放器依赖，由外部注入
    private var player: DYVideoAdvancedControlInput
    /// 全屏时支持的屏幕方向，默认横屏
    private let fullscreenOrientationMask: UIInterfaceOrientationMask
    /// 退出全屏时的回调，用于通知外部恢复状态
    var onDismiss: (() -> Void)?
    
    /// 承载播放器画面的容器视图
    private lazy var playerContainerView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        return view
    }()
    
    /// 关闭全屏播放的按钮
    private lazy var closeButton: UIButton = {
        let btn = UIButton(type: .custom)
        btn.setImage(UIImage(systemName: "xmark"), for: .normal)
        btn.tintColor = .white
        btn.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        btn.layer.cornerRadius = 20
        btn.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
        return btn
    }()
    
    /// 显示播放进度和缓冲进度的进度条
    private let progressBar = VideoProgressBar()
    /// 显示当前播放时间与总时长的标签
    private let timeLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 12)
        label.textAlignment = .left
        label.text = "00:00/00:00"
        return label
    }()
    /// 倍速播放按钮
    private let speedButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("倍速", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 12)
        return button
    }()
    /// 倍速选项容器视图
    private let speedSelectorContainerView = UIView()
    /// 长按快进时显示当前倍速提示的视图
    private let speedTipView = ShortPlayerSpeedTipView()
    /// 支持的播放倍速列表
    private let speedOptions: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]
    /// 当前倍速选择器是否可见
    private var isSpeedSelectorVisible: Bool = false
    /// 是否处于长按加速播放状态
    private var isFastPlayingByLongPress: Bool = false
    /// 当前播放倍速
    private var currentSpeed: Float = 1.0
    /// 是否正在手动拖拽进度条
    private var isDraggingProgress: Bool = false
    /// 播放控制元素的总容器视图
    private let controlsContainerView = UIView()
    /// 当前控制层是否处于展示状态
    private var areControlsVisible: Bool = true
    /// 控制层自动隐藏定时器
    private var controlsAutoHideTimer: Timer?
    /// 中间播放按钮的播放图标
    private let centerPlayPlayImage = UIImage(named: "longvideo_icon_play")
    /// 中间播放按钮的暂停图标
    private let centerPlayPauseImage = UIImage(named: "longvideo_icon_pause")
    /// 中间控制播放/暂停的按钮
    private lazy var centerPlayButton: UIButton = {
        let button = UIButton(type: .custom)
        button.setImage(centerPlayPlayImage, for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        button.layer.cornerRadius = 32
        button.isHidden = true
        return button
    }()

    /// 控制器释放时的日志，便于排查内存是否正确释放
    deinit {
        NSLog("FullscreenVideoViewController deinit")
    }

    // MARK: - Initialization
    
    /// 初始化全屏播放控制器
    /// - Parameters:
    ///   - videoURL: 视频播放地址
    ///   - currentTime: 初始播放进度，单位秒
    ///   - aspectRatio: 视频宽高比信息
    ///   - fullscreenOrientationMask: 全屏支持的屏幕方向
    init(
        videoURL: URL,
        currentTime: TimeInterval,
        aspectRatio: Double?,
        fullscreenOrientationMask: UIInterfaceOrientationMask = .landscapeRight,
        player: DYVideoAdvancedControlInput
    ) {
        self.videoURL = videoURL
        self.currentTime = currentTime
        self.aspectRatio = aspectRatio
        self.player = player
        self.fullscreenOrientationMask = fullscreenOrientationMask
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
    }
    
    /// 不支持从 Storyboard 构建
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    /// 视图加载完成，配置 UI 与手势，并开始播放
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        configureProgressBarCallbacks()
        speedButton.addTarget(self, action: #selector(handleSpeedButtonTapped), for: .touchUpInside)
        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.3
        view.addGestureRecognizer(longPressGesture)
        let singleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTapGesture.numberOfTapsRequired = 1
        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        singleTapGesture.require(toFail: doubleTapGesture)
        singleTapGesture.delegate = self
        doubleTapGesture.delegate = self
        view.addGestureRecognizer(singleTapGesture)
        view.addGestureRecognizer(doubleTapGesture)
        centerPlayButton.addTarget(self, action: #selector(handleCenterPlayButtonTapped), for: .touchUpInside)
        player.delegate = self
        currentSpeed = player.playbackRate
        updateSpeedButtonTitle()
        playVideo()
        scheduleControlsAutoHide()
    }

    /// 视图即将显示，此处预留扩展
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }
    
    /// 视图已经显示，此处预留扩展
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }

    /// 视图即将消失，此处预留扩展
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    /// 全屏播放时隐藏底部 Home Indicator（指示条）
    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }

    /// 返回全屏播放时支持的屏幕方向
    override var dyFullscreenOrientationMask: UIInterfaceOrientationMask {
        return fullscreenOrientationMask
    }

    // MARK: - Private Methods
    
    /// 构建全屏播放页面的 UI 结构与约束
    private func setupUI() {
        view.addSubview(playerContainerView)
        playerContainerView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        view.addSubview(controlsContainerView)
        controlsContainerView.backgroundColor = .clear
        controlsContainerView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        controlsContainerView.addSubview(progressBar)
        progressBar.snp.makeConstraints { make in
            make.leading.equalTo(view.safeAreaLayoutGuide.snp.leading).offset(44)
            make.trailing.equalTo(view.safeAreaLayoutGuide.snp.trailing).offset(-44)
            make.bottom.equalTo(view.safeAreaLayoutGuide.snp.bottom).offset(-24)
            make.height.equalTo(2)
        }
        
        controlsContainerView.addSubview(timeLabel)
        timeLabel.snp.makeConstraints { make in
            make.leading.equalTo(progressBar.snp.leading)
            make.bottom.equalTo(progressBar.snp.top).offset(-8)
        }
        
        controlsContainerView.addSubview(speedButton)
        speedButton.snp.makeConstraints { make in
            make.trailing.equalTo(progressBar.snp.trailing)
            make.centerY.equalTo(timeLabel.snp.centerY)
        }
        
        controlsContainerView.addSubview(speedSelectorContainerView)
        speedSelectorContainerView.isHidden = true
        speedSelectorContainerView.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        speedSelectorContainerView.layer.cornerRadius = 8
        speedSelectorContainerView.snp.makeConstraints { make in
            make.trailing.equalTo(speedButton.snp.trailing)
            make.bottom.equalTo(speedButton.snp.top).offset(-8)
        }
        setupSpeedSelector()
        
        controlsContainerView.addSubview(speedTipView)
        speedTipView.snp.makeConstraints { make in
            make.size.equalTo(CGSize(width: ShortPlayerSpeedTipView.viewWidth, height: ShortPlayerSpeedTipView.viewHeight))
            make.centerX.equalToSuperview()
            make.bottom.equalTo(progressBar.snp.top).offset(-20)
        }
        
        controlsContainerView.addSubview(closeButton)
        closeButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.top.equalToSuperview().offset(8)
            make.width.height.equalTo(32)
        }
        
        view.addSubview(centerPlayButton)
        centerPlayButton.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.height.equalTo(64)
        }
    }
    
    /// 在播放器容器中开始播放当前视频
    private func playVideo() {
        if let dyPlayer = player as? DYVideoPlayer {
            DYPlayerManager.shared.playWithCache(originalURL: videoURL, in: playerContainerView, seekTo: currentTime, use: dyPlayer)
        } else {
            // Fallback (should not happen in this project)
            DYPlayerManager.shared.playWithCache(originalURL: videoURL, in: playerContainerView, seekTo: currentTime)
        }
        player.videoGravity = .aspectFit
    }
    
    @objc private func handleClose() {
        dismiss(animated: true) { [weak self] in
            self?.onDismiss?()
        }
    }
}

extension FullscreenVideoViewController {
    /// 配置进度条拖拽相关回调，完成与播放器的联动
    private func configureProgressBarCallbacks() {
        progressBar.didBeginDragging = { [weak self] in
            guard let self = self else { return }
            self.isDraggingProgress = true
            self.showControls(animated: true)
            self.cancelControlsAutoHide()
            // 拖拽开始暂停播放，避免干扰
            self.player.pause()
        }
        progressBar.didChangeProgress = { [weak self] progress in
            guard let self = self else { return }
            let totalTime = self.player.duration
            let currentTime = Double(progress) * totalTime
            self.updateTimeLabel(currentTime: currentTime, totalTime: totalTime)
            
            // 拖拽过程中实时 Seek (非精确)
            self.player.seek(to: currentTime, isPrecise: false, completion: nil)
        }
        progressBar.didEndDragging = { [weak self] progress in
            guard let self = self else { return }
            self.isDraggingProgress = false
            let totalTime = self.player.duration
            let targetTime = Double(progress) * totalTime
            // 拖拽结束使用精确 Seek
            self.player.seek(to: targetTime, isPrecise: true) { finished in
                if finished {
                    self.player.resume()
                }
            }
            self.scheduleControlsAutoHide()
        }
    }
    
    /// 构建倍速选择器内部的按钮布局
    private func setupSpeedSelector() {
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.distribution = .fillEqually
        stackView.spacing = 4
        speedSelectorContainerView.addSubview(stackView)
        stackView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(8)
        }
        
        for (index, speed) in speedOptions.enumerated() {
            let button = UIButton(type: .system)
            let title = String(format: "%.2fx", speed)
            button.setTitle(title, for: .normal)
            button.setTitleColor(.white, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 12)
            button.tag = index
            button.addTarget(self, action: #selector(handleSpeedOptionTapped(_:)), for: .touchUpInside)
            stackView.addArrangedSubview(button)
        }
    }
    
    /// 更新时间标签显示的当前时间与总时长
    /// - Parameters:
    ///   - currentTime: 当前播放时间，单位秒
    ///   - totalTime: 视频总时长，单位秒
    private func updateTimeLabel(currentTime: Double, totalTime: Double) {
        let currentText = formatTime(seconds: currentTime)
        let totalText = formatTime(seconds: totalTime)
        timeLabel.text = "\(currentText)/\(totalText)"
    }
    
    /// 将秒数格式化为 mm:ss 形式的字符串
    /// - Parameter seconds: 时间秒数
    /// - Returns: 格式化后的时间字符串
    private func formatTime(seconds: Double) -> String {
        guard !seconds.isNaN, !seconds.isInfinite else { return "00:00" }
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
    
    /// 处理倍速按钮点击，控制倍速选择器的显示与隐藏
    @objc private func handleSpeedButtonTapped() {
        isSpeedSelectorVisible.toggle()
        speedSelectorContainerView.isHidden = !isSpeedSelectorVisible
        if isSpeedSelectorVisible {
            showControls(animated: true)
            cancelControlsAutoHide()
        } else {
            scheduleControlsAutoHide()
        }
    }

    private func updateSpeedButtonTitle() {
        let title = String(format: "%.2fx", currentSpeed)
        speedButton.setTitle(title, for: .normal)
    }
    
    /// 处理具体倍速选项点击，更新播放器播放倍速
    /// - Parameter sender: 被点击的倍速按钮
    @objc private func handleSpeedOptionTapped(_ sender: UIButton) {
        let index = sender.tag
        guard index >= 0, index < speedOptions.count else { return }
        let selectedSpeed = speedOptions[index]
        currentSpeed = selectedSpeed
        updateSpeedButtonTitle()
        isSpeedSelectorVisible = false
        speedSelectorContainerView.isHidden = true
        player.setPlaybackRate(currentSpeed)
        scheduleControlsAutoHide()
    }
    
    /// 处理长按手势，提供临时 2 倍速播放能力
    /// - Parameter gesture: 长按手势实例
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            if !isFastPlayingByLongPress {
                if player.state != .playing {
                    player.resume()
                }
                player.setPlaybackRate(2.0)
                isFastPlayingByLongPress = true
            }
            speedTipView.showSpeedView(tip: "2倍速")
        case .ended, .cancelled, .failed:
            player.setPlaybackRate(currentSpeed)
            isFastPlayingByLongPress = false
            speedTipView.hideSpeedView()
        default:
            break
        }
    }
}

extension FullscreenVideoViewController {
    /// 展示控制层，包括进度条、时间、倍速等控件
    /// - Parameter animated: 是否使用渐隐动画
    private func showControls(animated: Bool) {
        areControlsVisible = true
        controlsContainerView.isUserInteractionEnabled = true
        updateCenterPlayButtonForPlayerState(player.state)
        let animations = {
            self.controlsContainerView.alpha = 1.0
        }
        if animated {
            UIView.animate(withDuration: 0.25, animations: animations)
        } else {
            animations()
        }
    }
    
    /// 隐藏控制层，同时禁用交互
    /// - Parameter animated: 是否使用渐隐动画
    private func hideControls(animated: Bool) {
        areControlsVisible = false
        controlsContainerView.isUserInteractionEnabled = false
        centerPlayButton.isHidden = true
        let animations = {
            self.controlsContainerView.alpha = 0.0
        }
        if animated {
            UIView.animate(withDuration: 0.25, animations: animations)
        } else {
            animations()
        }
    }
    
    /// 取消控制层的自动隐藏定时器
    private func cancelControlsAutoHide() {
        controlsAutoHideTimer?.invalidate()
        controlsAutoHideTimer = nil
    }
    
    /// 重新开启控制层的自动隐藏定时器
    private func scheduleControlsAutoHide() {
        cancelControlsAutoHide()
        controlsAutoHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.hideControls(animated: true)
        }
    }
    
    /// 单击手势回调：在显示和隐藏控制层之间切换
    /// - Parameter gesture: 单击手势实例
    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        if areControlsVisible {
            hideControls(animated: true)
            cancelControlsAutoHide()
        } else {
            showControls(animated: true)
            scheduleControlsAutoHide()
        }
    }
    
    /// 双击手势回调：控制播放/暂停
    /// - Parameter gesture: 双击手势实例
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if player.state == .playing {
            player.pause()
        } else {
            player.resume()
        }
        showControls(animated: true)
        scheduleControlsAutoHide()
    }
    
    /// 中间播放按钮点击回调，切换播放/暂停状态
    @objc private func handleCenterPlayButtonTapped() {
        if player.state == .playing {
            player.pause()
        } else {
            player.resume()
        }
        showControls(animated: true)
        scheduleControlsAutoHide()
    }
    
    /// 根据当前播放器状态更新中间播放按钮的图标与显示状态
    /// - Parameter state: 播放器当前状态
    private func updateCenterPlayButtonForPlayerState(_ state: DYPlayerState) {
        switch state {
        case .playing:
            centerPlayButton.setImage(centerPlayPauseImage, for: .normal)
        default:
            centerPlayButton.setImage(centerPlayPlayImage, for: .normal)
        }
        centerPlayButton.isHidden = !areControlsVisible
    }
}

extension FullscreenVideoViewController: DYVideoPlayerDelegate {
    /// 播放器状态变更回调
    /// - Parameters:
    ///   - player: 播放器实例
    ///   - state: 最新的播放器状态
    func player(_ player: DYVideoPlayer, didChangeState state: DYPlayerState) {
        switch state {
        case .playing:
            updateCenterPlayButtonForPlayerState(state)
            scheduleControlsAutoHide()
        case .paused:
            showControls(animated: true)
            cancelControlsAutoHide()
            updateCenterPlayButtonForPlayerState(state)
        case .finished:
            showControls(animated: true)
            cancelControlsAutoHide()
            updateCenterPlayButtonForPlayerState(state)
        case .idle, .preparing, .buffering:
            updateCenterPlayButtonForPlayerState(state)
        case .error(_):
            showControls(animated: true)
            cancelControlsAutoHide()
            updateCenterPlayButtonForPlayerState(state)
        }
    }
    
    /// 播放进度更新回调，驱动进度条与时间显示
    /// - Parameters:
    ///   - player: 播放器实例
    ///   - progress: 当前进度比值 0~1
    ///   - currentTime: 当前播放时间，单位秒
    ///   - totalTime: 总时长，单位秒
    func player(_ player: DYVideoPlayer, didUpdateProgress progress: Double, currentTime: Double, totalTime: Double) {
        if !isDraggingProgress {
            progressBar.updateProgress(to: CGFloat(progress))
            updateTimeLabel(currentTime: currentTime, totalTime: totalTime)
        }
    }
    
    /// 缓冲进度更新回调
    /// - Parameters:
    ///   - player: 播放器实例
    ///   - progress: 当前缓冲比值 0~1
    func player(_ player: DYVideoPlayer, didUpdateBuffer progress: Double) {
        progressBar.updateBuffer(to: CGFloat(progress))
    }
}

extension FullscreenVideoViewController: UIGestureRecognizerDelegate {
    /// 控制手势是否响应，避免穿透中间播放按钮
    /// - Parameters:
    ///   - gestureRecognizer: 当前手势识别器
    ///   - touch: 当前触摸事件
    /// - Returns: 是否允许该手势识别
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if touch.view === centerPlayButton || (touch.view?.isDescendant(of: centerPlayButton) ?? false) {
            return false
        }
        return true
    }
}
