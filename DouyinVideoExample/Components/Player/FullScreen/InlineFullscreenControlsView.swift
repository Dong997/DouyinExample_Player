import UIKit

/// 内联全屏控制层，负责按钮、进度条、倍速面板和提示 UI。
final class InlineFullscreenControlsView: UIView {

    var onClose: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onSpeedSelected: ((Float) -> Void)?
    var onProgressDragStart: (() -> Void)?
    var onProgressChanged: ((CGFloat) -> Void)?
    var onProgressEnded: ((CGFloat) -> Void)?

    private let closeButton = UIButton(type: .custom)
    private let progressBar = VideoProgressBar()
    private let timeLabel = UILabel()
    private let speedButton = UIButton(type: .system)
    private let speedSelectorContainerView = UIView()
    private let centerPlayButton = UIButton(type: .custom)
    private let speedTipView = ShortPlayerSpeedTipView()

    private let speedOptions: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]
    private let centerPlayPlayImage = UIImage(named: "longvideo_icon_play")
    private let centerPlayPauseImage = UIImage(named: "longvideo_icon_pause")
    private var isSpeedSelectorVisible = false

    private(set) var isVisible = false
    private var currentSpeed: Float = 1.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutControls(in: bounds)
    }

    func configure(currentSpeed: Float) {
        self.currentSpeed = currentSpeed
        updateSpeedButtonTitle()
    }

    func show(animated: Bool) {
        isVisible = true
        isUserInteractionEnabled = true
        centerPlayButton.isHidden = false
        let updates = { self.alpha = 1 }
        if animated {
            UIView.animate(withDuration: 0.25, animations: updates)
        } else {
            updates()
        }
    }

    func hide(animated: Bool) {
        isVisible = false
        isUserInteractionEnabled = false
        isSpeedSelectorVisible = false
        speedSelectorContainerView.isHidden = true
        centerPlayButton.isHidden = true
        let updates = { self.alpha = 0 }
        if animated {
            UIView.animate(withDuration: 0.25, animations: updates)
        } else {
            updates()
        }
    }

    func updatePlaybackState(_ state: DYPlayerState?) {
        switch state {
        case .playing:
            centerPlayButton.setImage(centerPlayPauseImage, for: .normal)
        default:
            centerPlayButton.setImage(centerPlayPlayImage, for: .normal)
        }
        centerPlayButton.isHidden = !isVisible
    }

    func updateProgress(currentTime: Double, totalTime: Double) {
        guard totalTime > 0 else {
            progressBar.updateProgress(to: 0)
            timeLabel.text = "00:00/00:00"
            return
        }
        progressBar.updateProgress(to: CGFloat(currentTime / totalTime))
        updateTimeLabel(currentTime: currentTime, totalTime: totalTime)
    }

    func updateTimeLabel(currentTime: Double, totalTime: Double) {
        timeLabel.text = "\(Self.formatTime(currentTime))/\(Self.formatTime(totalTime))"
    }

    func updateBuffer(to progress: CGFloat) {
        progressBar.updateBuffer(to: progress)
    }

    func startLoading() {
        progressBar.startLoading()
    }

    func finishLoading() {
        progressBar.finishLoading()
    }

    func showSpeedTip() {
        speedTipView.showSpeedView(tip: "2倍速")
    }

    func hideSpeedTip() {
        speedTipView.hideSpeedView()
    }

    func containsControl(_ view: UIView) -> Bool {
        let excludedViews: [UIView] = [
            centerPlayButton,
            closeButton,
            progressBar,
            speedButton,
            speedSelectorContainerView
        ]
        return excludedViews.contains { excludedView in
            view === excludedView || view.isDescendant(of: excludedView)
        }
    }

    private func setupUI() {
        backgroundColor = .clear
        alpha = 0
        isUserInteractionEnabled = false

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        closeButton.layer.cornerRadius = 20
        closeButton.addTarget(self, action: #selector(handleCloseTapped), for: .touchUpInside)

        progressBar.progressColor = .white
        progressBar.bufferColor = UIColor.white.withAlphaComponent(0.5)
        progressBar.trackColor = UIColor.white.withAlphaComponent(0.2)
        progressBar.didBeginDragging = { [weak self] in
            self?.onProgressDragStart?()
        }
        progressBar.didChangeProgress = { [weak self] progress in
            self?.onProgressChanged?(progress)
        }
        progressBar.didEndDragging = { [weak self] progress in
            self?.onProgressEnded?(progress)
        }

        timeLabel.textColor = .white
        timeLabel.font = UIFont.systemFont(ofSize: 12)
        timeLabel.textAlignment = .left
        timeLabel.text = "00:00/00:00"

        speedButton.setTitleColor(.white, for: .normal)
        speedButton.titleLabel?.font = UIFont.systemFont(ofSize: 12)
        speedButton.addTarget(self, action: #selector(handleSpeedButtonTapped), for: .touchUpInside)

        speedSelectorContainerView.isHidden = true
        speedSelectorContainerView.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        speedSelectorContainerView.layer.cornerRadius = 8
        setupSpeedSelector()

        centerPlayButton.setImage(centerPlayPlayImage, for: .normal)
        centerPlayButton.tintColor = .white
        centerPlayButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        centerPlayButton.layer.cornerRadius = 32
        centerPlayButton.isHidden = true
        centerPlayButton.addTarget(self, action: #selector(handleCenterPlayTapped), for: .touchUpInside)

        addSubview(centerPlayButton)
        addSubview(progressBar)
        addSubview(timeLabel)
        addSubview(speedButton)
        addSubview(speedSelectorContainerView)
        addSubview(closeButton)
        addSubview(speedTipView)
        updateSpeedButtonTitle()
    }

    private func setupSpeedSelector() {
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.distribution = .fillEqually
        stackView.spacing = 4
        speedSelectorContainerView.addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: speedSelectorContainerView.leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: speedSelectorContainerView.trailingAnchor, constant: -8),
            stackView.topAnchor.constraint(equalTo: speedSelectorContainerView.topAnchor, constant: 8),
            stackView.bottomAnchor.constraint(equalTo: speedSelectorContainerView.bottomAnchor, constant: -8)
        ])

        for (index, speed) in speedOptions.enumerated() {
            let button = UIButton(type: .system)
            button.setTitle(String(format: "%.2fx", speed), for: .normal)
            button.setTitleColor(.white, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 12)
            button.tag = index
            button.addTarget(self, action: #selector(handleSpeedOptionTapped(_:)), for: .touchUpInside)
            stackView.addArrangedSubview(button)
        }
    }

    private func layoutControls(in bounds: CGRect) {
        closeButton.frame = CGRect(x: 48, y: 18, width: 40, height: 40)
        let horizontalInset: CGFloat = 44
        let progressY = bounds.height - 26
        progressBar.frame = CGRect(
            x: horizontalInset,
            y: progressY,
            width: max(0, bounds.width - horizontalInset * 2),
            height: 2
        )
        timeLabel.frame = CGRect(
            x: horizontalInset,
            y: progressY - 26,
            width: 140,
            height: 18
        )
        speedButton.frame = CGRect(
            x: max(horizontalInset, bounds.width - horizontalInset - 54),
            y: progressY - 30,
            width: 54,
            height: 26
        )
        speedSelectorContainerView.frame = CGRect(
            x: max(horizontalInset, bounds.width - horizontalInset - 70),
            y: progressY - 30 - 8 - 152,
            width: 70,
            height: 152
        )
        centerPlayButton.frame = CGRect(
            x: bounds.midX - 32,
            y: bounds.midY - 32,
            width: 64,
            height: 64
        )
        speedTipView.frame = CGRect(
            x: bounds.midX - ShortPlayerSpeedTipView.viewWidth / 2,
            y: progressY - 20 - ShortPlayerSpeedTipView.viewHeight,
            width: ShortPlayerSpeedTipView.viewWidth,
            height: ShortPlayerSpeedTipView.viewHeight
        )
    }

    private func updateSpeedButtonTitle() {
        speedButton.setTitle(String(format: "%.2fx", currentSpeed), for: .normal)
    }

    private static func formatTime(_ time: Double) -> String {
        guard time.isFinite else { return "00:00" }
        let seconds = max(0, Int(time))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    @objc private func handleCloseTapped() {
        onClose?()
    }

    @objc private func handleCenterPlayTapped() {
        onPlayPause?()
    }

    @objc private func handleSpeedButtonTapped() {
        isSpeedSelectorVisible.toggle()
        speedSelectorContainerView.isHidden = !isSpeedSelectorVisible
    }

    @objc private func handleSpeedOptionTapped(_ sender: UIButton) {
        let index = sender.tag
        guard index >= 0, index < speedOptions.count else { return }
        currentSpeed = speedOptions[index]
        updateSpeedButtonTitle()
        isSpeedSelectorVisible = false
        speedSelectorContainerView.isHidden = true
        onSpeedSelected?(currentSpeed)
    }
}
