import Foundation
import SwiftUI

// ===================================
//  Models.swift
// ===================================
// アプリケーション全体で使用されるデータモデルをこのファイルに集約します。

// MARK: - Enums

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
}

enum SortOrder: String, CaseIterable, Identifiable {
    case byDateAdded = "追加順"
    case byCreationDate = "日付順"
    case byName = "ABC順"
    case byLengthDescending = "長さ順（長い順）"
    case byLengthAscending = "長さ順（短い順）"
    var id: String { self.rawValue }
}

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

struct VideoMetadata: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let dateAdded: Date
    let creationDate: Date?
    let duration: TimeInterval
}

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}
