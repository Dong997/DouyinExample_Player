import UIKit
import SnapKit
import Combine

/// 首页控制器
/// 职责仅限于：
/// 1. UI 布局与构建
/// 2. CollectionView 数据源/代理
/// 3. 将用户交互转发给 ViewModel
/// 4. 订阅 ViewModel 的 Published 属性驱动 UI 更新
/// 5. 通过 Coordinator 处理导航（不直接 push/present）
class HomeViewController: UIViewController, DYOrientationConfigurable {

    #if DEBUG
    /// 调试缓存问题时可临时打开；默认保留磁盘缓存，避免抵消预加载收益。
    private static let shouldClearVideoCacheOnLaunch = false
    #endif

    // MARK: - Dependencies

    private let viewModel: HomeViewModel
    private let playback: DYPlaybackCoordinating
    private let videoCache: VideoCacheManager
    private var cancellables = Set<AnyCancellable>()

    /// 标记是否已触发首次视频播放，避免 reloadData 后硬编码延迟
    private var hasPlayedFirstVideo = false

    /// 中心可见视频播放确认任务。首播、滚动停止、程序滚动结束统一走这一条路径。
    private var centerPlaybackWorkItem: DispatchWorkItem?

    /// 追加推荐视频后需要滚动到的首条索引；等待 collectionView 增量插入完成后再执行。
    private var pendingRecommendedIndexPath: IndexPath?

    /// 当前正在播放视频的 Cell 弱引用
    /// 避免通过 cellForItem(at:) 查找时因 Cell 未就绪/已回收导致封面图无法隐藏
    private weak var currentPlayingCell: VideoCell?

    /// Home 内部假横屏全屏控制器，不触发 present 或系统方向旋转
    private let inlineFullscreenController = InlineFullscreenVideoController()

    /// 导航协调器，由 HomeCoordinator 注入
    weak var coordinator: HomeCoordinator?

