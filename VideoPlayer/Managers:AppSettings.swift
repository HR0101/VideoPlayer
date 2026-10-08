import SwiftUI

// MARK: - App Settings Manager
/// アプリケーションの設定を管理するクラス
class AppSettings: ObservableObject {
    @Published var thumbnailOption: ThumbnailOption {
        didSet {
            // UserDefaultsに設定を保存
            UserDefaults.standard.set(thumbnailOption.rawValue, forKey: "thumbnailOption")
        }
    }
    
    init() {
        // UserDefaultsから設定を読み込み
        let savedOption = UserDefaults.standard.string(forKey: "thumbnailOption") ?? ThumbnailOption.firstFrame.rawValue
        self.thumbnailOption = ThumbnailOption(rawValue: savedOption) ?? .firstFrame
    }
}
