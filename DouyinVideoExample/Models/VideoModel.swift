import Foundation
import UIKit

/// 视频数据模型
/// 纯数据模型，所有属性均为不可变（let），可变播放状态由 ResumeTimeStore 独立管理
/// 使用 struct 遵循 Swift 值类型优先原则，自动获得 Equatable/Hashable 合成
struct VideoModel: Equatable, Hashable {
    let id: String
    let title: String
    let coverURL: URL?
    let coverImage: UIImage?
    let videoURL: URL
    let aspectRatio: Double?

    /// Hashable 合成：仅基于 id，保证唯一性
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Equatable：仅基于 id 判等，同一视频无论其他属性是否变化都视为相同
    static func == (lhs: VideoModel, rhs: VideoModel) -> Bool {
        return lhs.id == rhs.id
    }

    /// 初始化视频模型
    /// - Parameters:
    ///   - id: 视频唯一标识
    ///   - title: 视频标题
    ///   - coverURL: 封面图远程 URL（与 coverImage 二选一，优先使用 coverImage）
    ///   - coverImage: 封面图本地图片（与 coverURL 二选一，优先使用）
    ///   - videoURL: 视频播放 URL
    ///   - aspectRatio: 宽高比
    init(id: String,
            title: String,
            coverURL: URL? = nil,
            coverImage: UIImage? = nil,
            videoURL: URL,
            aspectRatio: Double? = nil) {
           self.id = id
           self.title = title
           self.coverURL = coverURL
           self.coverImage = coverImage
           self.videoURL = videoURL
           self.aspectRatio = aspectRatio
       }
    
    static func mockData() -> [VideoModel] {
        var videos: [VideoModel] = []
        
        let coverNames = [
            "cover_1", "cover_2", "cover_3", "cover_4", "cover_5",
            "cover_6", "cover_7", "cover_8", "cover_9", "cover_10"
        ]
        
        let videoURLs = [
            "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2026/01/26/82871dbe18a940c7a9c9efae1e838113/h264_500k_mp4.mp4",
            "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2025/12/12/78577d0b7b4740728769339b4cf931e6/h264_500k_mp4.mp4",
            "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2022/07/11/beed2a81721b4a168ca7234ddf1fbaac/h264_500k_mp4.mp4",
            "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2022/07/08/ef1351bef30645e0acce0eb903f1841a/h264_500k_mp4.mp4",
            "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2022/05/26/9103af8d2b1d4f34b47cde4541952a7b/h264_500k_mp4.mp4",
            "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2022/04/28/db8332499363466f9066c333d676192e/h264_500k_mp4.mp4",
            "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2022/04/12/47870d26b4c34aa6b44babb2bf0be7e0/h264_500k_mp4.mp4",
            "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2022/02/14/7082d486a2c0482cb959d63472191dbc/h264_500k_mp4.mp4",
            "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2021/12/30/bd53b6803b084440b9236e9090b0c59a/h264_500k_mp4.mp4",
            "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2021/04/29/6836c41e20c5494db93d44e330f4d1fa/h264_500k_mp4.mp4"
        ]
        
        let titles = [
            "风景视频1", "风景视频2", "动物视频1", "动物视频2",
            "运动视频1", "运动视频2", "音乐视频1", "音乐视频2",
            "科技视频1", "科技视频2"
        ]
        
        // 根据实际视频首帧分辨率设置：
        // 1、2 为 1280×720 → 16:9
        // 3~10 为 1080×1920 → 9:16
        let aspectRatios: [Double?] = [
            16/9,   // 1_风景视频1  (1280×720)
            16/9,   // 2_风景视频2  (1280×720)
            9/16,   // 3_动物视频1  (1080×1920)
            9/16,   // 4_动物视频2  (1080×1920)
            9/16,   // 5_运动视频1  (1080×1920)
            9/16,   // 6_运动视频2  (1080×1920)
            9/16,   // 7_音乐视频1  (1080×1920)
            9/16,   // 8_音乐视频2  (1080×1920)
            9/16,   // 9_科技视频1  (1080×1920)
            9/16    // 10_科技视频2 (1080×1920)
        ]
        
        for i in 0..<coverNames.count {
            if let videoURL = URL(string: videoURLs[i]),
               let coverImage = UIImage(named: coverNames[i]) {
                let video = VideoModel(
                    id: "\(i + 1)",
                    title: titles[i],
                    coverImage: coverImage,
                    videoURL: videoURL,
                    aspectRatio: aspectRatios[i]
                )
                videos.append(video)
            }
        }
        
        return videos
    }

    
    static func moreData() -> [VideoModel] {
        var videos: [VideoModel] = []
        if let coverURL10 = URL(string: "https://img2.baidu.com/it/u=172332305,310833579&fm=253&fmt=auto&app=138&f=JPEG?w=500&h=889"),
           let videoURL10 = URL(string: "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2026/01/08/fe6c0a3e21a84b8e9f5c27ac133f64cd/h264_500k_mp4.mp4") {
            videos.append(VideoModel(id: "11", title: "跳转后的视频1", coverURL: coverURL10, videoURL: videoURL10))
        }
        
        if let coverURL11 = URL(string: "https://img2.baidu.com/it/u=172332305,310833579&fm=253&fmt=auto&app=138&f=JPEG?w=500&h=889"),
           let videoURL11 = URL(string: "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2026/01/08/0c90ec72be3448bd92781b09621515ad/h264_500k_mp4.mp4") {
            videos.append(VideoModel(id: "12", title: "跳转后的视频2", coverURL: coverURL11, videoURL: videoURL11))
        }
        return videos
    }
}
