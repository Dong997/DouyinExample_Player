import Foundation
import Combine

class HomeViewModel: ObservableObject {
    @Published var videos: [VideoModel] = []
    
    init() {
        loadData()
    }
    
    func loadData() {
        // Simulate network delay
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let data = VideoModel.mockData()
            DispatchQueue.main.async {
                self.videos = data
            }
        }
    }

    func updateResumeTime(for index: Int, time: Double) {
        guard videos.indices.contains(index) else { return }
        print("[HomeViewModel] Updating resume time: \(time) for index: \(index)")
        var v = videos[index]
        v.resumeTime = time
        videos[index] = v
    }
}
