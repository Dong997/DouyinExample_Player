import UIKit
import ObjectiveC.runtime

extension UIViewController {
    @objc var dyFullscreenOrientationMask: UIInterfaceOrientationMask {
        return .portrait
    }
    
    @objc var dySupportedInterfaceOrientations: UIInterfaceOrientationMask {
        return dyFullscreenOrientationMask
    }
    
    @objc var dyShouldAutorotate: Bool {
        switch dyFullscreenOrientationMask {
        case .portrait:
            return false
        default:
            return true
        }
    }
    
    @objc private func dy_swizzled_supportedInterfaceOrientations() -> UIInterfaceOrientationMask {
        return dySupportedInterfaceOrientations
    }
    
    @objc private func dy_swizzled_shouldAutorotate() -> Bool {
        return dyShouldAutorotate
    }
    
    static func configureOrientationInjection() {
        guard self === UIViewController.self else { return }
        
        let originalSupportedSelector = #selector(getter: UIViewController.supportedInterfaceOrientations)
        let swizzledSupportedSelector = #selector(UIViewController.dy_swizzled_supportedInterfaceOrientations)
        
        if let originalMethod = class_getInstanceMethod(self, originalSupportedSelector),
           let swizzledMethod = class_getInstanceMethod(self, swizzledSupportedSelector) {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
        
        let originalRotateSelector = #selector(getter: UIViewController.shouldAutorotate)
        let swizzledRotateSelector = #selector(UIViewController.dy_swizzled_shouldAutorotate)
        
        if let originalMethod = class_getInstanceMethod(self, originalRotateSelector),
           let swizzledMethod = class_getInstanceMethod(self, swizzledRotateSelector) {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }
}
