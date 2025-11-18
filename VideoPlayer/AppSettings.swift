import SwiftUI

// ===================================
//  AppSettings.swift
// ===================================
// アプリ全体の設定を管理します。

class AppSettings: ObservableObject {
    private static let thumbnailOptionKey = "thumbnailOption"
    // ★ 削除：スライドショー関連のキー
    // private static let slideshowClipDurationKey = "slideshowClipDuration"
    // private static let slideshowVideoCountKey = "slideshowVideoCount"

    @Published var thumbnailOption: ThumbnailOption {
        didSet {
            UserDefaults.standard.set(thumbnailOption.rawValue, forKey: Self.thumbnailOptionKey)
        }
    }
    
    // ★ 削除：スライドショー関連のプロパティ
    // @Published var slideshowClipDuration: TimeInterval { ... }
    // @Published var slideshowVideoCount: Int { ... }

    init() {
        let savedThumbnailValue = UserDefaults.standard.integer(forKey: Self.thumbnailOptionKey)
        self.thumbnailOption = ThumbnailOption(rawValue: savedThumbnailValue) ?? .initial
        
        // ★ 削除：スライドショー関連設定の読み込み処理
        // let savedDurationValue = UserDefaults.standard.double(forKey: Self.slideshowClipDurationKey)
        // self.slideshowClipDuration = savedDurationValue > 0 ? savedDurationValue : 10.0
        
        // let savedCountValue = UserDefaults.standard.integer(forKey: Self.slideshowVideoCountKey)
        // self.slideshowVideoCount = savedCountValue > 0 ? savedCountValue : 20
    }
}
