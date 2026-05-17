/// @file VideoCell.swift
/// @brief 视频列表 Cell — 承载播放器画面、封面图、标题、控制视图的 CollectionViewCell
/// @author jscn-app
/// @date 2025-05-13
import UIKit
import SnapKit
import Kingfisher

/// 视频列表单元格
///
/// 职责：
/// 1. 提供播放器画面容器（playerContainerView），由外部 PlayerCoordinator 绑定播放器
/// 2. 展示封面图，视频加载前/滑动时显示，播放器就绪后淡出
/// 3. 展示视频标题，支持点击标题回调（onTitleTapped）
/// 4. 内嵌 DYPlayerControlView，提供播放/暂停/进度等交互控件
///
/// 使用示例：
/// ```swift
/// let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VideoCell.identifier, for: indexPath) as! VideoCell
/// cell.configure(with: video)
/// cell.controlView.delegate = self
/// cell.onTitleTapped = { [weak self] in ... }
/// ```
class VideoCell: UICollectionViewCell {
    
    static let identifier = "VideoCell"
    
    /// 播放器画面容器，AVPlayerLayer 的宿主视图
    let playerContainerView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        return view
    }()
    
    /// 封面图：视频加载前/滑动时显示，播放器就绪后淡出
    /// 层级：playerContainerView 之上、controlView 之下
    /// 使用 scaleAspectFit 等比例拉伸，不裁剪铺满，保持画面完整
    let coverImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        iv.backgroundColor = .black
        return iv
    }()
    
    let titleLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        label.numberOfLines = 2
        return label
    }()
    
    let controlView = DYPlayerControlView()
    
    var onTitleTapped: (() -> Void)?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        setupActions()
    }

    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        contentView.addSubview(playerContainerView)
        contentView.addSubview(coverImageView)
        contentView.addSubview(controlView)
        contentView.addSubview(titleLabel)
        
        playerContainerView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        coverImageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        controlView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        titleLabel.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.bottom.equalToSuperview().offset(-60)
        }
    }
    
    private func setupActions() {
        titleLabel.isUserInteractionEnabled = true
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(titleTapped))
        titleLabel.addGestureRecognizer(tapGesture)
    }
    
    @objc private func titleTapped() {
        onTitleTapped?()
    }
    
    func configure(with model: VideoModel) {
        titleLabel.text = model.title
        controlView.resetForReuse()
        
        if let coverImage = model.coverImage {
            coverImageView.image = coverImage
            coverImageView.isHidden = false
            coverImageView.alpha = 1.0
        } else if let coverURL = model.coverURL {
            coverImageView.kf.setImage(
                with: coverURL,
                placeholder: nil,
                options: [.transition(.fade(0.2))]
            )
            coverImageView.isHidden = false
            coverImageView.alpha = 1.0
        } else {
            coverImageView.image = nil
            coverImageView.isHidden = true
        }
        
        let isHorizontal = (model.aspectRatio ?? 0) > 1.0
        controlView.updateAspectRatio(model.aspectRatio, shouldShowFullscreenButton: isHorizontal)
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        controlView.delegate = nil
        onTitleTapped = nil
        controlView.resetForReuse()
        coverImageView.image = nil
        coverImageView.isHidden = false
        coverImageView.alpha = 1.0
    }

    /// 隐藏封面图（播放器画面就绪后调用）
    /// - Parameter animated: 是否使用淡出动画
    func hideCoverImage(animated: Bool) {
        if animated {
            guard !coverImageView.isHidden, coverImageView.alpha > 0.01 else { return }
            UIView.animate(withDuration: 0.3, animations: {
                self.coverImageView.alpha = 0
            }, completion: { _ in
                self.coverImageView.isHidden = true
            })
        } else {
            coverImageView.alpha = 0
            coverImageView.isHidden = true
        }
    }

    /// 显示封面图（新视频开始加载时调用）
    func showCoverImage() {
        coverImageView.isHidden = false
        coverImageView.alpha = 1.0
    }
}
