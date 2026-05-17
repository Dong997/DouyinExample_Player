import UIKit
import SnapKit

/// 视频详情页控制器
/// 职责仅限于：
/// 1. UI 布局与构建
/// 2. 视频播放器容器管理
/// 3. 通过 Coordinator 处理导航（不直接 push/pop）
class DetailViewController: UIViewController, DYOrientationConfigurable {

    // MARK: - Properties

    private let videoURL: URL
    private let seekTime: TimeInterval
    private let playerSession: DYVideoPlayerSession
    private let playback: DYPlaybackCoordinating
    private var hasTakenOverPlayer: Bool = false

    /// 导航协调器，由 DetailCoordinator 注入
    weak var coordinator: DetailCoordinator?

    // MARK: - UI Components

    /// 视频播放器容器视图
    let videoContainerView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        return view
    }()

    private let backButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        button.layer.cornerRadius = 20
        return button
    }()

    private let infoLabel: UILabel = {
        let label = UILabel()
        label.text = "Detail Page Content"
        label.textColor = .white
        label.textAlignment = .center
        return label
    }()

    private let recommendButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Play Recommended Video", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = .systemBlue
        button.layer.cornerRadius = 8
        return button
    }()

    // MARK: - Initialization

    init(
        videoURL: URL,
        seekTime: TimeInterval = 0,
        player: DYVideoPlayerSession,
        playback: DYPlaybackCoordinating
    ) {
        self.videoURL = videoURL
        self.seekTime = seekTime
        self.playerSession = player
        self.playback = playback
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        setupActions()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        takeOverPlayerIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let player = playerSession
        if player.containerView != videoContainerView {
            hasTakenOverPlayer = false
            takeOverPlayerIfNeeded()
        }
    }

    private func takeOverPlayerIfNeeded() {
        if hasTakenOverPlayer {
            return
        }

        if videoContainerView.bounds.isEmpty {
            return
        }

        let player = playerSession
        let isSameVideo = player.isPlaying(url: videoURL)

        if isSameVideo {
            player.updateContainer(videoContainerView)
            if player.state != .playing {
                player.resume()
            }
        } else {
            playback.playWithCache(originalURL: videoURL, in: videoContainerView, seekTo: seekTime, use: nil)
        }

        hasTakenOverPlayer = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.addSubview(videoContainerView)
        videoContainerView.snp.makeConstraints { make in
            make.leading.trailing.top.equalToSuperview()
            make.height.equalToSuperview().multipliedBy(0.4)
        }

        view.addSubview(backButton)
        backButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.top.equalTo(view.safeAreaLayoutGuide).offset(16)
            make.width.height.equalTo(40)
        }

        view.addSubview(infoLabel)
        infoLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        view.addSubview(recommendButton)
        recommendButton.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalTo(infoLabel.snp.bottom).offset(20)
            make.width.equalTo(200)
            make.height.equalTo(44)
        }
    }

    private func setupActions() {
        backButton.addTarget(self, action: #selector(backButtonTapped), for: .touchUpInside)
        recommendButton.addTarget(self, action: #selector(recommendButtonTapped), for: .touchUpInside)
    }

    // MARK: - Actions

    /// 返回首页（通过 Coordinator，不再直接操作 navigationController）
    @objc private func backButtonTapped() {
        coordinator?.navigateBack()
    }

    /// 播放推荐视频（通过 Coordinator 返回首页，不再创建新 HomeVC 实例）
    @objc private func recommendButtonTapped() {
        coordinator?.playRecommendedVideo()
    }
}
