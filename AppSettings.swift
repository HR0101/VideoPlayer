import SwiftUI

// ===================================
//  AppSettings.swift
// ===================================
// アプリ全体の設定を管理します。

class AppSettings: ObservableObject {
    private static let thumbnailOptionKey = "thumbnailOption"

    // @Publishedプロパティは変更ありません。
    // AppSettingsは、Models.swiftで定義されたThumbnailOption型を使用します。
    @Published var thumbnailOption: ThumbnailOption {
        didSet {
            UserDefaults.standard.set(thumbnailOption.rawValue, forKey: Self.thumbnailOptionKey)
        }
    }

    init() {
        let savedValue = UserDefaults.standard.integer(forKey: Self.thumbnailOptionKey)
        // ThumbnailOptionはModels.swiftで定義されたものを使用します。
        self.thumbnailOption = ThumbnailOption(rawValue: savedValue) ?? .initial
    }
}
