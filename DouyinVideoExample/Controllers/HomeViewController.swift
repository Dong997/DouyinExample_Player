import UIKit
import SnapKit
import Combine

class HomeViewController: UIViewController {
    
    // MARK: - Properties
    
    private let viewModel = HomeViewModel()
    private var cancellables = Set<AnyCancellable>()
    private var currentPlayingIndexPath: IndexPath?
    private var fullscreenTransitioningDelegate: FullscreenVideoTransitioningDelegate?
    private let bottomBar: UIView = {
        let barView = UIView()
        barView.backgroundColor = UIColor.gray
        return barView
    }()
    private let bottomStack: UIStackView = {
        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.distribution = .equalSpacing
        stackView.spacing = 24
        return stackView
    }()
    
    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = .zero
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        layout.sectionInset = .zero
        layout.scrollDirection = .vertical
        
        let collectionViewInstance = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionViewInstance.backgroundColor = .black
        collectionViewInstance.delegate = self
        collectionViewInstance.dataSource = self
        collectionViewInstance.isPagingEnabled = true
        collectionViewInstance.contentInsetAdjustmentBehavior = .never
        collectionViewInstance.register(VideoCell.self, forCellWithReuseIdentifier: VideoCell.identifier)
        return collectionViewInstance
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .gray
        
        VideoCacheManager.shared.clearAllCache()
        // 启动视频缓存代理服务
        VideoCacheManager.shared.start()
        
        // 设置播放器代理
        DYPlayerManager.shared.player.delegate = self
        
        // 启用侧滑返回手势
        navigationController?.interactivePopGestureRecognizer?.delegate = self
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        
        setupUI()
        bindViewModel()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        checkAndRestorePlayer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            let size = collectionView.bounds.size
            if layout.itemSize != size {
                layout.itemSize = size
                layout.invalidateLayout()
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 只有当播放器还在当前页面（是 collectionView 的子视图）时才暂停
        // 如果已经跳转到详情页，播放器已经被详情页接管（containerView 变了），此时不应暂停
        let player = DYPlayerManager.shared.player
        if let container = player.containerView, container.isDescendant(of: collectionView) {
            player.pause()
        }
    }
    
    // MARK: - Orientation Support
    
    // MARK: - Private Methods
    
    private func checkAndRestorePlayer() {
        guard let indexPath = currentPlayingIndexPath,
              let cell = collectionView.cellForItem(at: indexPath) as? VideoCell,
              viewModel.videos.indices.contains(indexPath.item) else {
            return
        }
        
        let video = viewModel.videos[indexPath.item]
        let player = DYPlayerManager.shared.player
        
        // 恢复代理 (防止详情页修改了代理)
        player.delegate = self
        
        // 检查播放器是否被挪用（容器不一致）
        if player.containerView !== cell.playerContainerView {
            // 判断是否是同一个视频
            let isSameVideo: Bool
            if let original = player.originalURL {
                isSameVideo = (original == video.videoURL)
            } else if let current = player.currentURL {
                isSameVideo = (current == video.videoURL)
            } else {
                isSameVideo = false
            }
            
            if isSameVideo {
                // 1. 同视频：无缝拿回播放器
                player.updateContainer(cell.playerContainerView)
                if player.state != .playing {
                    player.resume()
                }
            } else {
                // 2. 不同视频：重新加载当前视频
                playVideo(at: indexPath)
            }
        } else {
            // 容器一致，仅确保恢复播放
            if player.state != .playing {
                player.resume()
            }
        }
    }
    
