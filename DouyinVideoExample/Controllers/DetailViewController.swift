import UIKit
import SnapKit

class DetailViewController: UIViewController {

    // MARK: - Properties

    private let videoURL: URL
    private let seekTime: TimeInterval
    
    // Container for the video player
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

    init(videoURL: URL, seekTime: TimeInterval = 0) {
        self.videoURL = videoURL
        self.seekTime = seekTime
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
        
        // 首次进入时接管播放器
        setupPlayer()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // 页面出现时（包括从下一级返回），检查并恢复播放器
        let player = DYPlayerManager.shared.player
        if player.containerView != videoContainerView {
            setupPlayer()
        }
    }
    
    private func setupPlayer() {
        let player = DYPlayerManager.shared.player
        let isSameVideo = (player.originalURL == videoURL) || (player.currentURL == videoURL)
        
        if isSameVideo {
            // 无缝衔接：直接移动 layer
            player.updateContainer(videoContainerView)
            if player.state != .playing {
                player.resume()
            }
        } else {
            // 不同视频：重新播放，并跳转到指定时间
            DYPlayerManager.shared.play(url: videoURL, in: videoContainerView, seekTo: seekTime)
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Ensure player is paused if we are popping and not restoring immediately
        // But HomeViewController will handle restoration in viewWillAppear
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.addSubview(videoContainerView)
        videoContainerView.snp.makeConstraints { make in
            make.leading.trailing.top.equalToSuperview()
            make.height.equalToSuperview().multipliedBy(0.4) // Top 40% for video
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

    @objc private func backButtonTapped() {
        navigationController?.popViewController(animated: true)
    }
    
    @objc private func recommendButtonTapped() {
        // Simulate playing a recommended video
        // For testing, let's just pick a different URL or the same one but treat it as a "recommendation"
        // Here we use a sample URL
//        if let url = URL(string: "https://www.w3schools.com/html/mov_bbb.mp4") {
//             DYPlayerManager.shared.play(url: url, in: videoContainerView)
//             infoLabel.text = "Playing Recommendation..."
//        }
        
        self.navigationController?.pushViewController(HomeViewController(), animated: true)
    }
}
