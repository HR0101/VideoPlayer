import SwiftUI


// アプリ全体の設定を管理

class AppSettings: ObservableObject {
    private static let thumbnailOptionKey = "thumbnailOption"

    @Published var thumbnailOption: ThumbnailOption {
        didSet {
            UserDefaults.standard.set(thumbnailOption.rawValue, forKey: Self.thumbnailOptionKey)
        }
    }
    

    init() {
        let savedThumbnailValue = UserDefaults.standard.integer(forKey: Self.thumbnailOptionKey)
        self.thumbnailOption = ThumbnailOption(rawValue: savedThumbnailValue) ?? .initial
        
    }
}
