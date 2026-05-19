# DouyinVideoExample

`DouyinVideoExample` 是一个基于 Swift + UIKit 的仿抖音短视频播放示例项目，重点演示垂直分页视频流、AVPlayer 播放器封装、视频缓存预加载、播放器复用、全屏播放与页面间播放状态迁移等能力。

项目采用 MVVM + Coordinator 组织业务和导航，UI 主要使用 SnapKit 纯代码布局，播放链路基于 AVFoundation，并通过 KTVHTTPCache、Kingfisher 等组件补齐视频缓存和封面加载能力。

## 功能描述

### 首页短视频流

- 使用 `UICollectionView` 实现竖向分页滑动，一屏一个视频，贴近短视频 App 的浏览体验。
- 首次进入页面后自动播放当前可见视频，滚动停止后自动切换到屏幕中心视频。
- Cell 内展示封面图、视频标题、播放器承载视图和自定义控制层。
- 播放器画面就绪后封面淡出，减少首帧加载过程中的黑屏和闪烁。
- 底部保留仿抖音 Tab 栏入口，包括首页、朋友、发布、消息、我的。

### 视频播放能力

- 基于 `AVPlayer` 封装 `DYVideoPlayer`，提供统一的播放、暂停、恢复、停止、Seek、倍速、音量、静音、循环播放和画面填充模式配置。
- 支持播放状态、播放进度、缓冲进度、播放错误和视频尺寸变化回调。
- 默认开启循环播放，适合短视频场景。
- 支持播放器承载视图迁移，播放器可以在列表 Cell、详情页和全屏容器之间切换，避免重复创建播放实例。
- 全局配置音频会话为 `.playback`，保证设备静音模式下仍可播放声音。

### 播放控制层

- 自定义 `DYPlayerControlView` 提供播放/暂停状态展示、底部进度条、缓冲进度、拖拽 Seek、加载状态、错误遮罩和全屏入口。
- 支持长按加速播放，并通过 `ShortPlayerSpeedTipView` 显示倍速提示。
- 拖拽进度时显示浮动时间，拖动过程中做预览 Seek 节流，结束拖拽后执行精确 Seek。
- 横屏视频会显示“全屏观看”按钮，竖屏内容保持沉浸式列表播放。

### 缓存与预加载

- `VideoCacheManager` 基于 `KTVHTTPCache` 封装本地代理服务，播放时将原始视频地址转换为代理 URL，实现边下边播和磁盘缓存。
- 支持计算缓存大小、清理全部缓存、清理指定 URL 缓存、查询缓存状态和判断资源是否完整缓存。
- 默认限制视频缓存上限为 500 MB，并设置下载超时和可接受的媒体 Content-Type。
- `VideoPreloadManager` 根据当前播放索引计算前后预加载窗口，默认预加载前后各 1 条视频。
- 预加载任务支持防抖、并发数限制、优先级队列、缓存命中统计、成功率统计和调试快照。
- 预加载失败的 URL 可进入自动黑名单，后续播放或预加载会回退到原始 URL，避免无效代理反复影响体验。

### 播放器复用与无缝切换

- `DYPlayerPool` 和 `DYPlayerManager` 负责播放器实例池与播放服务编排。
- `PlayerCoordinator` 维护列表索引到播放器实例的映射关系，处理播放切换、复用、回收和事件转发。
- 快速上下滑时采用双播放器交替策略，新播放器开始播放后再暂停旧播放器，降低切换黑屏概率。
- 最近播放过的播放器会短暂保留，回滑 1 到 2 个视频时可以快速恢复。
- 当前视频稳定播放后，会尝试对邻近视频做播放器级预热，配合字节级预加载提升首帧速度。

### 详情页与推荐播放

- 点击视频标题可进入详情页，详情页接管当前播放器并保持播放进度。
- 详情页返回时，播放器会迁回首页对应 Cell，继续保持原播放状态。
- 详情页提供推荐视频入口，触发后返回首页并追加推荐视频数据，自动滚动并播放新内容。
- 播放进度通过 `ResumeTimeStore` 按视频 ID 保存，列表插入、删除或重新排序后仍能恢复到正确视频。

### 全屏播放

- 首页内置 `InlineFullscreenVideoController`，通过在当前 Window 上创建浮层并旋转播放器容器实现“假横屏”全屏，不依赖系统方向切换。
- 全屏进入和退出时播放器在原始 Cell 与全屏容器之间迁移，配合动画保持视觉连续性。
- 全屏控制层支持关闭、播放/暂停、进度拖拽、倍速选择、长按加速和自动隐藏控制栏。
- 项目中也保留了 `FullscreenVideoViewController` 与自定义转场相关实现，便于扩展为真正的 present 全屏方案。

### 网络与错误恢复

- `NetworkMonitor` 监听网络状态。
- 播放失败后会记录最近一次失败上下文，网络恢复时自动重试当前视频。
- `PlaybackRetryHandler` 结合缓存黑名单策略处理代理播放失败场景，必要时回退到原始视频地址。
- 播放器事件通过 Combine 向 ViewModel 和 UI 层分发，ViewController 不直接处理底层播放器细节。

## 技术栈

- Swift 5
- UIKit
- AVFoundation
- Combine
- SnapKit
- KTVHTTPCache
- Kingfisher
- NVActivityIndicatorView
- CocoaPods

## 环境要求

- iOS 13.0+
- Xcode 12.0+
- CocoaPods

## 安装与运行

1. 克隆项目：

   ```bash
   git clone <repository-url>
   cd DouyinVideoExample
   ```

2. 安装依赖：

   ```bash
   pod install
   ```

3. 打开工作空间：

   ```bash
   open DouyinVideoExample.xcworkspace
   ```

4. 在 Xcode 中选择 `DouyinVideoExample` Scheme，运行到模拟器或真机。

