import Foundation
import AVKit

// MARK: - Data Models
// アプリケーションで使用されるデータ構造

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
    
    var systemIcon: String? {
        switch self {
        case .all: return "video.fill"
        case .trash: return "trash.fill"
        case .user: return "folder.fill"
        }
    }
}

/// ビデオファイルのメタデータを保持する構造体
struct VideoMetadata: Identifiable, Hashable {
    let id: URL
    let url: URL
    let dateAdded: Date?
    let creationDate: Date?
    
    init(url: URL) {
        self.id = url
        self.url = url
        
        // ファイル属性から日付を取得
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            self.dateAdded = attributes[.modificationDate] as? Date
            self.creationDate = attributes[.creationDate] as? Date
        } else {
            self.dateAdded = nil
            self.creationDate = nil
        }
    }
}

/// サムネイル生成オプションの列挙型
enum ThumbnailOption: String, CaseIterable, Identifiable {
    case firstFrame = "最初のフレーム"
    case atOneSecond = "1秒後"
    case atThreeSeconds = "3秒後"

    var id: String { self.rawValue }
    
    var time: CMTime {
        switch self {
        case .firstFrame: return .zero
        case .atOneSecond: return CMTime(seconds: 1, preferredTimescale: 600)
        case .atThreeSeconds: return CMTime(seconds: 3, preferredTimescale: 600)
        }
    }
}

/// ビデオの並べ替え順序を定義する列挙型
enum SortOrder: String, CaseIterable, Identifiable {
    case dateAdded = "追加順"
    case creationDate = "日付順"
    case name = "ABC順"
    
    var id: String { self.rawValue }
}
