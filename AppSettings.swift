import SwiftUI
import Foundation

class AppSettings: ObservableObject {
    private static let thumbnailOptionKey = "thumbnailOption"

    @Published var thumbnailOption: ThumbnailOption {
        didSet { UserDefaults.standard.set(thumbnailOption.rawValue, forKey: Self.thumbnailOptionKey) }
    }
    
    private static let upNextDisplayStyleKey = "upNextDisplayStyle"
    // 0 = 自動 (Auto), 1 = リスト (List), 2 = グリッド (Grid)
    @Published var upNextDisplayStyle: Int {
        didSet { UserDefaults.standard.set(upNextDisplayStyle, forKey: Self.upNextDisplayStyleKey) }
    }
    
    private static let showSameAlbumOnlyDefaultKey = "showSameAlbumOnlyDefault"
    @Published var showSameAlbumOnlyDefault: Bool {
        didSet { UserDefaults.standard.set(showSameAlbumOnlyDefault, forKey: Self.showSameAlbumOnlyDefaultKey) }
    }
    
    private static let excludedTitleWordsKey = "excludedTitleWordsList"
    @Published var excludedTitleWords: [String] {
        didSet { UserDefaults.standard.set(excludedTitleWords, forKey: Self.excludedTitleWordsKey) }
    }

    private static let shortsVideoFillScaleKey = "shortsVideoFillScale"
    @Published var shortsVideoFillScale: Double {
        didSet { UserDefaults.standard.set(shortsVideoFillScale, forKey: Self.shortsVideoFillScaleKey) }
    }

    init() {
        let savedThumbnailValue = UserDefaults.standard.integer(forKey: Self.thumbnailOptionKey)
        self.thumbnailOption = ThumbnailOption(rawValue: savedThumbnailValue) ?? .initial
        
        // 既存のキーがなければデフォルト値(0=自動)になる
        self.upNextDisplayStyle = UserDefaults.standard.integer(forKey: Self.upNextDisplayStyleKey)
        
        // Boolはデフォルトfalseになるので、必要なら初期化の工夫をする
        if UserDefaults.standard.object(forKey: Self.showSameAlbumOnlyDefaultKey) != nil {
            self.showSameAlbumOnlyDefault = UserDefaults.standard.bool(forKey: Self.showSameAlbumOnlyDefaultKey)
        } else {
            self.showSameAlbumOnlyDefault = false
        }
        
        if UserDefaults.standard.object(forKey: Self.shortsVideoFillScaleKey) != nil {
            self.shortsVideoFillScale = UserDefaults.standard.double(forKey: Self.shortsVideoFillScaleKey)
        } else {
            // Check legacy enum or bool
            let savedShortsSize = UserDefaults.standard.integer(forKey: "shortsVideoSizeMode")
            if UserDefaults.standard.object(forKey: "shortsVideoSizeMode") != nil {
                if savedShortsSize == 0 { self.shortsVideoFillScale = 0.0 }
                else if savedShortsSize == 1 { self.shortsVideoFillScale = 0.5 }
                else { self.shortsVideoFillScale = 1.0 }
            } else if UserDefaults.standard.bool(forKey: "shortsVideoFillMode") {
                self.shortsVideoFillScale = 1.0
            } else {
                self.shortsVideoFillScale = 0.0
            }
        }
        if let array = UserDefaults.standard.array(forKey: Self.excludedTitleWordsKey) as? [String] {
            self.excludedTitleWords = array
        } else if let oldString = UserDefaults.standard.string(forKey: "excludedTitleWords") {
            let words = oldString.components(separatedBy: CharacterSet(charactersIn: ",、\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            self.excludedTitleWords = words
            // 古いキーを削除
            UserDefaults.standard.removeObject(forKey: "excludedTitleWords")
        } else {
            self.excludedTitleWords = []
        }
    }
}