    private func setupUI() {
        view.addSubview(bottomBar)
        bottomBar.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(view.safeAreaLayoutGuide.snp.bottom)
            make.height.equalTo(60)
        }

        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.leading.trailing.top.equalToSuperview()
            make.bottom.equalTo(bottomBar.snp.top)
        }

        bottomBar.addSubview(bottomStack)
        bottomStack.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.bottom.equalToSuperview().inset(8)
        }
        let home = makeTabItem(image: UIImage(systemName: "house.fill"), title: "首页", highlighted: true)
        let friends = makeTabItem(image: UIImage(systemName: "person.2.fill"), title: "朋友")
        let plusImage = UIImage(systemName: "plus.circle.fill")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 28, weight: .bold))
        let plus = makeTabItem(image: plusImage, title: "")
        let messages = makeTabItem(image: UIImage(systemName: "message.fill"), title: "消息")
        let me = makeTabItem(image: UIImage(systemName: "person.crop.circle"), title: "我")
        [home, friends, plus, messages, me].forEach { bottomStack.addArrangedSubview($0) }
    }
    
    private func bindViewModel() {
        viewModel.$videos
            .receive(on: DispatchQueue.main)
            .sink { [weak self] videos in
                guard let self = self else { return }
                let currentCount = self.collectionView.numberOfItems(inSection: 0)
                if currentCount != videos.count {
                    self.collectionView.reloadData()
                    if !videos.isEmpty {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            let indexPath = IndexPath(item: 0, section: 0)
                            self.playVideo(at: indexPath)
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func makeTabItem(image: UIImage?, title: String, highlighted: Bool = false) -> UIStackView {
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = highlighted ? .white : UIColor.white.withAlphaComponent(0.7)
        let label = UILabel()
        label.text = title
        label.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        label.textAlignment = .center
        label.textColor = highlighted ? .white : UIColor.white.withAlphaComponent(0.7)
        let stack = UIStackView(arrangedSubviews: [imageView, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        return stack
    }
    
    private func playVideo(at indexPath: IndexPath) {
        // 如果切换了视频，先保存上一个视频的播放进度
        if let current = currentPlayingIndexPath, current != indexPath {
            let time = DYPlayerManager.shared.player.currentTime
            viewModel.updateResumeTime(for: current.item, time: time)
        }
        
        guard let cell = collectionView.cellForItem(at: indexPath) as? VideoCell else { return }
        let video = viewModel.videos[indexPath.item]
        
        currentPlayingIndexPath = indexPath
        
        cell.controlView.delegate = self
        cell.controlView.updateProgress(currentTime: 0, totalTime: 0)
        cell.controlView.updateCenterBtnState(.preparing)
        
        // 点击标题跳转详情页
        cell.onTitleTapped = { [weak self] in
            guard let self = self else { return }
            let currentTime = DYPlayerManager.shared.player.currentTime
            let detailVC = DetailViewController(videoURL: video.videoURL, seekTime: currentTime)
            self.navigationController?.pushViewController(detailVC, animated: true)
        }
        
        // 使用缓存代理播放，如果代理失败会自动降级为原始 URL
        if video.resumeTime > 0 {
            DYPlayerManager.shared.playWithCache(originalURL: video.videoURL, in: cell.playerContainerView, seekTo: video.resumeTime)
        } else {
            DYPlayerManager.shared.playWithCache(originalURL: video.videoURL, in: cell.playerContainerView)
        }
        
        // 更新预加载策略 (前后各预加载1个)
        let allURLs = viewModel.videos.map { $0.videoURL }
        VideoPreloadManager.shared.updateStrategy(currentURL: video.videoURL, allURLs: allURLs)
    }

    private func presentFullscreen(for indexPath: IndexPath) {
        guard viewModel.videos.indices.contains(indexPath.item) else { return }
        guard let cell = collectionView.cellForItem(at: indexPath) as? VideoCell else { return }
        let video = viewModel.videos[indexPath.item]
        let currentTime = DYPlayerManager.shared.player.currentTime
        let horizontalAspectRatio = video.aspectRatio ?? 1.1
        let fullscreenOrientationMask: UIInterfaceOrientationMask = horizontalAspectRatio > 1.0 ? .landscapeRight : .portrait
        let fullscreenViewController = FullscreenVideoViewController(
            videoURL: video.videoURL,
            currentTime: currentTime,
            aspectRatio: video.aspectRatio,
            fullscreenOrientationMask: fullscreenOrientationMask,
            player: DYPlayerManager.shared.player
        )
        fullscreenViewController.onDismiss = { [weak self] in
            guard let self = self else { return }
            DYPlayerManager.shared.player.delegate = self
            self.bottomBar.isHidden = false
            self.collectionView.isHidden = false
            self.restorePlayerAfterFullscreen(at: indexPath)
        }
        let transitionDelegate = FullscreenVideoTransitioningDelegate(
            originView: cell.playerContainerView,
            fullscreenOrientationMask: fullscreenOrientationMask
        )
        fullscreenTransitioningDelegate = transitionDelegate
        fullscreenViewController.transitioningDelegate = transitionDelegate
        fullscreenViewController.modalPresentationStyle = .fullScreen
        present(fullscreenViewController, animated: true, completion: nil)
    }

    private func restorePlayerAfterFullscreen(at indexPath: IndexPath) {
        guard viewModel.videos.indices.contains(indexPath.item) else { return }
        let video = viewModel.videos[indexPath.item]
        let currentTime = DYPlayerManager.shared.player.currentTime
        if let cell = collectionView.cellForItem(at: indexPath) as? VideoCell {
            cell.controlView.delegate = self
            DYPlayerManager.shared.playWithCache(originalURL: video.videoURL, in: cell.playerContainerView, seekTo: currentTime)
            cell.controlView.updateCenterBtnState(.playing)
        } else {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
            if let cell = collectionView.cellForItem(at: indexPath) as? VideoCell {
                cell.controlView.delegate = self
                DYPlayerManager.shared.playWithCache(originalURL: video.videoURL, in: cell.playerContainerView, seekTo: currentTime)
                cell.controlView.updateCenterBtnState(.playing)
            }
        }
    }
}

// MARK: - UICollectionViewDelegate & DataSource

extension HomeViewController: UICollectionViewDelegate, UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return viewModel.videos.count
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VideoCell.identifier, for: indexPath) as! VideoCell
        cell.configure(with: viewModel.videos[indexPath.item])
        return cell
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        // Tap to pause/resume
        let player = DYPlayerManager.shared.player
        if player.state == .playing {
            player.pause()
        } else {
            player.resume()
        }
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let visibleRect = CGRect(origin: collectionView.contentOffset, size: collectionView.bounds.size)
        let visiblePoint = CGPoint(x: visibleRect.midX, y: visibleRect.midY)
        
        if let indexPath = collectionView.indexPathForItem(at: visiblePoint) {
            if currentPlayingIndexPath != indexPath {
                playVideo(at: indexPath)
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if currentPlayingIndexPath == indexPath {
            let current = DYPlayerManager.shared.player.currentTime
            // 必须在 stop() 之前保存进度，因为 stop() 会重置播放器导致时间丢失
            viewModel.updateResumeTime(for: indexPath.item, time: current)
            DYPlayerManager.shared.stop()
            currentPlayingIndexPath = nil
        }
    }
}

// MARK: - DYVideoPlayerDelegate
extension HomeViewController: DYVideoPlayerDelegate {
    func player(_ player: DYVideoPlayer, didChangeState state: DYPlayerState) {
        guard let indexPath = currentPlayingIndexPath,
              let cell = collectionView.cellForItem(at: indexPath) as? VideoCell else { return }
        cell.controlView.updateCenterBtnState(state)
    }
    
    func player(_ player: DYVideoPlayer, didUpdateProgress progress: Double, currentTime: Double, totalTime: Double) {
        guard let indexPath = currentPlayingIndexPath,
              let cell = collectionView.cellForItem(at: indexPath) as? VideoCell else { return }
        
        cell.controlView.updateProgress(currentTime: currentTime, totalTime: totalTime)
    }
    
    func player(_ player: DYVideoPlayer, didFailWithError error: Error?) {
        guard let indexPath = currentPlayingIndexPath else { return }
        let video = viewModel.videos[indexPath.item]
        
        print("[HomeViewController] Player error: \(String(describing: error)), retrying with original URL")
        
        // 1. 将该 URL 加入黑名单，避免后续再次使用代理
        VideoCacheManager.shared.addToBlacklist(url: video.videoURL)
        
        // 2. 使用原始 URL 重试播放
        // 注意：playVideo 内部调用 getProxyURL 时，会因为黑名单而直接返回原始 URL
        playVideo(at: indexPath)
    }
}

// MARK: - DYPlayerControlViewDelegate
extension HomeViewController: DYPlayerControlViewDelegate {
    
    func controlView(_ controlView: DYPlayerControlView, didEndDragging value: Double) {
        // 拖拽结束，进行 Seek
        let player = DYPlayerManager.shared.player
        let totalTime = player.duration
        let targetTime = totalTime * value
        
        // Seek 操作
        player.seek(to: targetTime) { [weak player] finished in
            if finished {
                player?.resume()
            }
        }
        print("Seek to: \(targetTime)")
    }
    
    func controlViewDidTapPlayPause(_ controlView: DYPlayerControlView) {
        let player = DYPlayerManager.shared.player
        if player.state == .playing {
            player.pause()
        } else {
            player.resume()
        }
    }

    func controlViewDidTapFullscreen(_ controlView: DYPlayerControlView) {
        guard let indexPath = currentPlayingIndexPath else { return }
        presentFullscreen(for: indexPath)
    }
    
    func controlViewDidBeginFastPlay(_ controlView: DYPlayerControlView) {
        let player = DYPlayerManager.shared.player
        if player.state != .playing {
            player.resume()
        }
        player.setPlaybackRate(2.0)
    }
    
    func controlViewDidEndFastPlay(_ controlView: DYPlayerControlView) {
        let player = DYPlayerManager.shared.player
        player.setPlaybackRate(1.0)
    }
}

// MARK: - UIGestureRecognizerDelegate
extension HomeViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 只有当导航栈中控制器数量大于1时，才允许手势，防止在根控制器卡死
        return (navigationController?.viewControllers.count ?? 0) > 1
    }
}