    // MARK: - UI Components

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

        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .black
        cv.delegate = self
        cv.dataSource = self
        cv.isPagingEnabled = true
        cv.contentInsetAdjustmentBehavior = .never
        cv.register(VideoCell.self, forCellWithReuseIdentifier: VideoCell.identifier)
        return cv
    }()

    // MARK: - Initialization
    init(
        viewModel: HomeViewModel? = nil,
        playback: DYPlaybackCoordinating? = nil,
        videoCache: VideoCacheManager? = nil
    ) {
        let playback = playback ?? DYPlayerManager.shared
        self.viewModel = viewModel ?? HomeViewModel()
        self.playback = playback
        self.videoCache = videoCache ?? .shared
        super.init(nibName: nil, bundle: nil)
    }

    @MainActor
    required init?(coder: NSCoder) {
        self.viewModel = HomeViewModel()
        self.playback = DYPlayerManager.shared
        self.videoCache = .shared
        super.init(coder: coder)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .gray

        #if DEBUG
        if Self.shouldClearVideoCacheOnLaunch {
            videoCache.clearAllCache()
        }
        #endif
        videoCache.start()

        navigationController?.interactivePopGestureRecognizer?.delegate = self
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true

        setupUI()
        bindViewModel()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        restorePlayerIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scheduleVisibleCenterPlayback(reason: "viewDidAppear", retryCount: 40, delay: 0.05)
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
        let player = viewModel.currentPlayer
        if let container = player.containerView, container.isDescendant(of: collectionView) {
            player.pause()
        }
    }

    // MARK: - UI Setup

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

    // MARK: - Binding

    private func bindViewModel() {
        // 播放器开始播放时直接隐藏封面图（绕过 Combine receive(on:) 延迟）
        viewModel.onPlayerStartPlaying = { [weak self] in
            self?.fadeOutCoverImage()
        }

        viewModel.$videos
            .receive(on: DispatchQueue.main)
            .sink { [weak self] videos in
                guard let self = self else { return }
                let currentCount = self.collectionView.numberOfItems(inSection: 0)
                AppLog.ui.info("Home videos update oldCount=\(currentCount), newCount=\(videos.count), windowReady=\(self.view.window != nil)")
               
                self.applyVideoCollectionUpdate(oldCount: currentCount, newCount: videos.count)
            }
            .store(in: &cancellables)

        viewModel.$playerState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                AppLog.ui.info("Home observed playerState=\(String(describing: state)), currentIndex=\(String(describing: self?.viewModel.currentPlayingIndexPath))")
                self?.updateCurrentCellControlView { controlView in
                    controlView.updateCenterBtnState(state)
                }
                if state == .playing {
                    self?.hasPlayedFirstVideo = true
                    self?.centerPlaybackWorkItem?.cancel()
                    self?.centerPlaybackWorkItem = nil
                    self?.fadeOutCoverImage()
                }
            }
            .store(in: &cancellables)

        viewModel.$progressInfo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                self?.updateCurrentCellControlView { controlView in
                    controlView.updateProgress(currentTime: info.currentTime, totalTime: info.totalTime)
                }
            }
            .store(in: &cancellables)

        viewModel.$bufferProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.updateCurrentCellControlView { controlView in
                    controlView.updateBuffer(progress: progress)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Player Control（通过 ViewModel 间接调用 PlayerCoordinator）

    @discardableResult
    private func playVideo(at indexPath: IndexPath) -> Bool {
        guard let cell = collectionView.cellForItem(at: indexPath) as? VideoCell else { return false }
        return playVideo(at: indexPath, with: cell)
    }

    @discardableResult
    private func playVideo(at indexPath: IndexPath, with cell: VideoCell) -> Bool {
        let index = indexPath.item
        guard viewModel.videos.indices.contains(index) else { return false }
        let video = viewModel.videos[index]

        currentPlayingCell = cell
        AppLog.flicker.info("[FlickerTrace] Home playVideo begin index=\(index), cell=\(String(ObjectIdentifier(cell).hashValue, radix: 16)), url=\(video.videoURL.lastPathComponent), currentIndex=\(String(describing: self.viewModel.currentPlayingIndexPath)), playerState=\(String(describing: self.viewModel.currentPlayer.state)), cellBounds=\(String(describing: cell.bounds)), containerBounds=\(String(describing: cell.playerContainerView.bounds))")

        viewModel.playVideo(at: indexPath, containerView: cell.playerContainerView)

        let player = viewModel.currentPlayer
        AppLog.flicker.info("[FlickerTrace] Home playVideo requested index=\(index), cell=\(String(ObjectIdentifier(cell).hashValue, radix: 16)), playerState=\(String(describing: player.state)), playerURL=\(String(describing: player.currentURL?.absoluteString)), originalURL=\(String(describing: player.originalURL?.absoluteString)), playerContainerMatches=\(player.containerView === cell.playerContainerView)")
        if player.state == .playing, player.isPlaying(url: video.videoURL) {
            // 只有真正进入播放态后才隐藏占位图，避免 ready 但首帧未渲染时露黑。
            cell.hideCoverImage(animated: true)
        } else {
            // 播放开始前保持 last-frame/封面稳定，等待 .playing 回调后再淡出。
            cell.showCoverImage()
        }

        cell.controlView.delegate = self
        if player.state == .paused || player.state == .idle {
            cell.controlView.updateCenterBtnState(.preparing)
        } else {
            cell.controlView.updateCenterBtnState(player.state)
        }
        cell.controlView.updateProgress(currentTime: player.currentTime, totalTime: player.duration)

        cell.onTitleTapped = { [weak self] in
            guard let self = self else { return }
            let currentTime = self.viewModel.currentPlayer.currentTime
            self.coordinator?.showDetail(
                videoURL: video.videoURL,
                seekTime: currentTime,
                player: self.viewModel.currentPlayer
            )
        }
        return true
    }

    private func restorePlayerIfNeeded() {
        guard let indexPath = viewModel.currentPlayingIndexPath,
              let cell = collectionView.cellForItem(at: indexPath) as? VideoCell,
              viewModel.videos.indices.contains(indexPath.item) else {
            return
        }
        viewModel.restorePlayer(at: indexPath, containerView: cell.playerContainerView)
    }

    private func applyVideoCollectionUpdate(oldCount: Int, newCount: Int) {
        guard oldCount != newCount else { return }

        if oldCount == 0 || newCount < oldCount {
            hasPlayedFirstVideo = false
            collectionView.reloadData()
            runPendingRecommendedPlaybackIfNeeded()
            scheduleVisibleCenterPlayback(reason: "videosReload", retryCount: 40, delay: 0.05)
            return
        }

        let insertedIndexPaths = (oldCount..<newCount).map { IndexPath(item: $0, section: 0) }
        collectionView.performBatchUpdates {
            collectionView.insertItems(at: insertedIndexPaths)
        } completion: { [weak self] _ in
            guard let self = self else { return }
            self.runPendingRecommendedPlaybackIfNeeded()
            self.scheduleVisibleCenterPlayback(reason: "videosInserted", retryCount: 10, delay: 0.04)
        }
    }

    private func scheduleVisibleCenterPlayback(reason: String, retryCount: Int = 6, delay: TimeInterval = 0.04) {
        centerPlaybackWorkItem?.cancel()
        AppLog.ui.info("Home schedule center playback reason=\(reason), retryCount=\(retryCount), videos=\(self.viewModel.videos.count), windowReady=\(self.view.window != nil)")

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.ensureVisibleCenterVideoPlaying(reason: reason) {
                return
            }
            guard retryCount > 0 else { return }
            self.scheduleVisibleCenterPlayback(reason: reason, retryCount: retryCount - 1, delay: delay)
        }
        centerPlaybackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    @discardableResult
    private func ensureVisibleCenterVideoPlaying(reason: String) -> Bool {
        guard isViewLoaded, view.window != nil, !viewModel.videos.isEmpty else {
            AppLog.ui.info("Home center playback skipped reason=\(reason), loaded=\(self.isViewLoaded), windowReady=\(self.view.window != nil), videos=\(self.viewModel.videos.count)")
            return false
        }

        view.layoutIfNeeded()
        collectionView.layoutIfNeeded()

        let visibleRect = CGRect(origin: collectionView.contentOffset, size: collectionView.bounds.size)
        let visiblePoint = CGPoint(x: visibleRect.midX, y: visibleRect.midY)
        let indexPath = collectionView.indexPathForItem(at: visiblePoint) ?? centeredVisibleIndexPath()

        guard let indexPath = indexPath else {
            AppLog.ui.warning("Home center playback missing indexPath reason=\(reason), point=\(String(describing: visiblePoint)), visibleCount=\(self.collectionView.visibleCells.count)")
            return false
        }

        let player = viewModel.currentPlayer
        AppLog.ui.info("Home center playback reason=\(reason), index=\(indexPath.item), currentIndex=\(String(describing: self.viewModel.currentPlayingIndexPath)), playerState=\(String(describing: player.state)), point=\(String(describing: visiblePoint))")
        if viewModel.currentPlayingIndexPath == indexPath, player.state == .playing {
            hasPlayedFirstVideo = true
            return true
        }

        guard let cell = collectionView.cellForItem(at: indexPath) as? VideoCell else {
            AppLog.ui.warning("Home center playback missing cell reason=\(reason), index=\(indexPath.item), visibleCount=\(self.collectionView.visibleCells.count)")
            return false
        }

        _ = playVideo(at: indexPath, with: cell)
        return viewModel.currentPlayer.state == .playing
    }

    private func presentFullscreen(for indexPath: IndexPath) {
        guard viewModel.videos.indices.contains(indexPath.item) else { return }
        guard let cell = collectionView.cellForItem(at: indexPath) as? VideoCell else { return }
        let video = viewModel.videos[indexPath.item]
        let aspectRatio = video.aspectRatio ?? 1.0
        let fullscreenOrientationMask: UIInterfaceOrientationMask = aspectRatio > 1.0 ? .landscapeRight : .portrait

        cell.controlView.updateFullscreenState(isFullScreen: true)
        inlineFullscreenController.onDismiss = { [weak self] in
            guard let self else { return }
            if let restoredCell = self.collectionView.cellForItem(at: indexPath) as? VideoCell {
                restoredCell.controlView.delegate = self
                restoredCell.controlView.updateFullscreenState(isFullScreen: false)
                restoredCell.controlView.updateCenterBtnState(.playing)
            }
        }
        inlineFullscreenController.enter(
            from: cell.playerContainerView,
            player: viewModel.currentPlayer,
            orientationMask: fullscreenOrientationMask
        )
    }

    private func restoreAfterFullscreen(at indexPath: IndexPath) {
        guard viewModel.videos.indices.contains(indexPath.item) else { return }
        if let cell = collectionView.cellForItem(at: indexPath) as? VideoCell {
            cell.controlView.delegate = self
            viewModel.restoreAfterFullscreen(at: indexPath, containerView: cell.playerContainerView)
            cell.controlView.updateCenterBtnState(.playing)
        } else {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
            if let cell = collectionView.cellForItem(at: indexPath) as? VideoCell {
                cell.controlView.delegate = self
                viewModel.restoreAfterFullscreen(at: indexPath, containerView: cell.playerContainerView)
                cell.controlView.updateCenterBtnState(.playing)
            }
        }
    }

    // MARK: - UI Helper

    /// 获取当前播放 Cell 的控制视图并执行闭包更新，避免重复的 guard-let-cell 模式
    private func updateCurrentCellControlView(_ update: (DYPlayerControlView) -> Void) {
        guard let indexPath = viewModel.currentPlayingIndexPath,
              let cell = collectionView.cellForItem(at: indexPath) as? VideoCell else { return }
        update(cell.controlView)
    }

    /// 播放器就绪后淡出封面图，实现「封面→视频画面」的无缝过渡
    /// 抖音做法：视频画面渲染后，封面图以 0.3s 动画淡出
    /// 优先使用存储的 currentPlayingCell 弱引用，避免 cellForItem(at:) 找不到 Cell
    private func fadeOutCoverImage() {
        if let cell = currentPlayingCell {
            AppLog.flicker.info("[FlickerTrace] Home fadeOutCoverImage using currentPlayingCell cell=\(String(ObjectIdentifier(cell).hashValue, radix: 16)), currentIndex=\(String(describing: self.viewModel.currentPlayingIndexPath))")
            cell.hideCoverImage(animated: true)
            return
        }
        // 兜底：弱引用失效时回退到 cellForItem(at:) 查找
        guard let indexPath = viewModel.currentPlayingIndexPath,
              let cell = collectionView.cellForItem(at: indexPath) as? VideoCell else { return }
        AppLog.flicker.info("[FlickerTrace] Home fadeOutCoverImage fallback index=\(indexPath.item), cell=\(String(ObjectIdentifier(cell).hashValue, radix: 16))")
        cell.hideCoverImage(animated: true)
    }

    // MARK: - Recommended Video

    /// 加载更多视频数据并播放第一条推荐视频
    /// 由 DetailCoordinator 通过 HomeCoordinator 触发
    func playRecommendedVideo() {
        let moreVideos = VideoModel.moreData()
        let startIndex = viewModel.videos.count
        pendingRecommendedIndexPath = IndexPath(item: startIndex, section: 0)
        viewModel.videos.append(contentsOf: moreVideos)
    }

    private func runPendingRecommendedPlaybackIfNeeded() {
        guard let targetIndexPath = pendingRecommendedIndexPath,
              viewModel.videos.indices.contains(targetIndexPath.item) else { return }
        pendingRecommendedIndexPath = nil
        collectionView.scrollToItem(at: targetIndexPath, at: .centeredVertically, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            if self.collectionView.cellForItem(at: targetIndexPath) is VideoCell {
                self.playVideo(at: targetIndexPath)
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
        let video = viewModel.videos[indexPath.item]
        cell.configure(with: video)
        AppLog.flicker.info("[FlickerTrace] Home cellForItem index=\(indexPath.item), cell=\(String(ObjectIdentifier(cell).hashValue, radix: 16))")
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let videoCell = cell as? VideoCell else { return }
        let index = indexPath.item
        AppLog.flicker.info("[FlickerTrace] Home willDisplay index=\(index), cell=\(String(ObjectIdentifier(videoCell).hashValue, radix: 16)), currentIndex=\(String(describing: self.viewModel.currentPlayingIndexPath)), playerState=\(String(describing: self.viewModel.currentPlayer.state)), contentOffset=\(String(describing: collectionView.contentOffset))")
        if let player = viewModel.bindPreloadedPlayerIfNeeded(at: index, containerView: videoCell.playerContainerView) {
            AppLog.flicker.info("[FlickerTrace] Home willDisplay bound preloaded index=\(index), cell=\(String(ObjectIdentifier(videoCell).hashValue, radix: 16)), playerState=\(String(describing: player.state)), readyForDisplay=\(player.isReadyForDisplay), preloadedReady=\(player.isPreloadedAndReady), containerMatches=\(player.containerView === videoCell.playerContainerView)")
            if player.state == .paused || player.state == .idle {
                videoCell.controlView.updateCenterBtnState(.preparing)
            }
        }

        if viewModel.currentPlayingIndexPath == indexPath, viewModel.currentPlayer.state != .playing {
            AppLog.ui.info("Home willDisplay resumes current index=\(index), state=\(String(describing: self.viewModel.currentPlayer.state))")
            _ = playVideo(at: indexPath, with: videoCell)
        }

        if !hasPlayedFirstVideo, indexPath.item == 0 {
            AppLog.ui.info("Home willDisplay triggers first play index=0")
            scheduleVisibleCenterPlayback(reason: "firstWillDisplay", retryCount: 20, delay: 0.03)
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        viewModel.togglePlayPause()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        AppLog.flicker.info("[FlickerTrace] Home scrollViewDidEndDecelerating offset=\(String(describing: scrollView.contentOffset)), visible=\(self.collectionView.indexPathsForVisibleItems.map(\.item).sorted())")
        scheduleVisibleCenterPlayback(reason: "didEndDecelerating")
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        AppLog.flicker.info("[FlickerTrace] Home scrollViewDidEndDragging decelerate=\(decelerate), offset=\(String(describing: scrollView.contentOffset)), visible=\(self.collectionView.indexPathsForVisibleItems.map(\.item).sorted())")
        if !decelerate {
            scheduleVisibleCenterPlayback(reason: "didEndDragging")
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        AppLog.flicker.info("[FlickerTrace] Home scrollViewDidEndScrollingAnimation offset=\(String(describing: scrollView.contentOffset)), visible=\(self.collectionView.indexPathsForVisibleItems.map(\.item).sorted())")
        scheduleVisibleCenterPlayback(reason: "didEndScrollingAnimation")
    }

    private func centeredVisibleIndexPath() -> IndexPath? {
        let center = CGPoint(
            x: collectionView.contentOffset.x + collectionView.bounds.midX,
            y: collectionView.contentOffset.y + collectionView.bounds.midY
        )
        return collectionView.indexPathsForVisibleItems.min { lhs, rhs in
            guard let lhsAttributes = collectionView.layoutAttributesForItem(at: lhs),
                  let rhsAttributes = collectionView.layoutAttributesForItem(at: rhs) else {
                return lhs.item < rhs.item
            }
            let lhsDistance = abs(lhsAttributes.center.y - center.y)
            let rhsDistance = abs(rhsAttributes.center.y - center.y)
            return lhsDistance < rhsDistance
        }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        AppLog.flicker.info("[FlickerTrace] Home didEndDisplaying index=\(indexPath.item), cell=\(String(ObjectIdentifier(cell).hashValue, radix: 16)), currentIndex=\(String(describing: self.viewModel.currentPlayingIndexPath)), playerState=\(String(describing: self.viewModel.currentPlayer.state))")
        viewModel.didEndDisplaying(at: indexPath)
    }
}

// MARK: - DYPlayerControlViewDelegate

extension HomeViewController: DYPlayerControlViewDelegate {

    func controlViewDidBeginDragging(_ controlView: DYPlayerControlView) {
        viewModel.isDraggingProgress = true
        viewModel.pauseCurrent()
    }

    func controlView(_ controlView: DYPlayerControlView, didSeekTo time: Double, isPrecise: Bool) {
        viewModel.seekCurrent(to: time, isPrecise: isPrecise) { [weak self] finished in
            guard let self = self, isPrecise && finished else { return }
            self.viewModel.resumeCurrent()
        }
    }

    func controlViewDidTapPlayPause(_ controlView: DYPlayerControlView) {
        viewModel.togglePlayPause()
    }

    func controlViewDidTapFullscreen(_ controlView: DYPlayerControlView) {
        guard let indexPath = viewModel.currentPlayingIndexPath else { return }
        presentFullscreen(for: indexPath)
    }

    func controlViewDidBeginFastPlay(_ controlView: DYPlayerControlView) {
        let player = viewModel.currentPlayer
        if player.state != .playing { player.resume() }
        viewModel.setCurrentPlaybackRate(2.0)
    }

    func controlViewDidEndFastPlay(_ controlView: DYPlayerControlView) {
        viewModel.setCurrentPlaybackRate(1.0)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension HomeViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return (navigationController?.viewControllers.count ?? 0) > 1
    }
}
