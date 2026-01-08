import Foundation

struct VideoModel {
    let id: String
    let title: String
    var coverURL: URL?
    let videoURL: URL
    var resumeTime: Double = 0
    var aspectRatio: Double? = nil
    
    static func mockData() -> [VideoModel] {
        var videos: [VideoModel] = []
        
        // 安全构造 VideoModel 对象
        if let coverURL1 = URL(string: "https://img0.baidu.com/it/u=2414272732,2400080964&fm=253&app=138&f=JPEG?w=800&h=1422"),
           let videoURL1 = URL(string: "https://1309962417.vod-qcloud.com/4dd6dc2cvodcq1309962417/e0df88925145403710955125013/f0.mp4") {
            videos.append(VideoModel(id: "1", title: "风景视频1", coverURL: coverURL1, videoURL: videoURL1))
        }
        
        if let coverURL2 = URL(string: "https://img1.baidu.com/it/u=1046630760,1711311937&fm=253&app=138&f=JPEG?w=800&h=1428"),
           let videoURL2 = URL(string: "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2025/12/12/78577d0b7b4740728769339b4cf931e6/h264_500k_mp4.mp4") {
            videos.append(VideoModel(id: "2", title: "风景视频2", coverURL: coverURL2, videoURL: videoURL2,aspectRatio:16/9))
        }
        
        if let coverURL3 = URL(string: "https://img2.baidu.com/it/u=1631159426,2591345325&fm=253&app=138&f=JPEG?w=800&h=1428"),
           let videoURL3 = URL(string: "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2022/07/11/beed2a81721b4a168ca7234ddf1fbaac/h264_500k_mp4.mp4") {
            videos.append(VideoModel(id: "3", title: "动物视频1", coverURL: coverURL3, videoURL: videoURL3,aspectRatio:9/16))
        }
        
        if let coverURL4 = URL(string: "https://img0.baidu.com/it/u=3945354565,2140847448&fm=253&fmt=auto&app=138&f=JPEG?w=500&h=750"),
           let videoURL4 = URL(string: "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2022/07/08/ef1351bef30645e0acce0eb903f1841a/h264_500k_mp4.mp4") {
            videos.append(VideoModel(id: "4", title: "动物视频2", coverURL: coverURL4, videoURL: videoURL4))
        }
        
        if let coverURL5 = URL(string: "https://img1.baidu.com/it/u=2456334644,3378803144&fm=253&app=120&f=JPEG?w=800&h=1422"),
           let videoURL5 = URL(string: "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2022/05/26/9103af8d2b1d4f34b47cde4541952a7b/h264_500k_mp4.mp4") {
            videos.append(VideoModel(id: "5", title: "运动视频1", coverURL: coverURL5, videoURL: videoURL5))
        }
        
        if let coverURL6 = URL(string: "https://c-ssl.dtstatic.com/uploads/blog/202209/08/20220908102249_c5010.thumb.1000_0.jpg"),
           let videoURL6 = URL(string: "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2022/04/28/db8332499363466f9066c333d676192e/h264_500k_mp4.mp4") {
            videos.append(VideoModel(id: "6", title: "运动视频2", coverURL: coverURL6, videoURL: videoURL6))
        }
        
        if let coverURL7 = URL(string: "https://ww1.sinaimg.cn/mw690/008vtBVkgy1i30o2axj0tj30u01t8n50.jpg"),
           let videoURL7 = URL(string: "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2022/04/12/47870d26b4c34aa6b44babb2bf0be7e0/h264_500k_mp4.mp4") {
            videos.append(VideoModel(id: "7", title: "音乐视频1", coverURL: coverURL7, videoURL: videoURL7))
        }
        
        if let coverURL8 = URL(string: "https://gd-hbimg.huaban.com/c7bb79aaafc485a49167dee7aec48af4a6def49b99dba-g4QvI7_fw658"),
           let videoURL8 = URL(string: "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2022/02/14/7082d486a2c0482cb959d63472191dbc/h264_500k_mp4.mp4") {
            videos.append(VideoModel(id: "8", title: "音乐视频2", coverURL: coverURL8, videoURL: videoURL8))
        }
        
        if let coverURL9 = URL(string: "https://img0.baidu.com/it/u=2932395921,212263166&fm=253&fmt=auto&app=138&f=JPEG?w=500&h=750"),
           let videoURL9 = URL(string: "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2021/12/30/bd53b6803b084440b9236e9090b0c59a/h264_500k_mp4.mp4") {
            videos.append(VideoModel(id: "9", title: "科技视频1", coverURL: coverURL9, videoURL: videoURL9))
        }
        
        if let coverURL10 = URL(string: "https://img2.baidu.com/it/u=172332305,310833579&fm=253&fmt=auto&app=138&f=JPEG?w=500&h=889"),
           let videoURL10 = URL(string: "https://video.app.visionlinkmedia.cn/rongmeiti/vod/2021/04/29/6836c41e20c5494db93d44e330f4d1fa/h264_500k_mp4.mp4") {
            videos.append(VideoModel(id: "10", title: "科技视频2", coverURL: coverURL10, videoURL: videoURL10))
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