> 注意：项目依赖远程视频地址，首次播放和预加载需要网络可用。

## 项目结构

```text
DouyinVideoExample/
├── AppDelegate.swift                         # 应用启动、音频会话和网络监听初始化
├── SceneDelegate.swift                       # Window、导航控制器和 AppCoordinator 初始化
├── Coordinators/
│   ├── AppCoordinator.swift                  # 应用级导航入口
│   ├── HomeCoordinator.swift                 # 首页、详情页、全屏播放导航
│   └── DetailCoordinator.swift               # 详情页导航与推荐播放回调
├── Controllers/
│   ├── HomeViewController.swift              # 首页视频流、滚动播放、Cell 交互绑定
│   └── DetailViewController.swift            # 详情页播放器接管与推荐入口
├── ViewModels/
│   └── HomeViewModel.swift                   # 视频数据、播放状态、预加载调度
├── Models/
│   ├── VideoModel.swift                      # 视频数据模型和示例数据
│   └── ResumeTimeStore.swift                 # 播放进度恢复存储
├── Views/
│   └── VideoCell.swift                       # 视频 Cell、封面、标题、控制层
├── Components/Player/
│   ├── DYVideoPlayer.swift                   # AVPlayer 核心封装
│   ├── Cache/                                # 视频缓存与预加载
│   ├── FullScreen/                           # 全屏播放、手势和转场
│   ├── PlayerControl/                        # 播放控制层
│   ├── PlayerManager/                        # 播放器池、播放服务和协调器
│   ├── Strategy/                             # 播放失败重试策略
│   ├── Utils/                                # 协议、布局、方向和工具方法
│   └── Views/                                # 播放器视图、进度条、倍速提示
└── Utils/
    ├── AppLog.swift                          # 统一日志分类
    └── NetworkMonitor.swift                  # 网络状态监听
```

## 核心模块说明

### `DYVideoPlayer`

播放器核心封装，负责管理 `AVPlayer`、`AVPlayerItem`、`AVPlayerLayer`、状态机、进度监听、缓冲监听、首帧渲染、循环播放和资源释放。上层通过协议或 manager 调用，不需要直接接触 AVFoundation 细节。

### `DYPlayerManager`

播放器对外统一入口，组合 `DYPlayerPool` 和 `DYPlaybackService`。列表、详情页和全屏页共享同一播放编排边界，保证播放器迁移和复用逻辑一致。

### `PlayerCoordinator`

首页播放生命周期协调器，负责“哪个索引正在播放”“当前播放器应挂载到哪个容器”“旧播放器何时暂停”“失败后如何重试”等业务编排，并把底层播放器事件转换成 Combine 事件流。

### `VideoCacheManager`

视频缓存服务，启动 KTVHTTPCache 本地代理，提供代理 URL、预加载、缓存查询、缓存清理、黑名单和预加载通知能力。

### `VideoPreloadManager`

预加载策略层，只计算“应该预加载哪些 URL”，实际下载交给 `VideoCacheManager`。它和播放器解耦，避免快速滑动时重复创建播放器资源。

### `HomeViewModel`

首页数据和播放状态中枢，管理视频列表、播放器状态、进度、缓冲、当前播放索引和预加载调度。ViewController 通过订阅 Published 属性更新 UI。

## 播放链路概览

```text
HomeViewController
    -> HomeViewModel.playVideo(at:containerView:)
        -> PlayerCoordinator.playVideo(...)
            -> DYPlayerManager.playWithCache(...)
                -> VideoCacheManager.getProxyURL(...)
                -> DYVideoPlayer.play(url:in:seekTo:)
                    -> AVPlayer / AVPlayerLayer
```

预加载链路：

```text
HomeViewModel.updatePreloadStrategy(...)
    -> VideoPreloadManager.updateStrategy(...)
        -> VideoCacheManager.preload(url:length:)
            -> KTVHTTPCache Range Loader
```

## 示例数据

示例视频数据位于 `VideoModel.mockData()`，包含 10 条远程视频地址和本地封面图。`VideoModel.moreData()` 用于详情页推荐播放场景，返回追加视频数据。

## 开发约定

- ViewController 负责 UI 搭建、用户交互和状态绑定，不直接承载复杂播放业务。
- 播放业务优先放在 `HomeViewModel`、`PlayerCoordinator`、`DYPlayerManager` 或播放器组件内部。
- 导航跳转统一通过 Coordinator 处理，避免 ViewController 直接 push 或 present。
- `VideoModel` 保持不可变，播放进度等可变状态放在 `ResumeTimeStore`。
- UI 布局优先使用 SnapKit 纯代码实现。
- 播放器、缓存和网络相关回调需要回到主线程更新 UI。

## 调试提示

- 缓存问题：查看 `VideoCacheManager`、`VideoPreloadManager` 和 `AppLog.cache` / `AppLog.preload` 日志。
- 切换闪烁：查看 `PlayerCoordinator`、`DYVideoPlayer` 中的 `FlickerTrace` 日志。
- 播放失败：关注 `PlaybackRetryHandler`、缓存黑名单和网络恢复重试日志。
- 需要临时清空缓存时，可在 DEBUG 环境下调整 `HomeViewController.shouldClearVideoCacheOnLaunch`。

## 依赖说明

- [SnapKit](https://github.com/SnapKit/SnapKit)：Swift 自动布局 DSL。
- [KTVHTTPCache](https://github.com/ChangbaDev/KTVHTTPCache)：媒体代理缓存与 Range 预加载。
- [Kingfisher](https://github.com/onevcat/Kingfisher)：封面图片下载与缓存。
- [NVActivityIndicatorView](https://github.com/ninjaprox/NVActivityIndicatorView)：加载动画组件。

## License

MIT
