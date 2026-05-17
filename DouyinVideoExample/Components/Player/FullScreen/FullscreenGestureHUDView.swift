import UIKit
import SnapKit

/// 全屏手势调节时的居中提示视图。
final class FullscreenGestureHUDView: UIView {
    private let iconView: UIImageView = {
        let imageView = UIImageView()
        imageView.tintColor = .white
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        label.textAlignment = .center
        return label
    }()

    private let progressView: UIProgressView = {
        let progressView = UIProgressView(progressViewStyle: .default)
        progressView.trackTintColor = UIColor.white.withAlphaComponent(0.28)
        progressView.progressTintColor = .white
        return progressView
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(iconName: String, text: String, progress: Float) {
        iconView.image = UIImage(systemName: iconName)
        titleLabel.text = text
        progressView.setProgress(Self.clamp(progress), animated: false)
        UIView.animate(withDuration: 0.12) {
            self.alpha = 1
        }
    }

    func hide() {
        UIView.animate(withDuration: 0.18) {
            self.alpha = 0
        }
    }

    private func setupUI() {
        backgroundColor = UIColor.black.withAlphaComponent(0.72)
        layer.cornerRadius = 8
        alpha = 0

        addSubview(iconView)
        iconView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(14)
            make.centerX.equalToSuperview()
            make.width.height.equalTo(24)
        }

        addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.top.equalTo(iconView.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(12)
        }

        addSubview(progressView)
        progressView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(18)
            make.bottom.equalToSuperview().offset(-14)
            make.height.equalTo(2)
        }
    }

    private static func clamp(_ value: Float) -> Float {
        return min(max(value, 0), 1)
    }
}
