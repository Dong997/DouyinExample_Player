# DouyinVideoExample

基于 Swift 开发的 iOS 仿抖音短视频应用示例，实现了高性能的垂直无限滑动视频流。本项目采用 MVVM 架构，使用 SnapKit 进行纯代码布局，并集成了强大的本地缓存与预加载机制。

## 核心特性 (Features)

- **智能缓存与预加载 (Smart Caching & Preloading)**:
  - **本地预加载**: 利用 `KTVHTTPCache` 实现视频数据的边下边播与自动预加载，秒开视频，极大减少卡顿。
  - **离线播放**: 已缓存的视频片段支持无网络环境下播放，提升用户体验。
  - **零流量重播**: 视频加载完成后，再次播放完全读取本地缓存，不消耗任何网络流量。
- **垂直视频流**: 使用 `UICollectionView` 实现流畅的垂直翻页滑动体验。
- **自定义播放器**: 基于 `AVPlayer` 深度封装，支持播放/暂停、进度拖拽、倍速播放及循环播放。
- **MVVM 架构**: 业务逻辑与 UI 分离，`HomeViewModel` 负责数据处理，`ViewController` 专注 UI 展示。
- **纯代码布局**: 全面使用 `SnapKit` 进行 UI 布局，摒弃 Storyboard 和 XIB，便于维护与多人协作。
- **全屏模式**: 支持平滑过渡到全屏沉浸式播放体验。
- **图片缓存**: 集成 `Kingfisher` 处理封面图的高效加载与缓存。

## 环境要求 (Requirements)

- iOS 13.0+
- Xcode 12.0+
- Swift 5.0+
- CocoaPods

## 安装说明 (Installation)

1. 克隆项目:
   ```bash
   git clone <repository-url>
   cd DouyinVideoExample
   ```

2. 安装依赖:
   ```bash
   pod install
   ```

3. 打开工作空间:
   ```bash
   open DouyinVideoExample.xcworkspace
   ```

## 核心依赖 (Dependencies)

- [SnapKit](https://github.com/SnapKit/SnapKit) - Swift 优秀的自动布局 DSL。
- [KTVHTTPCache](https://github.com/ChangbaDev/KTVHTTPCache) - 强大的媒体缓存框架，支持预加载与离线缓存。
- [Kingfisher](https://github.com/onevcat/Kingfisher) - 轻量级纯 Swift 图片下载与缓存库。
- [NVActivityIndicatorView](https://github.com/ninjaprox/NVActivityIndicatorView) - 优雅的加载动画集合。

## 项目结构 (Project Structure)

```
DouyinVideoExample/
├── Components/         # 核心组件
│   ├── Player/         # 播放器实现 (Cache, Controls, Manager)
├── Controllers/        # 视图控制器 (HomeViewController)
├── Models/             # 数据模型 (VideoModel)
├── ViewModels/         # 视图模型 (HomeViewModel)
├── Views/              # UI 视图 (VideoCell)
├── AppDelegate.swift
└── SceneDelegate.swift
```

## 架构与规范 (Architecture & Standards)

本项目遵循严格的代码规范：

- **MVVM**: 业务逻辑统一置于 ViewModels，ViewControllers 仅负责 UI 交互。
- **命名规范**: 类型使用 `PascalCase`，变量/函数使用 `camelCase`。
- **UI 布局**: 严禁使用 Storyboard/XIB，统一使用 `SnapKit` 纯代码布局。
- **错误处理**: 优先使用 `guard let` 解包，避免强制解包。
- **内存管理**: 闭包中注意使用 `weak self` 避免循环引用。

## 许可证 (License)

MIT
