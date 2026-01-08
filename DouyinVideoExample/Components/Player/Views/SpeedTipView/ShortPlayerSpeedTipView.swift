import UIKit
import SnapKit
import QuartzCore

public class ShortPlayerSpeedTipView: UIView {
    // MARK: - Properties
    public static let viewWidth: CGFloat = 120
    public static let viewHeight: CGFloat = 40

    private let iconImageView: UIImageView = {
        let frames = [
            UIImage(named: "icon_speed_0"),
            UIImage(named: "icon_speed_1")
        ].compactMap { $0 }
        let image = frames.isEmpty ? UIImage(systemName: "bolt.fill") : UIImage.animatedImage(with: frames, duration: 0.6)
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = UIColor.white.withAlphaComponent(0.9)
        return label
    }()

    // MARK: - Initialization
    public override init(frame: CGRect) {
        super.init(frame: frame)
        configureView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    // MARK: - Private Methods
    private func configureView() {
        layer.cornerRadius = 8
        layer.masksToBounds = true
        backgroundColor = .black
        alpha = 0

        addSubview(iconImageView)
        addSubview(titleLabel)

        iconImageView.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(16)
            make.centerY.equalToSuperview()
            make.size.equalTo(CGSize(width: 24, height: 24))
        }

        titleLabel.snp.makeConstraints { make in
            make.left.equalTo(iconImageView.snp.right).offset(3)
            make.right.equalToSuperview().offset(-16)
            make.centerY.equalToSuperview()
        }
    }

    // MARK: - Public Methods
    public func showSpeedView(tip: String) {
        if let frames = iconImageView.image?.images, !frames.isEmpty {
            // 使用 animatedImage 自动播放，无需显式 startAnimating
        } else {
            iconImageView.image = iconImageView.image ?? UIImage(systemName: "bolt.fill")
            iconImageView.layer.removeAnimation(forKey: "pulse")
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 0.95
            pulse.toValue = 1.05
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            iconImageView.layer.add(pulse, forKey: "pulse")
        }
        titleLabel.text = tip
        UIView.animate(withDuration: 0.5) {
            self.alpha = 1.0
        }
    }

    public func hideSpeedView() {
        iconImageView.stopAnimating()
        iconImageView.layer.removeAnimation(forKey: "pulse")
        UIView.animate(withDuration: 0.5) {
            self.alpha = 0
        }
    }
}
