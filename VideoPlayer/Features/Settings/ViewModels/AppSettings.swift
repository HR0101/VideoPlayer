import SwiftUI
import Foundation

class AppSettings: ObservableObject {
    private static let thumbnailOptionKey = "thumbnailOption"
    private static let photoTapNavigationModeKey = "photoTapNavigationMode"
    private static let legacyMangaModeKey = "isMangaMode"
    private static let remoteVideoAlbumSortOrderKey = "remoteVideoAlbumSortOrder"
    private static let remotePhotoAlbumSortOrderKey = "remotePhotoAlbumSortOrder"

    @Published var thumbnailOption: ThumbnailOption {
        didSet { UserDefaults.standard.set(thumbnailOption.rawValue, forKey: Self.thumbnailOptionKey) }
    }

    @Published var remoteVideoAlbumSortOrder: RemoteSortOrder {
        didSet { UserDefaults.standard.set(remoteVideoAlbumSortOrder.rawValue, forKey: Self.remoteVideoAlbumSortOrderKey) }
    }

    @Published var remotePhotoAlbumSortOrder: RemoteSortOrder {
        didSet { UserDefaults.standard.set(remotePhotoAlbumSortOrder.rawValue, forKey: Self.remotePhotoAlbumSortOrderKey) }
    }

    // 0 = 右タップで次へ, 1 = 左タップで次へ
    @Published var photoTapNavigationMode: Int {
        didSet {
            UserDefaults.standard.set(photoTapNavigationMode, forKey: Self.photoTapNavigationModeKey)
            UserDefaults.standard.set(photoTapNavigationMode == 1, forKey: Self.legacyMangaModeKey)
        }
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
        self.remoteVideoAlbumSortOrder = Self.loadRemoteSortOrder(forKey: Self.remoteVideoAlbumSortOrderKey)
        self.remotePhotoAlbumSortOrder = Self.loadRemoteSortOrder(forKey: Self.remotePhotoAlbumSortOrderKey)

        if UserDefaults.standard.object(forKey: Self.photoTapNavigationModeKey) != nil {
            self.photoTapNavigationMode = UserDefaults.standard.integer(forKey: Self.photoTapNavigationModeKey)
        } else {
            self.photoTapNavigationMode = UserDefaults.standard.bool(forKey: Self.legacyMangaModeKey) ? 1 : 0
        }
        
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

    private static func loadRemoteSortOrder(forKey key: String) -> RemoteSortOrder {
        if let rawValue = UserDefaults.standard.string(forKey: key),
           let order = RemoteSortOrder(rawValue: rawValue) {
            return order
        }
        return .importDescending
    }
}
