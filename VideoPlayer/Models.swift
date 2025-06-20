import Foundation
import AVKit

// ===================================
//  Models.swift
// ===================================
// アプリケーション全体で使用されるデータモデルをこのファイルに集約します。

// MARK: - Enums

/// アルバムの種類を定義する列挙型
enum AlbumType: Hashable, Identifiable {
    case all
    case trash
    case user(String)

    var id: String {
        switch self {
        case .all: return "all"
        case .trash: return "trash"
        case .user(let name): return name
        }
    }

    var displayName: String {
        switch self {
        case .all: return "すべてのビデオ"
        case .trash: return "ごみ箱"
        case .user(let name): return name
        }
    }
    
    var systemIcon: String {
        switch self {
        case .all: return "video.fill"
        case .trash: return "trash.fill"
        case .user: return "folder.fill"
        }
    }
}

/// ビデオの並べ替え順序を定義する列挙型
enum SortOrder: String, CaseIterable, Identifiable {
    case byDateAdded = "追加順"
    case byCreationDate = "日付順"
    case byName = "ABC順"
    
    var id: String { self.rawValue }
}

/// サムネイル生成のオプションを定義します。
enum ThumbnailOption: Int, CaseIterable, Identifiable {
    case initial, threeSeconds, tenSeconds, midpoint, random

    var id: Int { self.rawValue }

    var description: String {
        switch self {
        case .initial: return "最初のサムネ"
        case .threeSeconds: return "3秒後のサムネ"
        case .tenSeconds: return "10秒後のサムネ"
        case .midpoint: return "中間のサムネ"
        case .random: return "ランダムな秒数"
        }
    }
}


// MARK: - Structs

/// ビデオファイルのメタデータを保持する構造体
struct VideoMetadata: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let dateAdded: Date
    let creationDate: Date?
}

/// URLをIdentifiableにするためのラッパー (VideoPlayer表示用)
struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}
