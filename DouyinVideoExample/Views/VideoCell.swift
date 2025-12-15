import UIKit
import SnapKit
import Kingfisher

class VideoCell: UICollectionViewCell {
    
    static let identifier = "VideoCell"
    
    // Container for the video player
    let playerContainerView: UIView = {
        let view = UIView()
        view.backgroundColor = .clear 
        return view
    }()
    
    // Cover image view
    let coverImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .lightGray
        return imageView
    }()
    
    // Title label
    let titleLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        label.numberOfLines = 2
        return label
    }()
    
    // Player Control View
    let controlView = DYPlayerControlView()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        // Correct hierarchy: Cover -> Player -> Title
//        contentView.addSubview(coverImageView)
        contentView.addSubview(playerContainerView)
        contentView.addSubview(controlView)
        contentView.addSubview(titleLabel)
        
//        coverImageView.snp.makeConstraints { make in
//            make.edges.equalToSuperview()
//        }
        
        playerContainerView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        controlView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        titleLabel.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.bottom.equalToSuperview().offset(-60) // Leave space for bottom tab bar if any, or safe area
        }
    }
    
    func configure(with model: VideoModel) {
        titleLabel.text = model.title
        
        controlView.updateAspectRatio(model.aspectRatio, shouldShowFullscreenButton: model.aspectRatio ?? 0 > 1.0)
        // 使用 Kingfisher 加载图片
        // 之前的手动加载方式容易出现线程安全问题和内存访问错误 (EXC_BAD_ACCESS)
        // Kingfisher 内部处理了线程切换、缓存和生命周期管理，更加安全稳定
//        if let url = model.coverURL {
//            coverImageView.kf.setImage(
//                with: url,
//                placeholder: nil,
//                options: [
//                    .transition(.fade(0.2)),
//                    .cacheOriginalImage
//                ]
//            )
//        } else {
//            coverImageView.image = nil
//        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        coverImageView.image = nil
        controlView.delegate = nil
        controlView.updateProgress(currentTime: 0, totalTime: 0)
        controlView.updateCenterBtnState(.preparing)
    }
}
